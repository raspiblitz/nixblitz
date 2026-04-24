import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';
import 'package:tui/src/build_info.dart';
import 'package:tui/src/cli/plugin_cli.dart';
import 'package:tui/src/ui/app.dart';

const int buildNumber = 9;

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print version information',
    )
    ..addCommand(
      'plugin',
      ArgParser()
        ..addCommand(
          'add',
          ArgParser()
            ..addOption('branch', defaultsTo: 'main')
            ..addOption('subdir')
            ..addFlag('yes', abbr: 'y', negatable: false)
            ..addFlag('insecure', negatable: false),
        )
        ..addCommand('remove', ArgParser())
        ..addCommand(
          'list',
          ArgParser()..addFlag('all', negatable: false),
        )
        ..addCommand(
          'refresh',
          ArgParser()
            ..addFlag('all', negatable: false)
            ..addFlag('insecure', negatable: false),
        ),
    );

  try {
    final results = parser.parse(arguments);

    if (results['version'] as bool) {
      print('nixblitz $buildVersionString');
      exit(0);
    }

    final homeDir = Platform.environment['HOME'] ?? '/root';
    final baseDir = '$homeDir/nixblitz';
    final startupBinary = Platform.resolvedExecutable;

    // Initialize logging
    LogService.init(homeDir);
    LogService.info('nixblitz $buildVersionString (build #$buildNumber)');
    LogService.info('startup binary: $startupBinary');

    // CLI subcommands exit before the TUI starts — they're one-shot
    // operations that print a result.
    if (results.command?.name == 'plugin') {
      final code = await runPluginCli(results.command!, baseDir);
      exit(code);
    }

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
        runApp(NixBlitzApp(baseDir: baseDir, startupBinary: startupBinary));
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
