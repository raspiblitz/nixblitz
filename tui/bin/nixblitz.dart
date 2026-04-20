import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';
import 'package:tui/src/ui/app.dart';

const String version = '0.1.0';
const int buildNumber = 8;

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print version information',
    );

  try {
    final results = parser.parse(arguments);

    if (results['version'] as bool) {
      print('nixblitz version: $version');
      exit(0);
    }

    final homeDir = Platform.environment['HOME'] ?? '/root';
    final baseDir = '$homeDir/nixblitz';

    // Initialize logging
    LogService.init(homeDir);
    LogService.info('build #$buildNumber');

    // Hook into nocterm's error reporting (catches layout errors, paint errors, etc.)
    NoctermError.onError = (details) {
      LogService.error(
        'Nocterm: ${details.context ?? "unknown context"}',
        details.exception,
        details.stack,
      );
    };

    // Catch uncaught async errors and log them
    runZonedGuarded(
      () {
        runApp(NixBlitzApp(baseDir: baseDir));
      },
      (error, stackTrace) {
        LogService.error('Uncaught error', error, stackTrace);
      },
    );
  } on FormatException catch (e) {
    print(e.message);
    exit(1);
  }
}
