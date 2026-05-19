import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:common/common.dart';

/// Entry point for `nixblitz update <target>`. Runs outside the
/// TUI — one-shot equivalent of the System → Apply path for a
/// single, well-scoped target.
///
/// Three targets:
///
/// - `tui` — bump just the `nixblitz` flake input + rebuild.
/// - `plugins` — refresh every auto-update plugin's pin + rebuild.
/// - `system` — bump every flake input + rebuild.
///
/// All three share the same gate (refuse if working tree dirty),
/// the same rebuild path (`sudo nixos-rebuild switch` with
/// inherited stdio so sudo prompts on the operator's terminal),
/// and the same post-success cleanup (wipe `update-status.json`
/// + staging so the dashboard banner doesn't lie next launch).
///
/// Exits 0 on success or "already up to date"; non-zero on
/// infrastructural failure (dirty tree, network, rebuild crash).
Future<int> runUpdateCli(ArgResults updateArgs, String baseDir) async {
  final sub = updateArgs.command;
  if (sub == null) {
    stderr.writeln('Usage: nixblitz update <tui|plugins|system>');
    return 2;
  }
  switch (sub.name) {
    case 'tui':
      return _updateFlakeInput(
        baseDir,
        input: 'nixblitz',
        commitMessage: 'Update nixblitz flake input',
        label: 'TUI',
      );
    case 'system':
      return _updateFlakeInput(
        baseDir,
        input: null,
        commitMessage: 'Update all flake inputs',
        label: 'system',
      );
    case 'plugins':
      return _updatePlugins(baseDir);
    default:
      stderr.writeln('unknown target: ${sub.name}');
      stderr.writeln('Usage: nixblitz update <tui|plugins|system>');
      return 2;
  }
}

/// Refuses on a dirty working tree, prints the dirty paths so the
/// operator knows what's blocking. Shared gate across all three
/// `update` subcommands so the no-silent-apply guarantee that the
/// TUI's Apply view enforces visually holds at the CLI too.
Future<bool> _requireCleanTree(String baseDir, GitService git) async {
  final dirty = await git.status();
  if (dirty.isEmpty) return true;
  stderr.writeln(
    'Refusing to update: ~/nixblitz/ has uncommitted changes.\n'
    'Open the TUI and run Apply (review screen will show your edits '
    'alongside the bump), or discard them first with '
    '`git -C $baseDir restore .`',
  );
  stderr.writeln('');
  stderr.writeln('Uncommitted paths:');
  for (final line in dirty.take(20)) {
    stderr.writeln('  $line');
  }
  if (dirty.length > 20) {
    stderr.writeln('  … (${dirty.length - 20} more)');
  }
  return false;
}

/// `sudo nixos-rebuild switch --flake <baseDir>#<attr>` with stdio
/// inherited. Picks the rebuild attribute via [_readPlatform]'s
/// fallback so the CLI doesn't disagree with the in-TUI Apply path
/// about which target to build.
Future<int> _runRebuild(String baseDir) async {
  final platform = _readPlatform(baseDir);
  final attr = rebuildAttributeFor(platform);
  stdout.writeln('');
  stdout.writeln('> sudo nixos-rebuild switch --flake $baseDir#$attr');
  stdout.writeln('');
  final rebuild = await Process.start('sudo', [
    'nixos-rebuild',
    'switch',
    '--flake',
    '$baseDir#$attr',
  ], mode: ProcessStartMode.inheritStdio);
  return rebuild.exitCode;
}

/// Wipe the cached check state. Called after every successful
/// rebuild from this CLI — the staged candidates have either been
/// promoted into the working tree (via Apply) or sidestepped (via
/// `update`), and the dashboard banner shouldn't keep referencing
/// pre-rebuild state. Non-fatal: the next check overwrites.
void _clearCheckState() {
  try {
    final statusFile = File(updateStatusPath);
    if (statusFile.existsSync()) statusFile.deleteSync();
    StagingService().clearAll();
  } catch (e) {
    stderr.writeln('warning: failed to clear cached check state: $e');
  }
}

