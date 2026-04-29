import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:common/src/models/install_state.dart';
import 'package:common/src/services/log_service.dart';

class InstallService {
  Future<List<DiskInfo>> listDisks() async {
    final result = await Process.run('lsblk', [
      '--json', '--bytes', '--output', 'NAME,SIZE,MODEL,RM,TYPE', '--nodeps',
    ]);
    return parseLsblkOutput(result.stdout as String);
  }

  static List<DiskInfo> parseLsblkOutput(String output) {
    final json = jsonDecode(output) as Map<String, dynamic>;
    final devices = json['blockdevices'] as List<dynamic>;
    return devices
        .where((d) => (d['type'] as String) == 'disk')
        .map((d) => DiskInfo.fromLsblkJson(d as Map<String, dynamic>))
        .toList();
  }

  Future<String> detectPlatform() async {
    try {
      final content = await File('/proc/cpuinfo').readAsString();
      return detectPlatformFromCpuinfo(content);
    } catch (e) {
      LogService.warn('Could not read /proc/cpuinfo: $e');
      return 'x86';
    }
  }

  static String detectPlatformFromCpuinfo(String cpuinfo) {
    // Pi 4 was dropped — running a Bitcoin / Lightning node on
    // 4GB of RAM and SD-card I/O is not a deployment we want to
    // recommend, and continuing to advertise it sets up
    // operators for a bad experience. Older Pi models fall
    // through to "x86" which is wrong but loud (rebuild will
    // fail), better than silently building an unsupportable
    // image.
    if (cpuinfo.contains('Raspberry Pi 5')) return 'pi5';
    return 'x86';
  }

  Future<int> getMemoryMb() async {
    try {
      final content = await File('/proc/meminfo').readAsString();
      final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(content);
      if (match != null) return int.parse(match.group(1)!) ~/ 1024;
    } catch (e) {
      LogService.warn('Could not read /proc/meminfo: $e');
    }
    return 0;
  }

  Future<SystemInfo> detectSystem() async {
    final results = await Future.wait([detectPlatform(), getMemoryMb(), listDisks()]);
    return SystemInfo(
      platform: results[0] as String,
      memoryMb: results[1] as int,
      disks: results[2] as List<DiskInfo>,
    );
  }

