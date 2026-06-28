import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:common/common.dart';

/// `nixblitz update <target>` — one-shot equivalent of the
/// System → Apply path for a single, well-scoped target. Three
/// subcommands wrap the same shape: refuse on dirty tree, bump,
/// commit, `sudo nixos-rebuild switch` with inherited stdio, wipe
/// stale check state on success.
class UpdateCommand extends Command<int> {
  UpdateCommand(String baseDir) {
    addSubcommand(UpdateTuiCommand(baseDir));
    addSubcommand(UpdatePluginsCommand(baseDir));
    addSubcommand(UpdateSystemCommand(baseDir));
  }

  @override
  final String name = 'update';

  @override
  final String description =
      'One-shot rebuild for a single target (tui / plugins / system).';
}

/// `nixblitz update tui` — bumps the `nixblitz` flake input. The
/// "I just pushed a fix to nixblitz_ng and want it on this node"
/// path; sidesteps the full check + Apply flow when the operator
/// already knows exactly what they're rolling forward.
class UpdateTuiCommand extends Command<int> {
  UpdateTuiCommand(this.baseDir);

  final String baseDir;

  @override
  final String name = 'tui';

  @override
  final String description =
      'Bump the nixblitz flake input + rebuild. Refuses if the working tree is dirty.';

  @override
  Future<int> run() => _updateFlakeInput(
    baseDir,
    input: 'nixblitz',
    commitMessage: 'Update nixblitz flake input',
    label: 'TUI',
  );
}

/// `nixblitz update plugins` — refreshes every auto-update plugin
/// (pinned plugins skipped) and rebuilds.
class UpdatePluginsCommand extends Command<int> {
  UpdatePluginsCommand(this.baseDir);

  final String baseDir;

  @override
  final String name = 'plugins';

  @override
  final String description =
      'Refresh every auto-update plugin + rebuild. Per-plugin failures are non-fatal.';

  @override
  Future<int> run() => _updatePlugins(baseDir);
}

/// `nixblitz update system` — bumps every flake input. The old
/// "Update entire system" path; for "everything moved forward at
/// once."
class UpdateSystemCommand extends Command<int> {
  UpdateSystemCommand(this.baseDir);

  final String baseDir;

  @override
  final String name = 'system';

  @override
  final String description =
      'Bump every flake input + rebuild. The "Update entire system" path.';

  @override
  Future<int> run() => _updateFlakeInput(
    baseDir,
    input: null,
    commitMessage: 'Update all flake inputs',
    label: 'system',
  );
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
  // Halt any plugins this rebuild removes/disables BEFORE nixos-rebuild, on
  // the still-live old system — mirrors the TUI Apply path. The CLI has no
  // ProviderContainer, so the services are built directly. Best-effort.
  final teardown = PluginTeardownRunner(
    runAction: PluginActionRunner(sudoSession: SudoSession()).run,
    readCommitted: GitService(repoDir: baseDir).readCommittedFile,
    readCurrent: (p) {
      final f = File('$baseDir/$p');
      return f.existsSync() ? f.readAsStringSync() : null;
    },
  );
  final pending = await teardown.resolvePending();
  if (pending.isNotEmpty) {
    // The teardown units run via `sudo systemctl start --wait`; prime sudo
    // interactively once (the rebuild below would prompt anyway) so the
    // SudoSession's `-n` calls succeed instead of silently skipping.
    final prime = await Process.start('sudo', [
      '-v',
    ], mode: ProcessStartMode.inheritStdio);
    await prime.exitCode;
    await teardown.run(pending, stdout.writeln);
  }

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

  // 3. Rebuild against the (uncommitted) lock bump. Commit-on-success only:
  // nothing is committed before the build, so a failed rebuild never records
  // a committed state — the lock bump stays in the working tree.
  final code = await _runRebuild(baseDir);
  if (code != 0) {
    stderr.writeln('');
    stderr.writeln('nixos-rebuild switch failed (exit $code) — not committed');
    return code;
  }

  // 4. Commit-on-success: refresh the SBOM, then commit lock + SBOM as one
  // commit. STRICT — an SBOM failure aborts the commit (the lock bump stays
  // uncommitted, retried on the next run).
  final outcome = await generateSbomAndCommit(
    git: git,
    baseDir: baseDir,
    message: commitMessage,
  );
  if (outcome == ApplyCommitOutcome.sbomFailed) {
    stderr.writeln('');
    stderr.writeln(
      'rebuilt OK but SBOM generation failed — NOT committed; re-run to retry.',
    );
    return 1;
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

  // refreshAll already wrote the new plugin files + markers + regen'd the
  // plugin loader into the working tree. Commit-on-success only: rebuild
  // against the uncommitted tree first; a failed build never records a commit.
  final code = await _runRebuild(baseDir);
  if (code != 0) {
    stderr.writeln('');
    stderr.writeln('nixos-rebuild switch failed (exit $code) — not committed');
    return code;
  }

  // Commit-on-success: SBOM + the refreshed plugin tree as one commit. STRICT
  // — an SBOM failure aborts the commit (the refresh stays uncommitted).
  final outcome = await generateSbomAndCommit(
    git: git,
    baseDir: baseDir,
    message: 'Update plugins',
  );
  if (outcome == ApplyCommitOutcome.sbomFailed) {
    stderr.writeln('');
    stderr.writeln(
      'rebuilt OK but SBOM generation failed — NOT committed; re-run to retry.',
    );
    return 1;
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