/// Bump one (or all) flake inputs and rebuild. Shared by
/// `update tui` and `update system` — they only differ in which
/// input is passed to `nix flake update` and what the resulting
/// commit message says.
Future<int> _updateFlakeInput(
  String baseDir, {
  required String? input,
  required String commitMessage,
  required String label,
}) async {
  final git = GitService(repoDir: baseDir);
  if (!await _requireCleanTree(baseDir, git)) return 1;

  // 1. Bump the flake input(s). `nix flake update <input>` with
  // an explicit input restricts the update to that one; with no
  // argument it advances every input.
  final updArgs = input == null
      ? <String>['flake', 'update']
      : <String>['flake', 'update', input];
  stdout.writeln('> nix ${updArgs.join(' ')}');
  final upd = await Process.run('nix', updArgs, workingDirectory: baseDir);
  stdout.write(upd.stdout);
  stderr.write(upd.stderr);
  if (upd.exitCode != 0) {
    stderr.writeln('nix flake update failed (exit ${upd.exitCode})');
    return upd.exitCode;
  }

  // 2. Did the lock actually move? `nix flake update` rewrites
  // the file with a fresh timestamp regardless, so git is the
  // source of truth for "anything to rebuild."
  final diff = await Process.run('git', [
    'diff',
    '--quiet',
    '--exit-code',
    'flake.lock',
  ], workingDirectory: baseDir);
  if (diff.exitCode == 0) {
    stdout.writeln('');
    stdout.writeln('$label already at upstream — nothing to rebuild.');
    return 0;
  }

  // 3. Commit the lock bump. Single-file commit keeps this
  // separable from any later Apply.
  stdout.writeln('');
  stdout.writeln('> git commit flake.lock');
  final addRes = await Process.run('git', [
    'add',
    'flake.lock',
  ], workingDirectory: baseDir);
  if (addRes.exitCode != 0) {
    stderr.writeln('git add flake.lock failed: ${addRes.stderr}');
    return addRes.exitCode;
  }
  final commit = await Process.run('git', [
    'commit',
    '-m',
    commitMessage,
  ], workingDirectory: baseDir);
  if (commit.exitCode != 0) {
    stderr.writeln('git commit failed: ${commit.stderr}');
    return commit.exitCode;
  }

  // 4. Rebuild.
  final code = await _runRebuild(baseDir);
  if (code != 0) {
    stderr.writeln('');
    stderr.writeln('nixos-rebuild switch failed (exit $code)');
    return code;
  }

  _clearCheckState();
  stdout.writeln('');
  stdout.writeln('$label updated.');
  return 0;
}

/// Refresh every auto-update plugin's pin, then commit + rebuild.
/// Per-plugin failures are non-fatal: the rebuild proceeds with
/// whichever plugins advanced. Pinned plugins (autoUpdate=false)
/// are skipped — operators opted out of bulk refresh for those.
Future<int> _updatePlugins(String baseDir) async {
  final git = GitService(repoDir: baseDir);
  if (!await _requireCleanTree(baseDir, git)) return 1;

  final pluginService = PluginService(baseDir: baseDir);
  stdout.writeln('> nixblitz plugin update --all (excluding pinned)');
  final result = await pluginService.refreshAll(includePinned: false);

  // Print per-category summary so the operator sees which plugins
  // moved, which were already current, and which failed.
  if (result.advanced.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Advanced:');
    for (final p in result.advanced) {
      stdout.writeln('  ${p.id} → ${p.rev.substring(0, 7)}');
    }
  }
  if (result.unchanged.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Already at upstream:');
    for (final p in result.unchanged) {
      stdout.writeln('  ${p.id}');
    }
  }
  if (result.skipped.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Skipped (pinned):');
    for (final p in result.skipped) {
      stdout.writeln('  ${p.id}');
    }
  }
  if (result.failures.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('Failed:');
    for (final f in result.failures) {
      stdout.writeln('  ${f.plugin.id}: ${f.error}');
    }
  }

  if (result.advanced.isEmpty) {
    stdout.writeln('');
    stdout.writeln('No plugin pins moved — nothing to rebuild.');
    // Failures without any advances still exit non-zero so CI /
    // scripts can branch on success.
    return result.failures.isEmpty ? 0 : 1;
  }

  // refreshAll already wrote the new plugin files + markers +
  // regen'd plugin loader. Commit the working tree as one
  // recoverable point.
  stdout.writeln('');
  stdout.writeln('> git add -A && git commit -m "Update plugins"');
  final committed = await git.commitAll('Update plugins');
  if (!committed) {
    stderr.writeln('git commit failed — nothing staged?');
    return 1;
  }

  final code = await _runRebuild(baseDir);
  if (code != 0) {
    stderr.writeln('');
    stderr.writeln('nixos-rebuild switch failed (exit $code)');
    return code;
  }

  _clearCheckState();
  stdout.writeln('');
  final n = result.advanced.length;
  stdout.writeln('Plugins updated ($n plugin${n == 1 ? "" : "s"} advanced).');
  return result.failures.isEmpty ? 0 : 1;
}

/// Best-effort platform read for picking the rebuild attribute.
/// Falls back to `x86` on any I/O / parse failure — same fallback
/// the TUI uses, so the CLI doesn't disagree with the in-TUI
/// Apply path about which target to build.
String _readPlatform(String baseDir) {
  try {
    final f = File('$baseDir/config.json');
    if (!f.existsSync()) return 'x86';
    final raw = f.readAsStringSync();
    final json = NixblitzConfig.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    return json.system.platform;
  } catch (_) {
    return 'x86';
  }
}
