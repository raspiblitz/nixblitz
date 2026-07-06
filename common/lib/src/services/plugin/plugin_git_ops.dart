import 'dart:io';

import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/log_service.dart';

/// Git + filesystem helpers used by PluginService to fetch and validate a
/// plugin source tree. Extracted as free functions so the service class
/// stays focused on install / refresh / lifecycle.

/// Fixed clone timeout. Remote repos that misbehave shouldn't hang the TUI
/// — 60 s is generous for a shallow clone.
const _cloneTimeout = Duration(seconds: 60);

/// Shallow-clone [url] into [target]. When [branch] is non-null,
/// pass `--branch <branch>` so the clone lands on that ref;
/// when null, omit the flag and let git pick the remote's
/// advertised HEAD (typically `main` or `master`). The null
/// case lets the install flow do an unbiased first clone before
/// the manifest's own `branches` block redirects it.
Future<void> gitClonePlugin(String url, String? branch, String target) async {
  final r = await Process.run(
    'git',
    [
      'clone',
      '--depth',
      '1',
      if (branch != null) ...['--branch', branch],
      '--no-recurse-submodules',
      url,
      target,
    ],
    environment: const {'GIT_TERMINAL_PROMPT': '0'},
  ).timeout(_cloneTimeout);
  if (r.exitCode != 0) {
    final stderr = (r.stderr as String).trim();
    final hint = _suggestLocalSubdir(url);
    throw StateError(
      'git clone failed (exit ${r.exitCode}): $stderr'
      '${hint == null ? '' : '\n\n$hint'}',
    );
  }
}

/// If [url] points at a local path that lives *inside* a git repo
/// (rather than being the repo root itself), build a friendly hint
/// showing the correct form. The common case: user runs
/// `plugin add /path/to/repo/plugin-a --insecure`, which fails
/// because /path/to/repo/plugin-a has no .git/. We walk up to
/// /path/to/repo, find .git/, and suggest
/// `/path/to/repo --subdir plugin-a`.
String? _suggestLocalSubdir(String url) {
  String? fsPath;
  if (url.startsWith('file://')) {
    fsPath = url.substring('file://'.length);
  } else if (url.startsWith('/')) {
    fsPath = url;
  }
  if (fsPath == null) return null;
  // Strip any ?dir= we appended when subdir was set via flag.
  final q = fsPath.indexOf('?');
  if (q >= 0) fsPath = fsPath.substring(0, q);

  final segments = fsPath.split(Platform.pathSeparator);
  for (var i = segments.length - 1; i > 0; i--) {
    final candidate = segments.sublist(0, i).join(Platform.pathSeparator);
    if (candidate.isEmpty) continue;
    // `.git` is usually a directory but can be a file (worktrees, submodules).
    if (Directory('$candidate/.git').existsSync() ||
        File('$candidate/.git').existsSync()) {
      final subdir = segments.sublist(i).join('/');
      return 'hint: `$fsPath` sits inside the git repo at `$candidate`. '
          'Try: `plugin add $candidate --subdir $subdir --insecure`';
    }
  }
  return null;
}

/// List immediate subdirectory names of [repoDir] that look like
/// NixBlitz plugins (contain both plugin.json and plugin.nix).
/// Used to build a helpful "pick one with --subdir" error when a
/// user points at a multi-plugin repo without specifying which
/// plugin they want. Sorted for stable output.
List<String> listPluginSubdirs(String repoDir) {
  final result = <String>[];
  for (final entity in Directory(repoDir).listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final name = entity.path.split(Platform.pathSeparator).last;
    if (name.startsWith('.')) continue;
    final hasManifest = File('${entity.path}/plugin.json').existsSync();
    final hasPluginNix = File('${entity.path}/plugin.nix').existsSync();
    if (hasManifest && hasPluginNix) {
      result.add(name);
    }
  }
  result.sort();
  return result;
}

/// `git add -N` (intent-to-add) on everything under [path]. Makes
/// brand-new files visible in `git diff` as additions. Non-fatal:
/// a non-git baseDir just logs a warning.
Future<void> gitIntentToAdd(String path, {required String baseDir}) async {
  try {
    final r = await Process.run('git', [
      'add',
      '-N',
      path,
    ], workingDirectory: baseDir);
    if (r.exitCode != 0) {
      LogService.warn(
        'PluginService: git add -N failed '
        '(${r.exitCode}): ${(r.stderr as String).trim()}',
      );
    }
  } catch (e) {
    LogService.warn('PluginService: git add -N threw: $e');
  }
}

/// Walk the cloned tree and throw if any entry is a symlink.
/// Uses `followLinks: false` so symlinks come back as `Link`
/// entities instead of being transparently resolved.
void rejectSymlinks(String dir) {
  for (final entity in Directory(
    dir,
  ).listSync(recursive: true, followLinks: false)) {
    // Skip the .git internals — Dart doesn't descend into them
    // automatically because of the default list behavior; we
    // check anyway to avoid flagging any internal link git uses.
    if (entity.path.contains(
      '${Platform.pathSeparator}.git${Platform.pathSeparator}',
    )) {
      continue;
    }
    if (entity is Link) {
      final rel = entity.path.substring(dir.length);
      throw StateError(
        'Plugin repo contains a symlink at `$rel`; refusing to install. '
        'Plugins must contain only regular files (no symlinks).',
      );
    }
  }
}

Future<String> gitRevParseHead(String repoDir) async {
  final r = await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: repoDir);
  if (r.exitCode != 0) {
    throw StateError('git rev-parse failed: ${(r.stderr as String).trim()}');
  }
  return (r.stdout as String).trim();
}

/// Return the short name of HEAD's symbolic ref (e.g. `main`) in
/// the freshly-cloned [repoDir]. Used when the install flow
/// clones at the remote's default (no `--branch`) so the marker
/// can still record a concrete branch name for later refreshes.
/// Falls back to the empty string if HEAD is detached or
/// `symbolic-ref` fails for any reason (e.g. an old git that
/// produced a detached shallow checkout).
Future<String> gitCurrentBranch(String repoDir) async {
  final r = await Process.run('git', [
    'symbolic-ref',
    '--short',
    '-q',
    'HEAD',
  ], workingDirectory: repoDir);
  if (r.exitCode != 0) return '';
  return (r.stdout as String).trim();
}

PluginManifest readPluginManifest(String dir) {
  final f = File('$dir/plugin.json');
  if (!f.existsSync()) {
    throw StateError('plugin.json not found at $dir');
  }
  return PluginManifest.fromJsonString(f.readAsStringSync());
}

void requirePluginNix(String dir) {
  if (!File('$dir/plugin.nix').existsSync()) {
    throw StateError('plugin.nix not found at $dir');
  }
}
