import 'dart:io';

/// Simple file logger for debugging.
/// Writes to ~/nixblitz.log using synchronous append.
class LogService {
  static File? _logFile;

  /// Initialize the logger. Call once at startup.
  static void init(String homeDir) {
    _logFile = File('$homeDir/nixblitz.log');
    info('nixblitz started');
  }

  /// Log an informational message.
  static void info(String message) {
    _write('INFO', message);
  }

  /// Log an error with optional stack trace.
  static void error(String message, [Object? err, StackTrace? stackTrace]) {
    final buf = StringBuffer(message);
    if (err != null) buf.write('\n  $err');
    if (stackTrace != null) buf.write('\n  $stackTrace');
    _write('ERROR', buf.toString());
  }

  /// Log a warning.
  static void warn(String message) {
    _write('WARN', message);
  }

  static void _write(String level, String message) {
    _logFile?.writeAsStringSync(
      '${DateTime.now().toIso8601String()} [$level] $message\n',
      mode: FileMode.append,
    );
  }
}
