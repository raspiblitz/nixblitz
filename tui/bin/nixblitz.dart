import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';
import 'package:common/src/streamers/system_stats_streamer.dart';
import 'package:tui/src/build_info.dart';
import 'package:tui/src/cli/check_cli.dart';
import 'package:tui/src/cli/plugin_cli.dart';
import 'package:tui/src/ui/app.dart';

const int buildNumber = 9;

void main(List<String> arguments) async {
  // Streamer dispatch: runs BEFORE TUI startup so the binary can be invoked as a subprocess.
  if (arguments.isNotEmpty && arguments.first == 'streamer') {
    if (arguments.length < 2) {
      stderr.writeln('usage: nixblitz streamer <name> [args...]');
      exit(2);
    }
    final name = arguments[1];
    final streamerArgs = arguments.skip(2).toList();
    switch (name) {
      case 'system-stats':
        await systemStatsMain(streamerArgs);
        return;
      default:
        stderr.writeln('unknown streamer: $name');
        exit(2);
    }
  }

  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Print this help')
    ..addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print version information',
    )
    ..addCommand(
      'check',
      ArgParser()
        ..addCommand('light', ArgParser())
        ..addCommand('heavy', ArgParser()),
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
        ..addCommand('list', ArgParser()..addFlag('all', negatable: false))
        ..addCommand(
          'update',
          ArgParser()
            ..addFlag('all', negatable: false)
            ..addFlag('insecure', negatable: false),
        )
        ..addCommand('pin', ArgParser())
        ..addCommand('unpin', ArgParser()),
    );

  // Pre-parse `help` as a positional verb so `nixblitz help` and
  // `nixblitz help <subcommand>` work alongside the conventional
  // `--help` / `-h` flag. ArgParser doesn't model a no-dash help
  // verb natively; intercepting before parse keeps the rest of the
  // arg shape (with subcommands like `check light`) parseable.
  if (arguments.isNotEmpty && arguments.first == 'help') {
    _printHelp(arguments.length > 1 ? arguments[1] : null);
    exit(0);
  }

  try {
    final results = parser.parse(arguments);

    if (results['help'] as bool) {
      _printHelp(null);
      exit(0);
    }

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
    if (results.command?.name == 'check') {
      final code = await runCheckCli(results.command!, baseDir);
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

/// Prints top-level help, or subcommand help when [topic] is one of
/// the known subcommands.
void _printHelp(String? topic) {
  if (topic == 'plugin') {
    print(
      'Usage: nixblitz plugin <add|remove|list|update|pin|unpin> [options]\n'
      '\n'
      '  add <url> [--branch X] [--subdir Y] [--yes] [--insecure]\n'
      '      Install a plugin from a git URL.\n'
      '  remove <id>\n'
      '      Soft-delete a plugin (tombstone preserves the pin).\n'
      '  list [--all]\n'
      '      List active plugins; --all also shows tombstones.\n'
      '  update [<id>] [--all] [--insecure]\n'
      '      Pull a plugin\'s upstream into its pinned rev (or all\n'
      '      auto-update plugins with --all). Does not rebuild.\n'
      '  pin <id>\n'
      '      Freeze the plugin at its current rev (auto_update=false).\n'
      '  unpin <id>\n'
      '      Re-enable auto-updates for the plugin.',
    );
    return;
  }
  if (topic == 'check') {
    print(
      'Usage: nixblitz check <light|heavy>\n'
      '\n'
      '  light\n'
      '      Probe each flake input + active plugin\'s upstream HEAD\n'
      '      via forge APIs. Fast (~5s); writes update-status.json.\n'
      '  heavy\n'
      '      Run a full nix flake update + nvd diff against\n'
      '      /run/current-system in a tmpdir. Slow (1–10 min, ~125\n'
      '      MB to /tmp); writes update-status.json.',
    );
    return;
  }

  print(
    'nixblitz $buildVersionString — Bitcoin/Lightning node manager on NixOS\n'
    '\n'
    'Usage:\n'
    '  nixblitz                       Launch the interactive TUI (default)\n'
    '  nixblitz --version, -v         Print version\n'
    '  nixblitz --help,    -h         Print this help\n'
    '  nixblitz help <subcommand>     Print help for a subcommand\n'
    '  nixblitz <subcommand> [args]   Run a one-shot subcommand\n'
    '\n'
    'Subcommands:\n'
    '  plugin    Manage installed plugins (add / remove / list / update / pin / unpin)\n'
    '  check     Run an update check now (light / heavy)\n'
    '\n'
    'The TUI is the default UI; subcommands are one-shot operations\n'
    'for scripting and the systemd update-check timers. See\n'
    '`nixblitz help <subcommand>` for per-subcommand details.',
  );
}
