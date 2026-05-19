import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:common/common.dart';

/// Entry point for `nixblitz update <target>`. Runs outside the
/// TUI — one-shot equivalent of the System → Apply path for a
/// single, well-scoped target.
///
/// Only `tui` is wired today (advances just the `nixblitz` flake
/// input + rebuilds). Future expansion (`update plugins`,
/// `update system`) lives behind the same subcommand surface so
/// the CLI shape doesn't churn when more targets land.
///
/// Exits 0 on success or "already up to date"; non-zero on
/// infrastructural failure (dirty tree, network, rebuild crash).
Future<int> runUpdateCli(ArgResults updateArgs, String baseDir) async {
  final sub = updateArgs.command;
  if (sub == null) {
    stderr.writeln('Usage: nixblitz update <tui>');
    return 2;
  }
  switch (sub.name) {
    case 'tui':
      return _updateTui(baseDir);
    default:
      stderr.writeln('unknown target: ${sub.name}');
      stderr.writeln('Usage: nixblitz update <tui>');
      return 2;
  }
}

/// Bump just the `nixblitz` flake input + rebuild. The targeted
/// shape of "I just pushed a fix to nixblitz_ng and want it on
/// this node" — sidesteps the full check + Apply flow when the
/// operator already knows exactly what they're rolling forward.
///
/// Refuses to run with a dirty working tree: the no-silent-apply
/// guarantee that the TUI's Apply view enforces visually has to
/// hold here too, or this command becomes the back door we
/// structurally closed in the unification refactor.
Future<int> _updateTui(String baseDir) async {
  final git = GitService(repoDir: baseDir);

  // Gate on a clean working tree. Any pending config edit means
  // the operator needs to go through Apply (where they see the
  // edit + the lock bump together) rather than have it land as
  // a side effect of a TUI bump.
  final dirty = await git.status();
  if (dirty.isNotEmpty) {
    stderr.writeln(
      'Refusing to update: ~/nixblitz/ has uncommitted changes.\n'
      'Open the TUI and run Apply (review screen will show your edits '
      'alongside the lock bump), or discard them first with '
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
    return 1;
  }

  // 1. Bump just the nixblitz input.
  stdout.writeln('> nix flake update nixblitz');
  final upd = await Process.run('nix', [
    'flake',
    'update',
    'nixblitz',
  ], workingDirectory: baseDir);
  stdout.write(upd.stdout);
  stderr.write(upd.stderr);
  if (upd.exitCode != 0) {
    stderr.writeln('nix flake update failed (exit ${upd.exitCode})');
    return upd.exitCode;
  }

  // 2. Did the lock actually move? `nix flake update` rewrites the
  // file with a fresh timestamp regardless, so git is the source
  // of truth for "anything to rebuild."
  final diff = await Process.run('git', [
    'diff',
    '--quiet',
    '--exit-code',
    'flake.lock',
  ], workingDirectory: baseDir);
  if (diff.exitCode == 0) {
    stdout.writeln('');
    stdout.writeln('nixblitz already at upstream — nothing to rebuild.');
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
    'Update nixblitz flake input',
  ], workingDirectory: baseDir);
  if (commit.exitCode != 0) {
    stderr.writeln('git commit failed: ${commit.stderr}');
    return commit.exitCode;
  }

  // 4. Resolve rebuild attribute from on-disk platform. Mirrors
  // the same fallback the TUI's Apply view uses.
  final platform = _readPlatform(baseDir);
  final attr = rebuildAttributeFor(platform);

  stdout.writeln('');
  stdout.writeln('> sudo nixos-rebuild switch --flake $baseDir#$attr');
  stdout.writeln('');

  // Inherit stdio so sudo can prompt on the operator's terminal
  // and the rebuild output streams straight through. The CLI is
  // already attached to a TTY (or piped, in which case sudo will
  // fail loudly which is correct).
  final rebuild = await Process.start('sudo', [
    'nixos-rebuild',
    'switch',
    '--flake',
    '$baseDir#$attr',
  ], mode: ProcessStartMode.inheritStdio);
  final code = await rebuild.exitCode;
  if (code != 0) {
    stderr.writeln('');
    stderr.writeln('nixos-rebuild switch failed (exit $code)');
    return code;
  }

  // 5. Wipe stale check state so the dashboard banner doesn't
  // keep claiming "updates available" for inputs we just bumped
  // (or for the unrelated inputs the last check probed). Same
  // semantic as the Apply view's post-rebuild cleanup.
  try {
    final statusFile = File(updateStatusPath);
    if (statusFile.existsSync()) statusFile.deleteSync();
    StagingService().clearAll();
  } catch (e) {
    // Non-fatal — the next check overwrites stale entries.
    stderr.writeln('warning: failed to clear cached check state: $e');
  }

  stdout.writeln('');
  stdout.writeln('TUI updated. The new binary lands on next launch.');
  return 0;
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
