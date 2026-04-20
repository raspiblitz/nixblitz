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
    if (cpuinfo.contains('Raspberry Pi 5')) return 'pi5';
    if (cpuinfo.contains('Raspberry Pi 4')) return 'pi4';
    if (cpuinfo.contains('Raspberry Pi')) return 'pi4';
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

  ({Stream<String> output, Future<int> exitCode}) diskoInstall({
    required String flakePath,
    required String diskPath,
  }) {
    final controller = StreamController<String>();
    final exitCodeFuture = () async {
      final process = await Process.start('sudo', [
        'disko-install', '--flake', '$flakePath#nixblitz', '--disk', 'main', diskPath,
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
      'nixos-generate-config', '--root', mountPoint,
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

    final copyResult = await Process.run('sudo', ['cp', hwConfigSrc, hwConfigDst]);
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

    // Create target directory
    var result = await Process.run('sudo', ['mkdir', '-p', targetConfigDir]);
    if (result.exitCode != 0) {
      LogService.error('Failed to create target dir: ${result.stderr}');
      return false;
    }

    // Copy config directory
    result = await Process.run('sudo', [
      'rsync', '-av', '--delete', '$sourceDir/', '$targetConfigDir/',
    ]);
    if (result.exitCode != 0) {
      LogService.error('Failed to rsync config: ${result.stderr}');
      return false;
    }

    // Copy install log
    if (File(logFile).existsSync()) {
      LogService.info('Copying install log to $targetLogDir/nixblitz.log');
      result = await Process.run('sudo', [
        'cp', logFile, '$targetLogDir/nixblitz.log',
      ]);
      if (result.exitCode != 0) {
        LogService.warn('Failed to copy log file: ${result.stderr}');
        // Non-fatal — continue
      }
    }

    // Fix ownership (UID 1000 = first normal user "admin")
    result = await Process.run('sudo', [
      'chown', '-R', '1000:100', targetConfigDir,
    ]);
    if (result.exitCode != 0) {
      LogService.warn('Failed to chown config dir: ${result.stderr}');
    }

    // Fix log file ownership too
    await Process.run('sudo', [
      'chown', '1000:100', '$targetLogDir/nixblitz.log',
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
