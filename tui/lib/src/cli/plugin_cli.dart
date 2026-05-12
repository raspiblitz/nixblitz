import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:common/common.dart';

import '../ui/widgets/signature_label.dart';

/// Entry point for `nixblitz plugin <verb> ...`. Runs outside the
/// TUI (no `runApp`, no terminal takeover) so it can print and exit.
///
/// Supported verbs in Phase 1: `add`, `remove`, `list`. `pin /
/// unpin / update` land in Phase 5 alongside the Update-view
/// integration (see docs/decisions/plugins.md D11).
Future<int> runPluginCli(ArgResults pluginArgs, String baseDir) async {
  final sub = pluginArgs.command;
  if (sub == null) {
    stderr.writeln(
      'Usage: nixblitz plugin <add|remove|list|update|pin|unpin> ...',
    );
    return 2;
  }

  final pluginService = PluginService(baseDir: baseDir);

  try {
    switch (sub.name) {
      case 'add':
        return await _runAdd(pluginService, sub);
      case 'remove':
        return await _runRemove(pluginService, sub);
      case 'list':
        return await _runList(pluginService, sub);
      case 'update':
        return await _runRefresh(pluginService, sub);
      case 'pin':
        return await _runPin(pluginService, sub, pin: true);
      case 'unpin':
        return await _runPin(pluginService, sub, pin: false);
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

  // Consent flow: run the clone + manifest fetch first so the
  // prompt has real metadata (name, description, pinned rev) to
  // show. The PluginService callback hooks in at the right point
  // — after parse, before any state lands on disk. `--yes`
  // bypasses by passing null.
  try {
    final marker = await svc.install(
      url,
      branch: branch,
      allowInsecure: insecure,
      subdir: subdir,
      confirm: yes
          ? null
          : (preview) => _askConsent(
              preview,
              requestedSubdir: subdir,
              insecure: insecure,
            ),
    );
    stdout.writeln('installed ${marker.id}');
    stdout.writeln('  pin:    ${_shortRev(marker.rev)}');
    stdout.writeln('  dir:    plugins/${marker.id}');
    stdout.writeln('  branch: ${marker.branch}');
    stdout.writeln('  url:    ${marker.url}');
    stdout.writeln();
    stdout.writeln(
      'Run the Apply view (`a` in the TUI) to commit and rebuild.',
    );
    return 0;
  } on PluginInstallCancelled {
    stdout.writeln('aborted');
    return 1;
  }
}

/// Honest install consent prompt. Shows manifest metadata + a stark
/// warning that installing grants the plugin author root. **Does
/// not** display the manifest's `permissions` block — that field is
/// author-supplied, unenforced, and would invite a false sense of
/// security if surfaced as a "permissions requested" list.
///
/// Returns true on `y` / `yes`, false on anything else (including
/// EOF / Ctrl-D).
Future<bool> _askConsent(
  PluginInstallPreview p, {
  String? requestedSubdir,
  required bool insecure,
}) async {
  stdout.writeln();
  stdout.writeln('━━━ plugin: ${p.name} ━━━');
  if (p.description.isNotEmpty) {
    stdout.writeln(p.description);
    stdout.writeln();
  }
  stdout.writeln('source:      ${p.url}');
  if (requestedSubdir != null) {
    stdout.writeln('subdir:      $requestedSubdir');
  }
  stdout.writeln('branch:      ${p.branch}');
  stdout.writeln('pinned rev:  ${p.pinnedRev}');
  stdout.writeln('schema:      v${p.schemaVersion}');
  // Signature line — Approach A. The fingerprint is what gets
  // pinned on the PluginMarker; subsequent refreshes that present
  // a different fingerprint are escalated to re-consent.
  stdout.writeln('signature:   ${describeSignature(p.signature)}');
  if (insecure) {
    stdout.writeln('insecure:    yes (--insecure given for non-https URL)');
  }
  stdout.writeln();
  stdout.writeln(
    'WARNING: installing this plugin grants the plugin author root '
    'on this node.',
  );
  stdout.writeln(
    'plugin.nix is arbitrary Nix code that runs at nixos-rebuild '
    'time as root and',
  );
  stdout.writeln(
    'can declare any systemd service, activation script, or external '
    'dependency.',
  );
  stdout.writeln(
    'This prompt is consent to run that code, not a sandbox. If you '
    "don't trust",
  );
  stdout.writeln(
    'the source + commit above, read plugin.nix at the upstream URL '
    'before answering yes.',
  );
  stdout.writeln();
  stdout.write('Proceed? [y/N]: ');
  final line = stdin.readLineSync() ?? '';
  final answer = line.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

Future<int> _runRemove(PluginService svc, ArgResults args) async {
  final rest = args.rest;
  if (rest.isEmpty) {
    stderr.writeln('Usage: nixblitz plugin remove <id>');
    return 2;
  }
  final id = rest.first;
  await svc.remove(id);
  stdout.writeln('removed $id');
  stdout.writeln('Run the Apply view (`a` in the TUI) to commit and rebuild.');
  return 0;
}

Future<int> _runList(PluginService svc, ArgResults args) async {
  // The `--all` flag previously surfaced tombstones; with markers
  // there are no tombstones — `--all` now means "include disabled".
  final all = args['all'] as bool;
  final plugins = await svc.list(includeDisabled: all);
  if (plugins.isEmpty) {
    stdout.writeln(all ? '(no plugins)' : '(no plugins installed)');
    return 0;
  }
  // Compact table. Not pretty-aligned; plugin lists stay short.
  stdout.writeln(
    'ID  |  BRANCH  |  PIN      |  DISABLED  |  AUTO-UPDATE  |  INSTALLED',
  );
  for (final p in plugins) {
    final disMark = p.disabled ? '  [disabled]' : '';
    final autoMark = p.autoUpdate ? 'true' : 'false [pinned]';
    stdout.writeln(
      '${p.id}  |  ${p.branch}  |  ${_shortRev(p.rev)}  |  '
      '${p.disabled}  |  $autoMark  |  '
      '${p.installedAt.toIso8601String().split("T").first}'
      '$disMark',
    );
  }
  return 0;
}

Future<int> _runRefresh(PluginService svc, ArgResults args) async {
  final all = args['all'] as bool;
  final insecure = args['insecure'] as bool;
  final rest = args.rest;

  if (all) {
    if (rest.isNotEmpty) {
      stderr.writeln('Either pass --all OR a plugin id, not both.');
      return 2;
    }
    final result = await svc.refreshAll(allowInsecure: insecure);
    if (result.totalAttempted == 0 && result.skipped.isEmpty) {
      stdout.writeln('(no plugins to refresh)');
      return 0;
    }
    for (final p in result.advanced) {
      stdout.writeln('refreshed ${p.id}  pin=${_shortRev(p.rev)}');
    }
    for (final p in result.unchanged) {
      stdout.writeln('${p.id} already at pin=${_shortRev(p.rev)} (no changes)');
    }
    for (final f in result.failures) {
      stderr.writeln('FAILED ${f.plugin.id}: ${f.error}');
    }
    if (result.advanced.isNotEmpty) {
      stdout.writeln();
      stdout.writeln(
        'Run the Apply view (`a` in the TUI) to commit and rebuild.',
      );
    }
    return result.hasAnyFailure ? 1 : 0;
  }

  if (rest.isEmpty) {
    stderr.writeln(
      'Usage: nixblitz plugin update <id> [--insecure]\n'
      '       nixblitz plugin update --all [--insecure]',
    );
    return 2;
  }
  final id = rest.first;
  // Capture the pin BEFORE refresh so we can detect a no-op (rev held)
  // and suppress the misleading "Run the Apply view" hint when nothing
  // actually moved.
  final priorRev = readMarker('${svc.pluginsDir}/$id')?.rev;
  try {
    final marker = await svc.refresh(id, allowInsecure: insecure);
    final advanced = priorRev != null && marker.rev != priorRev;
    if (advanced) {
      stdout.writeln('refreshed ${marker.id}');
      stdout.writeln('  pin:    ${_shortRev(marker.rev)}');
      stdout.writeln('  branch: ${marker.branch}');
      stdout.writeln();
      stdout.writeln(
        'Run the Apply view (`a` in the TUI) to commit and rebuild.',
      );
    } else {
      stdout.writeln(
        '${marker.id} already at pin=${_shortRev(marker.rev)} (no changes)',
      );
    }
    return 0;
  } on PluginSignatureMismatch catch (e) {
    _printSignatureMismatch(e);
    return 1;
  }
}

/// Render a [PluginSignatureMismatch] as a clear refusal message
/// with a recovery hint. Refresh is intentionally hard-fail on
/// mismatch so the operator has to explicitly re-consent before
/// the new key is accepted.
void _printSignatureMismatch(PluginSignatureMismatch e) {
  stderr.writeln('REFUSED: signing key changed for ${e.pluginId}');
  stderr.writeln('  pinned key:  ${e.expected}');
  stderr.writeln('  new key:     ${e.actual ?? "(unsigned)"}');
  stderr.writeln();
  stderr.writeln(
    'A bare `plugin update` will keep failing until you re-consent.',
  );
  stderr.writeln(
    'If the new key is legitimate (publisher rotated, you trust both):',
  );
  stderr.writeln('  nixblitz plugin remove ${e.pluginId}');
  stderr.writeln('  nixblitz plugin add    ${e.pluginId}');
  stderr.writeln('and re-affirm the new fingerprint at the consent prompt.');
}

Future<int> _runPin(
  PluginService svc,
  ArgResults args, {
  required bool pin,
}) async {
  final rest = args.rest;
  if (rest.isEmpty) {
    stderr.writeln('Usage: nixblitz plugin ${pin ? "pin" : "unpin"} <id>');
    return 2;
  }
  final id = rest.first;
  final marker = pin ? await svc.pin(id) : await svc.unpin(id);
  if (pin) {
    stdout.writeln(
      'pinned ${marker.id}\n'
      '  auto_update is now false; "Update entire system" will skip this '
      'plugin until you `unpin` or run `plugin update ${marker.id}` directly.',
    );
  } else {
    stdout.writeln(
      'unpinned ${marker.id}\n'
      '  auto_update is now true; the next "Update entire system" will '
      'advance its pin alongside the rest.',
    );
  }
  return 0;
}

String _shortRev(String rev) => rev.length >= 7 ? rev.substring(0, 7) : rev;