  /// Run `sudo disko-install --flake <path>#<attr> --disk main <disk>`.
  ///
  /// [attribute] selects which `nixosConfigurations.<name>` target
  /// gets installed onto [diskPath]; pick it via
  /// [installerAttributeFor] from the platform detected by
  /// [detectPlatform]. Defaults to `nixblitz-installer`, the
  /// x86 / VM target — picking that on an aarch64 host fails
  /// loudly, which is the right outcome.
  ({Stream<String> output, Future<int> exitCode}) diskoInstall({
    required String flakePath,
    required String diskPath,
    String attribute = 'nixblitz-installer',
  }) {
    final controller = StreamController<String>();
    final exitCodeFuture = () async {
      final process = await Process.start('sudo', [
        '-n', 'disko-install',
        '--flake', '$flakePath#$attribute',
        '--disk', 'main', diskPath,
      ]);
      process.stdout.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) => controller.add(line));
      process.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen((line) => controller.add(line));
      final code = await process.exitCode;
      await controller.close();
      return code;
    }();
    return (output: controller.stream, exitCode: exitCodeFuture);
  }

  /// Generate hardware-configuration.nix for the target system.
  /// Must be called after disko has partitioned and mounted at [mountPoint].
  /// Copies the generated file into the nixblitz config directory.
  Future<bool> generateHardwareConfig({
    required String mountPoint,
    required String targetConfigDir,
  }) async {
    LogService.info('Generating hardware-configuration.nix for $mountPoint');

    // Run nixos-generate-config to detect hardware
    final genResult = await Process.run('sudo', [
      '-n', 'nixos-generate-config', '--root', mountPoint,
    ]);
    if (genResult.exitCode != 0) {
      LogService.error('nixos-generate-config failed: ${genResult.stderr}');
      return false;
    }

    // Copy the generated hardware config to our nixblitz config
    final hwConfigSrc = '$mountPoint/etc/nixos/hardware-configuration.nix';
    final hwConfigDst = '$targetConfigDir/hardware-configuration.nix';

    if (!File(hwConfigSrc).existsSync()) {
      LogService.error('Generated hardware config not found at $hwConfigSrc');
      return false;
    }

    final copyResult = await Process.run('sudo', ['-n', 'cp', hwConfigSrc, hwConfigDst]);
    if (copyResult.exitCode != 0) {
      LogService.error('Failed to copy hardware config: ${copyResult.stderr}');
      return false;
    }

    LogService.info('Hardware config generated and copied to $hwConfigDst');
    return true;
  }

  /// Copy the nixblitz config and install log to the target system.
  /// [sourceDir] is the config directory (e.g. ~/nixblitz).
  /// [logFile] is the path to the install log (e.g. ~/nixblitz.log).
  /// [mountPoint] is where the installed system is mounted (e.g. /mnt).
  Future<bool> copyConfigToTarget({
    required String sourceDir,
    required String logFile,
    required String mountPoint,
  }) async {
    final targetConfigDir = '$mountPoint/home/admin/nixblitz';
    final targetLogDir = '$mountPoint/home/admin';

    LogService.info('Copying config from $sourceDir to $targetConfigDir');

    // Check if mount point exists and is mounted
    final mountCheck = await Process.run('mountpoint', ['-q', mountPoint]);
    if (mountCheck.exitCode != 0) {
      LogService.warn('$mountPoint is not mounted, attempting to mount');
      // disko-install may have unmounted — try to remount
      await Process.run('sudo', ['-n', 'mount', '/dev/disk/by-partlabel/disk-main-root', mountPoint]);
    }

    // Create target directory
    var result = await Process.run('sudo', ['-n', 'mkdir', '-p', targetConfigDir]);
    if (result.exitCode != 0) {
      LogService.error('Failed to create target dir: ${result.stderr}');
      return false;
    }

    // Copy config directory (try rsync, fall back to cp)
    result = await Process.run('sudo', [
      '-n', 'rsync', '-av', '--delete', '$sourceDir/', '$targetConfigDir/',
    ]);
    if (result.exitCode != 0) {
      LogService.warn('rsync failed (${result.exitCode}): ${result.stderr}');
      LogService.info('Falling back to cp -r');
      result = await Process.run('sudo', [
        '-n', 'cp', '-r', '$sourceDir/.', '$targetConfigDir/',
      ]);
      if (result.exitCode != 0) {
        LogService.error('cp also failed (${result.exitCode}): ${result.stderr}');
        return false;
      }
    }

    // Copy install log
    if (File(logFile).existsSync()) {
      LogService.info('Copying install log to $targetLogDir/nixblitz.log');
      result = await Process.run('sudo', [
        '-n', 'cp', logFile, '$targetLogDir/nixblitz.log',
      ]);
      if (result.exitCode != 0) {
        LogService.warn('Failed to copy log file: ${result.stderr}');
        // Non-fatal — continue
      }
    }

    // Fix ownership (UID 1000 = first normal user "admin")
    result = await Process.run('sudo', [
      '-n', 'chown', '-R', '1000:100', targetConfigDir,
    ]);
    if (result.exitCode != 0) {
      LogService.warn('Failed to chown config dir: ${result.stderr}');
    }

    // Fix log file ownership too
    await Process.run('sudo', [
      '-n', 'chown', '1000:100', '$targetLogDir/nixblitz.log',
    ]);

    LogService.info('Config and log copied to target successfully');
    return true;
  }

  static String? parseDiskoStep(String line) {
    if (line.contains('sgdisk')) return 'Partitioning disk...';
    if (line.contains('mkfs') || line.contains('formatting')) return 'Formatting partitions...';
    if (line.contains('mount ')) return 'Mounting filesystems...';
    if (line.contains('copying')) return 'Copying NixOS store paths...';
    if (line.contains('boot loader')) return 'Installing bootloader...';
    return null;
  }
}

/// Map a detected platform to the `nixosConfigurations.<attribute>`
/// the install wizard's `disko-install` should target.
///
/// Mirrors `system_service.rebuildAttributeFor` but for the
/// install-time path: x86 / VM operators land on
/// `nixblitz-installer` (passwordless sudo, x86_64-linux); Pi 5
/// operators land on `nixblitz-pi5-installer` (passwordless sudo,
/// aarch64-linux, layered on `nvmd/nixos-raspberrypi`).
///
/// Unknown platforms fall through to the x86 default. That'll
/// fail at install time when `disko-install` rejects the
/// architecture — the right failure mode, since silently picking
/// the wrong one would just shift the failure into a worse spot.
String installerAttributeFor(String platform) =>
    platform == 'pi5' ? 'nixblitz-pi5-installer' : 'nixblitz-installer';
