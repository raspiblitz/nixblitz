import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';

/// Exit the TUI and leave the terminal in a sane state (line mode + echo
/// restored). Pass [restartExitCode] to let the shell wrapper in
/// `bin/nixblitz` re-launch us with the freshly-installed binary.
void shutdownWithTerminalRestore([int exitCode = 0]) {
  try {
    if (stdin.hasTerminal) {
      stdin.lineMode = true;
      stdin.echoMode = true;
    }
  } catch (e) {
    LogService.warn('Failed to restore terminal mode before shutdown: $e');
  }
  shutdownApp(exitCode);
}
