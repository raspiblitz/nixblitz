import 'dart:io';

import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/process_runner.dart';

/// Detect whether we're running inside a NixOS installer image —
/// the x86 minimal ISO, the Pi 5 SD-image installer, etc. These
/// are the environments where the TUI should start in install mode
/// and disk-wiping commands are safe to run.
///
/// Two signals, ORed together so each image variant is covered:
///
/// 1. **Root filesystem is tmpfs.** True on the upstream NixOS
///    minimal ISO (the x86 walkthrough's path), where the rootfs
///    overlays a tmpfs on top of the read-only squashfs. False
///    on installer images that boot writable disk images (like
///    nvmd's Pi 5 sdimage-installer, which roots on a real ext4
///    partition).
///
/// 2. **`VARIANT_ID=installer` in `/etc/os-release`.** Set by
///    upstream nixos-images for every installer flavour. This is
///    what catches the Pi 5 case the tmpfs check misses. Installed
///    NixOS systems either omit `VARIANT_ID` or set it to something
///    else.
bool isInstallerEnvironment() {
  try {
    final result = runCheckedSync('stat', ['-f', '-c', '%T', '/']);
    if (result.stdout.trim() == 'tmpfs') return true;
  } catch (e) {
    LogService.warn('Could not stat / for tmpfs check: $e');
  }
  try {
    final content = File('/etc/os-release').readAsStringSync();
    // Match `VARIANT_ID=installer` (with or without quotes) on its
    // own line. Avoid substring matches like `BUILD_ID=…installer…`
    // — only the explicit field counts.
    final hit = RegExp(
      r'^VARIANT_ID="?installer"?$',
      multiLine: true,
    ).hasMatch(content);
    if (hit) return true;
  } catch (e) {
    LogService.warn('Could not read /etc/os-release: $e');
  }
  return false;
}
