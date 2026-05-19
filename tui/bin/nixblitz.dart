import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:common/common.dart';
import 'package:common/src/streamers/system_stats_streamer.dart';
import 'package:nocterm/nocterm.dart';
import 'package:tui/src/build_info.dart';
import 'package:tui/src/cli/check_cli.dart';
import 'package:tui/src/cli/init_cli.dart';
import 'package:tui/src/cli/plugin_cli.dart';
import 'package:tui/src/cli/update_cli.dart';
import 'package:tui/src/ui/app.dart';

const int buildNumber = 9;

/// `nixblitz` CLI surface, built on `package:args`' [CommandRunner]
/// + cli_completion's [CompletionCommandRunner] base for tab
/// completion. Each operator-facing subcommand lives in its own
/// `tui/lib/src/cli/*_cli.dart` file as a `Command<int>` subclass;
/// this class only wires them up.
///
/// Auto-install is off — operators run
/// `nixblitz install-completion-files` once explicitly if they
/// want tab completion. Avoids silently mutating `~/.bashrc` from
/// the `admin` user that systemd timers spawn.
class NixblitzCommandRunner extends CompletionCommandRunner<int> {
  NixblitzCommandRunner({required this.baseDir})
    : super('nixblitz', 'NixBlitz — Bitcoin/Lightning node manager on NixOS') {
    argParser.addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print version information.',
    );
    addCommand(CheckCommand(baseDir));
    addCommand(UpdateCommand(baseDir));
    addCommand(InitCommand(baseDir));
    addCommand(PluginCommand(baseDir));
  }

  final String baseDir;

  @override
  bool get enableAutoInstall => false;

  @override
  Future<int?> run(Iterable<String> args) async {
    // Top-level --version short-circuits before any command runs.
    // CommandRunner's parse() would otherwise print usage when the
    // argument list has no subcommand attached.
    final results = parse(args);
    if (results['version'] as bool) {
      print('nixblitz $buildVersionString');
      return 0;
    }
    return await runCommand(results) ?? 0;
  }
}

/// Auto-refresh templates that drifted between this binary's
/// embedded set and the operator's on-disk `~/nixblitz/`. Runs as
/// the FIRST thing the TUI does after CLI subcommand dispatch.
///
/// Why up here instead of inside the apply flow's
/// `_maybeAutoRewriteTemplates`: that runs in the OLD binary's
/// in-memory process. After a `nixos-rebuild switch` installs a
/// new binary mid-flow, only the NEW binary on startup can write
/// its own embedded templates to disk. The in-flow refresh writes
/// the OLD binary's set, and the on-disk drift against the NEW
/// binary persists until the operator triggers another refresh
/// manually — which they often don't, because the rebuild succeeded
/// and they don't realize the templates haven't caught up.
///
/// Running here closes that loop: every new binary's first start
/// auto-heals any drift introduced by the version bump.
Future<void> _autoRefreshTemplatesIfDrifted(String baseDir) async {
  // Skip on installer images — templates haven't been scaffolded
  // onto disk yet, drift detection is meaningless.
  if (isInstallerEnvironment()) return;
  // Skip on fresh / unconfigured systems — the app's refusal screen
  // handles those cases; refreshing would overwrite nothing or
  // create files where there's no profile yet.
  if (!File('$baseDir/config.json').existsSync()) return;

  final drift = detectTemplatesDrift(baseDir);
  if (!drift.hasDrift) return;

  LogService.info(
    'Templates drift at startup: '
    'modified=${drift.modified}, missing=${drift.missing}; '
    'auto-refreshing',
  );

  try {
    final driftedPaths = <String>[...drift.missing, ...drift.modified];
    ScaffoldService(targetDir: baseDir).refreshTemplatesSync();
    final git = GitService(repoDir: baseDir);
    final committed = await git.commitPaths(
      driftedPaths,
      'Refresh templates from TUI (startup)',
    );
    LogService.info(
      'Startup auto-refresh: ${driftedPaths.length} drifted paths, '
      'committed=$committed',
    );
  } catch (e, st) {
    LogService.error('Startup auto-refresh failed', e, st);
  }
}

/// Treat any non-empty argv as a CLI invocation — CommandRunner
/// routes known subcommands, reports "Could not find a command
/// named 'X'" with a "did you mean" suggestion for typos, and
/// prints help on `--help`. Only bare `nixblitz` falls through to
/// the TUI; that's the primary UX and CommandRunner's empty-args
/// "print help" default is the wrong fit for it.
bool _looksLikeCli(List<String> arguments) => arguments.isNotEmpty;

void main(List<String> arguments) async {
  // Streamer dispatch: stays outside the CommandRunner so it
  // doesn't appear in completions / help (it's a TUI subprocess,
  // not an operator-facing command). Must run before everything
  // else so the binary can be invoked as a subprocess from
  // streamer subprocess sources.
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

  final homeDir = Platform.environment['HOME'] ?? '/root';
  final baseDir = '$homeDir/nixblitz';

  // CLI dispatch: routes through CommandRunner. Hidden completion
  // verbs (completion / install-completion-files /
  // uninstall-completion-files) are auto-registered by
  // CompletionCommandRunner.
  if (_looksLikeCli(arguments)) {
    LogService.init(homeDir);
    LogService.info('nixblitz $buildVersionString (build #$buildNumber) [cli]');
    final runner = NixblitzCommandRunner(baseDir: baseDir);
    try {
      final code = await runner.run(arguments);
      exit(code ?? 0);
    } on UsageException catch (e) {
      stderr.writeln(e);
      exit(64);
    }
  }

  // TUI mode: bare `nixblitz`. Initialize logging, self-heal
  // template drift, then runApp.
  final startupBinary = Platform.resolvedExecutable;
  LogService.init(homeDir);
  LogService.info('nixblitz $buildVersionString (build #$buildNumber)');
  LogService.info('startup binary: $startupBinary');

  await _autoRefreshTemplatesIfDrifted(baseDir);

  NoctermError.onError = (details) {
    LogService.error(
      'Nocterm: ${details.context ?? "unknown context"}',
      details.exception,
      details.stack,
    );
  };

  runZonedGuarded(
    () {
      runApp(NixBlitzApp(baseDir: baseDir, startupBinary: startupBinary));
    },
    (error, stackTrace) {
      LogService.error('Uncaught error', error, stackTrace);
    },
  );
}
