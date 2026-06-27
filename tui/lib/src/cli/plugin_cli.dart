import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:common/common.dart';

import '../ui/widgets/signature_label.dart';

/// `nixblitz plugin <verb>` — plugin management. Runs outside the
/// TUI (no `runApp`, no terminal takeover) so each verb can print
/// and exit.
class PluginCommand extends Command<int> {
  PluginCommand(String baseDir) {
    addSubcommand(PluginAddCommand(baseDir));
    addSubcommand(PluginRemoveCommand(baseDir));
    addSubcommand(PluginListCommand(baseDir));
    addSubcommand(PluginUpdateCommand(baseDir));
    addSubcommand(PluginPinCommand(baseDir));
    addSubcommand(PluginUnpinCommand(baseDir));
    addSubcommand(PluginSwitchBranchCommand(baseDir));
  }

  @override
  final String name = 'plugin';

  @override
  final String description =
      'Manage installed plugins (add / remove / list / update / pin / unpin / switch-branch).';
}

/// Shared catch-all wrapper: any thrown exception from a plugin
/// verb prints `error: <e>` and exits non-zero. Each subcommand
/// runs its own logic inside [body] and lets PluginService throw
/// freely.
Future<int> _runWithErrorReport(Future<int> Function() body) async {
  try {
    return await body();
  } catch (e) {
    stderr.writeln('error: $e');
    return 1;
  }
}

class PluginAddCommand extends Command<int> {
  PluginAddCommand(this.baseDir) {
    argParser
      ..addOption(
        'branch',
        help:
            'Branch to clone. When omitted, uses the manifest\'s declared '
            'default (or the remote\'s HEAD when no default is declared).',
      )
      ..addOption('subdir', help: 'Plugin subdirectory inside the cloned repo.')
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Skip the consent prompt.',
      )
      ..addFlag(
        'insecure',
        negatable: false,
        help: 'Allow non-https sources (file://, bare paths).',
      );
  }

  final String baseDir;

  @override
  final String name = 'add';

  @override
  final String description = 'Install a plugin from a git URL.';

  @override
  String get invocation =>
      'nixblitz plugin add <url> [--branch X] [--subdir Y] [-y] [--insecure]';

  @override
  Future<int> run() => _runWithErrorReport(
    () => _runAdd(PluginService(baseDir: baseDir), argResults!),
  );
}

class PluginRemoveCommand extends Command<int> {
  PluginRemoveCommand(this.baseDir);

  final String baseDir;

  @override
  final String name = 'remove';

  @override
  final String description =
      'Soft-delete a plugin (tombstone preserves the pin).';

  @override
  String get invocation => 'nixblitz plugin remove <id>';

  @override
  Future<int> run() => _runWithErrorReport(
    () => _runRemove(PluginService(baseDir: baseDir), argResults!),
  );
}

class PluginListCommand extends Command<int> {
  PluginListCommand(this.baseDir) {
    argParser.addFlag(
      'all',
      negatable: false,
      help: 'Include disabled plugins.',
    );
  }

  final String baseDir;

  @override
  final String name = 'list';

  @override
  final String description = 'List active plugins; --all also shows disabled.';

  @override
  Future<int> run() => _runWithErrorReport(
    () => _runList(PluginService(baseDir: baseDir), argResults!),
  );
}

class PluginUpdateCommand extends Command<int> {
  PluginUpdateCommand(this.baseDir) {
    argParser
      ..addFlag(
        'all',
        negatable: false,
        help: 'Refresh every auto-update plugin (instead of one by id).',
      )
      ..addFlag(
        'insecure',
        negatable: false,
        help: 'Allow non-https sources during the clone.',
      );
  }

  final String baseDir;

  @override
  final String name = 'update';

  @override
  final String description =
      "Pull a plugin's upstream into its pinned rev (or all auto-update plugins with --all).";

  @override
  String get invocation =>
      'nixblitz plugin update <id> [--insecure]\n'
      '       nixblitz plugin update --all [--insecure]';

  @override
  Future<int> run() => _runWithErrorReport(
    () => _runRefresh(PluginService(baseDir: baseDir), argResults!),
  );
}

class PluginPinCommand extends Command<int> {
  PluginPinCommand(this.baseDir);

  final String baseDir;

  @override
  final String name = 'pin';

  @override
  final String description =
      "Freeze the plugin at its current rev (auto_update=false).";

  @override
  String get invocation => 'nixblitz plugin pin <id>';

  @override
  Future<int> run() => _runWithErrorReport(
    () => _runPin(PluginService(baseDir: baseDir), argResults!, pin: true),
  );
}

class PluginUnpinCommand extends Command<int> {
  PluginUnpinCommand(this.baseDir);

  final String baseDir;

  @override
  final String name = 'unpin';

  @override
  final String description = 'Re-enable auto-updates for the plugin.';

  @override
  String get invocation => 'nixblitz plugin unpin <id>';

  @override
  Future<int> run() => _runWithErrorReport(
    () => _runPin(PluginService(baseDir: baseDir), argResults!, pin: false),
  );
}

