import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:common/src/models/install_state.dart';
import 'package:common/src/services/log_service.dart';

class InstallService {
  Future<List<DiskInfo>> listDisks() async {
    final result = await Process.run('lsblk', [
      '--json',
      '--bytes',
      '--output',
      'NAME,SIZE,MODEL,RM,TYPE',
      '--nodeps',
    ]);
    return parseLsblkOutput(result.stdout as String);
  }

  static List<DiskInfo> parseLsblkOutput(String output) {
    final json = jsonDecode(output) as Map<String, dynamic>;
    final devices = json['blockdevices'] as List<dynamic>;
    return devices
        .where((d) => (d['type'] as String) == 'disk')
        .where((d) => !isVirtualDiskName(d['name'] as String))
        .map((d) => DiskInfo.fromLsblkJson(d as Map<String, dynamic>))
        .toList();
  }

  /// True for kernel-virtual block devices that show up in
  /// `lsblk --type disk` but are never legitimate install
  /// targets: compressed-RAM swap (`zram*`), loopback files
  /// (`loop*`), device-mapper / encrypted / LVM (`dm-*`), MD
  /// software RAID virtual blocks (`md*`), and read-only optical
  /// (`sr*`). Filtering these is unconditional — there's no
  /// flow where you'd want to install NixBlitz onto zram. Other
  /// "non-viable" cases (zero-byte card readers, the live boot
  /// device, undersized disks) belong behind the Show-all toggle
  /// proposed in issue #19; this is the unconditional half.
  static bool isVirtualDiskName(String name) {
    return name.startsWith('zram') ||
        name.startsWith('loop') ||
        name.startsWith('dm-') ||
        name.startsWith('md') ||
        name.startsWith('sr');
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

  /// Parse `/proc/meminfo`'s `MemTotal:` line and return the
  /// total in bytes. Returns 0 if the line is missing — caller
  /// treats that as "RAM unknown, assume worst case".
  static int parseMemTotalBytes(String contents) {
    final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(contents);
    if (match == null) return 0;
    return int.parse(match.group(1)!) * 1024;
  }

  /// Sum the active swap devices in `/proc/swaps`. Returns 0
  /// when no swap is configured (header-only file). Used by the
  /// pre-install check to decide whether the live ISO needs a
  /// zram fallback before the heavy nix eval kicks off.
  static int parseProcSwapsTotalBytes(String contents) {
    // Format: header line + one row per active swap device. The
    // size column is in 1024-byte units (man 5 proc).
    //   Filename               Type       Size    Used  Priority
    //   /dev/zram0             partition  6291452 0     100
    final lines = contents.split('\n');
    if (lines.length <= 1) return 0;
    var totalBytes = 0;
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length < 3) continue;
      final kb = int.tryParse(fields[2]);
      if (kb == null) continue;
      totalBytes += kb * 1024;
    }
    return totalBytes;
  }

  /// How much zram swap to set up before the install eval, in
  /// bytes. Returns 0 when existing swap covers the gap or no
  /// action is needed.
  ///
  /// Rationale: the live NixOS ISO sizes root tmpfs at roughly
  /// half RAM; the Bitcoin / Lightning eval can spill over that
  /// on machines with ≤8 GB. zram compresses ~2-3× in practice
  /// on Nix store paths, so a RAM-sized zram device gives
  /// effective 2-3× headroom and is lazily allocated (no actual
  /// RAM cost until used). If the live ISO already has swap
  /// configured (zramSwap NixOS module, manual mkswap, etc.),
  /// don't second-guess it.
  static int recommendedZramBytes({
    required int memTotalBytes,
    required int existingSwapBytes,
  }) {
    if (existingSwapBytes > 0) return 0;
    if (memTotalBytes <= 0) return 0;
    return memTotalBytes;
  }

  Future<SystemInfo> detectSystem() async {
    final results = await Future.wait([
      detectPlatform(),
      getMemoryMb(),
      listDisks(),
    ]);
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
  /// Pre-install memory check. Reads RAM + active swap, and if
  /// the live ISO has no swap configured, sets up zram-backed
  /// swap sized to RAM. Returns a record with the lines the TUI
  /// should append to its install log and a success flag — even
  /// on failure the install continues, since plenty of RAM
  /// makes zram unnecessary and we'd rather burn a few extra
  /// log lines than block a healthy install.
  ///
  /// Idempotent: if `/proc/swaps` already has any device, this
  /// is a no-op (logged as such).
  Future<({bool wasNeeded, bool succeeded, List<String> log})>
  ensureSwapForInstall() async {
    final log = <String>[];
    int memTotal = 0;
    int swapTotal = 0;
    try {
      memTotal = parseMemTotalBytes(await File('/proc/meminfo').readAsString());
    } catch (e) {
      log.add('  (could not read /proc/meminfo: $e — skipping swap setup)');
      LogService.warn('ensureSwapForInstall: meminfo unreadable: $e');
      return (wasNeeded: false, succeeded: true, log: log);
    }
    try {
      swapTotal = parseProcSwapsTotalBytes(
        await File('/proc/swaps').readAsString(),
      );
    } catch (e) {
      log.add('  (could not read /proc/swaps: $e — skipping swap setup)');
      LogService.warn('ensureSwapForInstall: swaps unreadable: $e');
      return (wasNeeded: false, succeeded: true, log: log);
    }

    log.add(
      '  RAM ${_humanGiB(memTotal)} GB, '
      'swap ${_humanGiB(swapTotal)} GB',
    );

    final zramTarget = recommendedZramBytes(
      memTotalBytes: memTotal,
      existingSwapBytes: swapTotal,
    );
    if (zramTarget == 0) {
      log.add(
        swapTotal > 0
            ? '  swap already configured; skipping zram setup'
            : '  RAM info unavailable; skipping zram setup',
      );
      return (wasNeeded: false, succeeded: true, log: log);
    }

    log.add(
      '  no swap detected — enabling ${_humanGiB(zramTarget)} GB zram '
      '(compresses ~2-3×; lazy-allocated, no upfront RAM cost)',
    );
    final ok = await _enableZramSwap(zramTarget, log);
    return (wasNeeded: true, succeeded: ok, log: log);
  }

  /// Run the four-step zram setup the user would otherwise type
  /// by hand: `modprobe zram` → write disksize to sysfs → mkswap
  /// → swapon. Each step's failure is captured in [log] and the
  /// caller decides whether to proceed.
  Future<bool> _enableZramSwap(int sizeBytes, List<String> log) async {
    final modprobe = await Process.run('sudo', [
      '-n',
      'modprobe',
      'zram',
      'num_devices=1',
    ]);
    if (modprobe.exitCode != 0) {
      log.add('  modprobe zram failed: ${(modprobe.stderr as String).trim()}');
      return false;
    }
    // Write the desired disksize to sysfs via tee. echo+redirect
    // would need a shell; piping through tee is cleaner and
    // avoids shell-quoting concerns even though `sizeBytes` is
    // produced by us, not the user.
    final tee = await Process.start('sudo', [
      '-n',
      'tee',
      '/sys/block/zram0/disksize',
    ], mode: ProcessStartMode.normal);
    tee.stdin.writeln('$sizeBytes');
    await tee.stdin.close();
    // Drain stdout/stderr so the process can exit cleanly.
    await tee.stdout.drain<void>();
    await tee.stderr.drain<void>();
    final teeCode = await tee.exitCode;
    if (teeCode != 0) {
      log.add('  failed to set zram disksize: exit $teeCode');
      return false;
    }
    final mkswap = await Process.run('sudo', ['-n', 'mkswap', '/dev/zram0']);
    if (mkswap.exitCode != 0) {
      log.add('  mkswap failed: ${(mkswap.stderr as String).trim()}');
      return false;
    }
    final swapon = await Process.run('sudo', [
      '-n',
      'swapon',
      '-p',
      '100',
      '/dev/zram0',
    ]);
    if (swapon.exitCode != 0) {
      log.add('  swapon failed: ${(swapon.stderr as String).trim()}');
      return false;
    }
    log.add('  zram swap enabled (${_humanGiB(sizeBytes)} GB)');
    return true;
  }

  static String _humanGiB(int bytes) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

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
        '-n',
        'disko-install',
        '--flake',
        '$flakePath#$attribute',
        '--disk',
        'main',
        diskPath,
      ]);
      process.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) => controller.add(line));
      process.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((line) => controller.add(line));
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
      '-n',
      'nixos-generate-config',
      '--root',
      mountPoint,
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

    final copyResult = await Process.run('sudo', [
      '-n',
      'cp',
      hwConfigSrc,
      hwConfigDst,
    ]);
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
      await Process.run('sudo', [
        '-n',
        'mount',
        '/dev/disk/by-partlabel/disk-main-root',
        mountPoint,
      ]);
    }

    // Create target directory
    var result = await Process.run('sudo', [
      '-n',
      'mkdir',
      '-p',
      targetConfigDir,
    ]);
    if (result.exitCode != 0) {
      LogService.error('Failed to create target dir: ${result.stderr}');
      return false;
    }

    // Copy config directory (try rsync, fall back to cp)
    result = await Process.run('sudo', [
      '-n',
      'rsync',
      '-av',
      '--delete',
      '$sourceDir/',
      '$targetConfigDir/',
    ]);
    if (result.exitCode != 0) {
      LogService.warn('rsync failed (${result.exitCode}): ${result.stderr}');
      LogService.info('Falling back to cp -r');
      result = await Process.run('sudo', [
        '-n',
        'cp',
        '-r',
        '$sourceDir/.',
        '$targetConfigDir/',
      ]);
      if (result.exitCode != 0) {
        LogService.error(
          'cp also failed (${result.exitCode}): ${result.stderr}',
        );
        return false;
      }
    }

    // Copy install log
    if (File(logFile).existsSync()) {
      LogService.info('Copying install log to $targetLogDir/nixblitz.log');
      result = await Process.run('sudo', [
        '-n',
        'cp',
        logFile,
        '$targetLogDir/nixblitz.log',
      ]);
      if (result.exitCode != 0) {
        LogService.warn('Failed to copy log file: ${result.stderr}');
        // Non-fatal — continue
      }
    }

    // Fix ownership (UID 1000 = first normal user "admin")
    result = await Process.run('sudo', [
      '-n',
      'chown',
      '-R',
      '1000:100',
      targetConfigDir,
    ]);
    if (result.exitCode != 0) {
      LogService.warn('Failed to chown config dir: ${result.stderr}');
    }

    // Fix log file ownership too
    await Process.run('sudo', [
      '-n',
      'chown',
      '1000:100',
      '$targetLogDir/nixblitz.log',
    ]);

    LogService.info('Config and log copied to target successfully');
    return true;
  }

  static String? parseDiskoStep(String line) {
    if (line.contains('sgdisk')) return 'Partitioning disk...';
    if (line.contains('mkfs') || line.contains('formatting'))
      return 'Formatting partitions...';
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
