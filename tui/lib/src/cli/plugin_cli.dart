import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:common/common.dart';

/// Entry point for `nixblitz plugin <verb> ...`. Runs outside the
/// TUI (no `runApp`, no terminal takeover) so it can print and exit.
///
/// Supported verbs in Phase 1: `add`, `remove`, `list`. `pin /
/// unpin / update` land in Phase 5 alongside the Update-view
/// integration (see docs/decisions/plugins.md D11).
Future<int> runPluginCli(ArgResults pluginArgs, String baseDir) async {
  final sub = pluginArgs.command;
  if (sub == null) {
    stderr.writeln('Usage: nixblitz plugin <add|remove|list> ...');
    return 2;
  }

  final svc = PluginService(baseDir: baseDir);

  try {
    switch (sub.name) {
      case 'add':
        return await _runAdd(svc, sub);
      case 'remove':
        return await _runRemove(svc, sub);
      case 'list':
        return await _runList(svc, sub);
      default:
        stderr.writeln('unknown verb: ${sub.name}');
        return 2;
    }
  } catch (e) {
    stderr.writeln('error: $e');
    return 1;
  }
}

Future<int> _runAdd(PluginService svc, ArgResults args) async {
  final rest = args.rest;
  if (rest.isEmpty) {
    stderr.writeln(
      'Usage: nixblitz plugin add <url> '
      '[--branch <name>] [--subdir <path>] [-y] [--insecure]',
    );
    return 2;
  }
  final url = rest.first;
  final branch = args['branch'] as String;
  final subdir = args['subdir'] as String?;
  final yes = args['yes'] as bool;
  final insecure = args['insecure'] as bool;

  // Pre-consent: show the manifest permissions block the plugin
  // will request. We do this by doing a dry run that parses but
  // doesn't land the plugin — cheapest option in Phase 1 is just
  // to install and trust the user, prompting before the clone.
  if (!yes) {
    stdout.writeln('About to install plugin from: $url');
    stdout.writeln('Branch: $branch');
    if (subdir != null) stdout.writeln('Subdir: $subdir');
    if (insecure) stdout.writeln('  (via --insecure)');
    stdout.write('Proceed? [y/N]: ');
    final line = stdin.readLineSync() ?? '';
    if (line.trim().toLowerCase() != 'y' &&
        line.trim().toLowerCase() != 'yes') {
      stdout.writeln('aborted');
      return 1;
    }
  }

  final entry = await svc.install(
    url,
    branch: branch,
    allowInsecure: insecure,
    subdir: subdir,
  );
  stdout.writeln('installed ${entry.id}');
  stdout.writeln('  pin:   ${_shortRev(entry.pinnedRev)}');
  stdout.writeln('  dir:   plugins/${entry.dirName}');
  stdout.writeln('  branch: ${entry.branch}');
  stdout.writeln();
  stdout.writeln(
    'Run the Apply view (`a` in the TUI) to commit and rebuild.',
  );
  return 0;
}

Future<int> _runRemove(PluginService svc, ArgResults args) async {
  final rest = args.rest;
  if (rest.isEmpty) {
    stderr.writeln('Usage: nixblitz plugin remove <id>');
    return 2;
  }
  final id = rest.first;
  await svc.remove(id);
  stdout.writeln('removed $id (tombstoned)');
  stdout.writeln(
    'Run the Apply view (`a` in the TUI) to commit and rebuild.',
  );
  return 0;
}

Future<int> _runList(PluginService svc, ArgResults args) async {
  final all = args['all'] as bool;
  final plugins = await svc.list(includeTombstones: all);
  if (plugins.isEmpty) {
    stdout.writeln(all ? '(no plugins)' : '(no plugins installed)');
    return 0;
  }
  // Compact table. Not pretty-aligned; plugin lists stay short.
  stdout.writeln('ID  |  BRANCH  |  PIN      |  ENABLED  |  INSTALLED');
  for (final p in plugins) {
    final tombMark = p.isTombstone ? '  [removed]' : '';
    stdout.writeln(
      '${p.id}  |  ${p.branch}  |  ${_shortRev(p.pinnedRev)}  |  '
      '${p.enabled}  |  ${p.installedAt.toIso8601String().split("T").first}'
      '$tombMark',
    );
  }
  return 0;
}

String _shortRev(String rev) => rev.length >= 7 ? rev.substring(0, 7) : rev;