class PluginSwitchBranchCommand extends Command<int> {
  PluginSwitchBranchCommand(this.baseDir) {
    argParser
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Skip the consent prompt (auto-accept).',
      )
      ..addFlag(
        'insecure',
        negatable: false,
        help: 'Allow non-https sources during the clone.',
      );
  }

  final String baseDir;

  @override
  final String name = 'switch-branch';

  @override
  final String description =
      'Re-clone the plugin from a different branch. '
      'Pinned plugins are refused — unpin first.';

  @override
  String get invocation =>
      'nixblitz plugin switch-branch <id> <branch> [-y] [--insecure]';

  @override
  Future<int> run() => _runWithErrorReport(
    () => _runSwitchBranch(PluginService(baseDir: baseDir), argResults!),
  );
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
  final branch = args['branch'] as String?;
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
  // Drop the plugin's now-orphaned app_configs entry (symmetric with the
  // install path seeding it). Mirrors what the TUI Remove flow does so the
  // change registers and config.json doesn't keep stale plugin config.
  if (svc.configService.configExists()) {
    final cfg = await svc.configService.readConfig();
    if (cfg.appConfigs.containsKey(id)) {
      await svc.configService.writeConfig(cfg.removeAppConfig(id));
    }
  }
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
  // App version per plugin, run on demand from the plugin's declared
  // `app_version` command (in parallel). No command → fall back to the
  // plugin version; command present but failing → "unavailable".
  final appVersions = <String, String>{};
  await Future.wait(
    plugins.map((p) async {
      appVersions[p.id] = await _appVersionFor(svc.baseDir, p);
    }),
  );

  // Aligned table: pad each column to the widest cell (header
  // included) so columns line up regardless of id / version length.
  // DISABLED + AUTO-UPDATE carry the pinned/disabled state, so no
  // inline [pinned] / [disabled] trailers are needed.
  const headers = [
    'ID',
    'VERSION',
    'APP VERSION',
    'BRANCH',
    'PIN',
    'DISABLED',
    'AUTO-UPDATE',
    'INSTALLED',
  ];
  final rows = [
    for (final p in plugins)
      [
        p.id,
        p.version.isEmpty ? '—' : p.version,
        appVersions[p.id] ?? '—',
        p.branch,
        _shortRev(p.rev),
        p.disabled ? 'yes' : 'no',
        p.autoUpdate ? 'yes' : 'no',
        p.installedAt.toIso8601String().split('T').first,
      ],
  ];
  final widths = List<int>.generate(
    headers.length,
    (c) => [
      headers,
      ...rows,
    ].map((r) => r[c].length).reduce((a, b) => a > b ? a : b),
  );
  String fmtRow(List<String> cells) => [
    for (var c = 0; c < cells.length; c++)
      // Trailing column isn't padded — avoids dangling whitespace.
      c == cells.length - 1 ? cells[c] : cells[c].padRight(widths[c]),
  ].join('  ');
  stdout.writeln(fmtRow(headers));
  for (final r in rows) {
    stdout.writeln(fmtRow(r));
  }
  return 0;
}

/// Resolve a plugin's app version for the list table: run its declared
/// `app_version` command; fall back to the plugin version when there's
/// no command, or "unavailable" when a declared command fails/times out.
Future<String> _appVersionFor(String baseDir, PluginMarker p) async {
  final fallback = p.version.isEmpty ? '—' : p.version;
  try {
    final mf = File('$baseDir/plugins/${p.id}/plugin.json');
    if (!mf.existsSync()) return fallback;
    final manifest = PluginManifest.fromJsonString(mf.readAsStringSync());
    final cmd = manifest.appVersionCommand;
    if (cmd == null) return fallback;
    final v = await readPluginAppVersion(
      baseDir: baseDir,
      pluginId: p.id,
      cmd: cmd,
    );
    return v ?? 'unavailable';
  } catch (_) {
    return fallback;
  }
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

Future<int> _runSwitchBranch(PluginService svc, ArgResults args) async {
  final rest = args.rest;
  if (rest.length != 2) {
    stderr.writeln(
      'Usage: nixblitz plugin switch-branch <id> <branch> [-y] [--insecure]',
    );
    return 2;
  }
  final id = rest[0];
  final branch = rest[1];
  final yes = args['yes'] as bool;
  final insecure = args['insecure'] as bool;

  try {
    final marker = await svc.switchBranch(
      id,
      branch,
      allowInsecure: insecure,
      confirm: yes
          ? null
          : (preview) => _askConsent(preview, insecure: insecure),
    );
    stdout.writeln('switched $id to branch ${marker.branch}');
    stdout.writeln('  pin:    ${_shortRev(marker.rev)}');
    stdout.writeln('  dir:    plugins/${marker.id}');
    stdout.writeln();
    stdout.writeln(
      'Run the Apply view (`a` in the TUI) to commit and rebuild.',
    );
    return 0;
  } on PluginInstallCancelled {
    stdout.writeln('aborted');
    return 1;
  } on PluginPinnedException catch (e) {
    stderr.writeln('REFUSED: $e');
    return 1;
  }
}

String _shortRev(String rev) => rev.length >= 7 ? rev.substring(0, 7) : rev;
