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
      case 'refresh':
        return await _runRefresh(svc, sub);
      case 'pin':
        return await _runPin(svc, sub, pin: true);
      case 'unpin':
        return await _runPin(svc, sub, pin: false);
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
    final entry = await svc.install(
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
    stdout.writeln('installed ${entry.id}');
    stdout.writeln('  pin:    ${_shortRev(entry.pinnedRev)}');
    stdout.writeln('  dir:    plugins/${entry.dirName}');
    stdout.writeln('  branch: ${entry.branch}');
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
  // pinned on the PluginEntry; subsequent refreshes that present
  // a different fingerprint are escalated to re-consent.
  stdout.writeln('signature:   ${_describeSignature(p.signature)}');
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

/// Render a [GitSignature] as a single-line string for the consent
/// prompt. Three relevant flavours, plus a generic fall-through:
///
/// - `signed by SSH key SHA256:abc…   (alice@example.com)` — fully
///   verified against the operator's keyring.
/// - `signed by SSH key SHA256:abc… [unverified key]` — good
///   signature, key not in operator's `allowed_signers`. Still
///   pinnable for TOFU.
/// - `(unsigned)` — no signature on the commit. The install can
///   still proceed; subsequent refreshes won't be able to detect
///   key changes.
String _describeSignature(GitSignature s) {
  if (!s.isPresent) return '(unsigned)';
  final fp = s.fingerprint.isEmpty ? '(no fingerprint)' : s.fingerprint;
  final identity = s.signer.isEmpty ? '' : '   (${s.signer})';
  switch (s.status) {
    case 'G':
      return 'signed by $fp$identity';
    case 'U':
      return 'signed by $fp$identity [unverified key]';
    case 'X':
      return 'signed by $fp$identity [signature expired]';
    case 'Y':
      return 'signed by $fp$identity [signing key expired]';
    case 'R':
      return 'signed by $fp$identity [signing key revoked]';
    case 'B':
      return 'BAD signature ($fp)';
    default:
      return 'signed (status=${s.status}, fp=$fp)';
  }
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
  stdout.writeln('Run the Apply view (`a` in the TUI) to commit and rebuild.');
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
  stdout.writeln(
    'ID  |  BRANCH  |  PIN      |  ENABLED  |  AUTO-UPDATE  |  INSTALLED',
  );
  for (final p in plugins) {
    final tombMark = p.isTombstone ? '  [removed]' : '';
    final autoMark = p.autoUpdate ? 'true' : 'false [pinned]';
    stdout.writeln(
      '${p.id}  |  ${p.branch}  |  ${_shortRev(p.pinnedRev)}  |  '
      '${p.enabled}  |  $autoMark  |  '
      '${p.installedAt.toIso8601String().split("T").first}'
      '$tombMark',
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
    for (final p in result.refreshed) {
      stdout.writeln('refreshed ${p.id}  pin=${_shortRev(p.pinnedRev)}');
    }
    for (final f in result.failures) {
      stderr.writeln('FAILED ${f.plugin.id}: ${f.error}');
    }
    if (result.refreshed.isNotEmpty) {
      stdout.writeln();
      stdout.writeln(
        'Run the Apply view (`a` in the TUI) to commit and rebuild.',
      );
    }
    return result.hasAnyFailure ? 1 : 0;
  }

  if (rest.isEmpty) {
    stderr.writeln(
      'Usage: nixblitz plugin refresh <id> [--insecure]\n'
      '       nixblitz plugin refresh --all [--insecure]',
    );
    return 2;
  }
  final id = rest.first;
  try {
    final entry = await svc.refresh(id, allowInsecure: insecure);
    stdout.writeln('refreshed ${entry.id}');
    stdout.writeln('  pin:    ${_shortRev(entry.pinnedRev)}');
    stdout.writeln('  branch: ${entry.branch}');
    stdout.writeln();
    stdout.writeln(
      'Run the Apply view (`a` in the TUI) to commit and rebuild.',
    );
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
    'A bare `plugin refresh` will keep failing until you re-consent.',
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
  final entry = pin ? await svc.pin(id) : await svc.unpin(id);
  if (pin) {
    stdout.writeln(
      'pinned ${entry.id}\n'
      '  auto_update is now false; "Update entire system" will skip this '
      'plugin until you `unpin` or run `plugin refresh ${entry.id}` directly.',
    );
  } else {
    stdout.writeln(
      'unpinned ${entry.id}\n'
      '  auto_update is now true; the next "Update entire system" will '
      'advance its pin alongside the rest.',
    );
  }
  return 0;
}

String _shortRev(String rev) => rev.length >= 7 ? rev.substring(0, 7) : rev;
