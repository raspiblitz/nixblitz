import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_entry.dart';
import 'package:common/src/models/plugin/plugin_install_preview.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/git_service.dart';
import 'package:common/src/services/log_service.dart';

/// Manages installed plugins under `~/nixblitz/plugins/<dirName>/`
/// and the matching `plugins[]` entries in `~/nixblitz/config.json`.
///
/// Phase 1 surface: URL parsing, clone-to-tmpdir, manifest
/// validation, install (with collision-resolved dirName, D5), soft
/// delete (D4), list. No update / pin / unpin yet (Phase 5).
///
/// Side effects land in the working tree — no git commits here.
/// The user's next Apply captures every change via `git add -A`.
class PluginService {
  final String baseDir;
  final ConfigService configService;

  /// Fixed clone timeout. Remote repos that misbehave shouldn't hang
  /// the TUI — 60 s is generous for a shallow clone.
  static const _cloneTimeout = Duration(seconds: 60);

  PluginService({required this.baseDir})
      : configService = ConfigService(baseDir: baseDir);

  String get pluginsDir => '$baseDir/plugins';

  /// Install a plugin from [rawUrl] (D5 schemes). Clones to a
  /// tmpdir, validates the manifest, then (optionally) hands a
  /// [PluginInstallPreview] to [confirm] before copying plugin files
  /// into `plugins/<dirName>/` and appending a [PluginEntry] to the
  /// main config. Reviving a tombstoned entry (D4) is idempotent.
  ///
  /// [allowInsecure] must be true for `file://`, `http://`, or
  /// `ssh://` URLs (D9).
  ///
  /// [confirm] runs after the manifest has been parsed but before
  /// any state lands on disk. Returning `false` aborts cleanly with
  /// [PluginInstallCancelled]. `null` (the default) skips the prompt
  /// — the caller has either already collected consent (`--yes`) or
  /// is invoking install from a non-interactive context.
  Future<PluginEntry> install(
    String rawUrl, {
    String branch = 'main',
    bool allowInsecure = false,
    String? subdir,
    PluginInstallConfirm? confirm,
  }) async {
    final parsed = PluginUrl.parse(
      rawUrl,
      allowInsecure: allowInsecure,
      subdir: subdir,
    );

    final config = configService.configExists()
        ? await configService.readConfig()
        : NixblitzConfig.defaults();

    final activeExisting = config.plugins.firstWhereOrNull(
      (p) => p.id == parsed.canonical && p.uninstalledAt == null,
    );
    if (activeExisting != null) {
      throw StateError('Plugin already installed: ${parsed.canonical}');
    }

    final tmpDir = await Directory.systemTemp.createTemp('nixblitz-plugin-');
    Directory? targetDir;
    try {
      await _gitClone(parsed.cloneUrl, branch, tmpDir.path);
      final pinnedRev = await _gitRevParseHead(tmpDir.path);

      // Safety: the source repo must not contain symlinks. A
      // malicious plugin could ship plugin.nix as a symlink to e.g.
      // /etc/shadow; `File.copySync` follows links, which would
      // land sensitive content in the tracked config repo. Phase 1
      // plugins have no legitimate need for symlinks, so reject
      // outright with a clear error.
      _rejectSymlinks(tmpDir.path);

      final pluginSourceDir = parsed.subdir == null
          ? tmpDir.path
          : '${tmpDir.path}/${parsed.subdir}';

      // If there's no manifest where we expected one, the repo is
      // likely a multi-plugin bundle — scan for candidates and list
      // them so the user can re-run with --subdir.
      if (!File('$pluginSourceDir/manifest.json').existsSync()) {
        if (parsed.subdir == null) {
          final candidates = _listPluginSubdirs(tmpDir.path);
          if (candidates.isEmpty) {
            throw StateError(
              'No plugin found in this repo: no manifest.json at the root '
              'and no immediate subdirectory contains one. '
              'Is this a NixBlitz plugin repo?',
            );
          }
          throw StateError(
            'Repo has no plugin at its root but contains '
            '${candidates.length} plugin${candidates.length == 1 ? '' : 's'} '
            'in subdirectories:\n'
            '${candidates.map((s) => '  - $s').join('\n')}\n'
            'Pick one with `--subdir <name>`.',
          );
        } else {
          throw StateError(
            'manifest.json not found at subdir `${parsed.subdir}` in the '
            'cloned repo.',
          );
        }
      }

      final manifest = _readManifest(pluginSourceDir);
      _requirePluginNix(pluginSourceDir);

      // Capture commit signature (Approach A) BEFORE the consent
      // callback so the preview can render fingerprint + status.
      // Note: GitService is constructed without `environment` so
      // it inherits the operator's gpg / SSH config — the hermetic
      // test env explicitly disables signing, but production code
      // wants the real keyring visible.
      final signature =
          await GitService(repoDir: tmpDir.path).verifyCommit();

      // Consent gate (D14). Hand the manifest metadata + signature
      // to the caller's prompt; if it returns false, abort cleanly
      // so nothing lands on disk. The tmpdir is cleaned up by the
      // outer `finally` regardless.
      if (confirm != null) {
        final preview = PluginInstallPreview(
          name: manifest.name,
          description: manifest.description,
          url: parsed.canonical,
          branch: branch,
          pinnedRev: pinnedRev,
          schemaVersion: manifest.schemaVersion,
          signature: signature,
        );
        final ok = await confirm(preview);
        if (!ok) {
          LogService.info(
            'PluginService.install: cancelled by user '
            '(${parsed.canonical})',
          );
          throw const PluginInstallCancelled();
        }
      }

      // Revival of a tombstoned entry (D4) reuses the original
      // dirName; only fresh installs collision-resolve against the
      // existing set.
      final tombstone = config.plugins.firstWhereOrNull(
        (p) => p.id == parsed.canonical && p.uninstalledAt != null,
      );
      final dirName = tombstone?.dirName ??
          _resolveDirName(config.plugins, parsed.deriveDirName());

      final pluginsDirObj = Directory(pluginsDir);
      if (!pluginsDirObj.existsSync()) {
        pluginsDirObj.createSync(recursive: true);
      }
      targetDir = Directory('$pluginsDir/$dirName');
      if (targetDir.existsSync()) {
        // Should not happen after _resolveDirName; defend anyway.
        throw StateError('target dir exists: ${targetDir.path}');
      }
      targetDir.createSync();

      for (final name in const [
        'plugin.nix',
        'manifest.json',
        'README.md',
        'LICENSE',
      ]) {
        final src = File('$pluginSourceDir/$name');
        if (src.existsSync()) {
          src.copySync('${targetDir.path}/$name');
        }
      }

      File('${targetDir.path}/config.json').writeAsStringSync('{}\n');

      final now = DateTime.now().toUtc();
      final entry = PluginEntry(
        id: parsed.canonical,
        url: parsed.canonical,
        branch: branch,
        pinnedRev: pinnedRev,
        dirName: dirName,
        installedAt: now,
        lastUpdatedAt: now,
        signatureFingerprint:
            signature.fingerprint.isEmpty ? null : signature.fingerprint,
      );

      // Mark the new plugin files as intent-to-add (git add -N) so
      // the Apply view's `git diff` renders them as new-file
      // additions instead of hiding them as untracked. The files
      // remain unstaged in content; Apply's later `git add -A` still
      // stages them properly. Best-effort — a git-less baseDir
      // (shouldn't happen in practice) doesn't block install.
      await _gitIntentToAdd(targetDir.path);

      final updatedPlugins = List<PluginEntry>.from(config.plugins);
      final tombstoneIdx = updatedPlugins.indexWhere(
        (p) => p.id == parsed.canonical,
      );
      if (tombstoneIdx >= 0) {
        updatedPlugins[tombstoneIdx] = entry;
      } else {
        updatedPlugins.add(entry);
      }
      await configService.writeConfig(
        config.copyWith(plugins: updatedPlugins),
      );

      LogService.info(
        'PluginService: installed ${parsed.canonical} '
        '($pinnedRev, dir=$dirName, schema=${manifest.schemaVersion})',
      );
      return entry;
    } catch (e, st) {
      // Roll back a half-created target dir so the user's next
      // Apply review isn't littered with partial state.
      if (targetDir != null && targetDir.existsSync()) {
        try {
          targetDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      // User-cancellation is an expected outcome, not an error —
      // the prompt explicitly invites "no". Log at info, no stack.
      if (e is PluginInstallCancelled) rethrow;
      LogService.error('PluginService.install failed for $rawUrl', e, st);
      rethrow;
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Soft-delete: wipe the plugin directory and mark the row as
  /// tombstoned (D4). Reinstall later with [install] revives it.
  Future<void> remove(String id) async {
    final config = await configService.readConfig();
    final idx = config.plugins.indexWhere(
      (p) => p.id == id && p.uninstalledAt == null,
    );
    if (idx < 0) {
      throw StateError('Plugin not installed: $id');
    }
    final entry = config.plugins[idx];

    final dir = Directory('$pluginsDir/${entry.dirName}');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }

    final updated = List<PluginEntry>.from(config.plugins);
    updated[idx] = entry.copyWith(
      enabled: false,
      uninstalledAt: DateTime.now().toUtc(),
    );
    await configService.writeConfig(config.copyWith(plugins: updated));
    LogService.info('PluginService: removed $id (tombstoned)');
  }

  /// Re-fetch a plugin from its stored URL, updating the pinned
  /// rev + file contents while preserving the user's per-plugin
  /// `config.json`. Used as a less-destructive alternative to the
  /// `plugin remove && plugin add` dance the user has to do today
  /// whenever the upstream plugin source moves.
  ///
  /// The plugin's `dirName`, `branch`, and main-config entry index
  /// all stay the same; only `pinnedRev` and `lastUpdatedAt` are
  /// updated. Leaves the working tree dirty — next Apply commits
  /// the refreshed files alongside any other staged changes.
  Future<PluginEntry> refresh(
    String id, {
    bool allowInsecure = false,
  }) async {
    final config = await configService.readConfig();
    final idx = config.plugins.indexWhere(
      (p) => p.id == id && p.uninstalledAt == null,
    );
    if (idx < 0) {
      throw StateError('Plugin not installed: $id');
    }
    final existing = config.plugins[idx];
    final parsed = PluginUrl.parse(
      existing.url,
      allowInsecure: allowInsecure,
    );

    final targetDir = Directory('$pluginsDir/${existing.dirName}');
    if (!targetDir.existsSync()) {
      throw StateError(
        'Plugin dir missing at ${targetDir.path}; main config says '
        'it\'s installed but the files are gone. Try `plugin remove` '
        'followed by `plugin add` to recover.',
      );
    }

    // Preserve the user's config.json bytes verbatim. Even if a
    // manifest update removes a field, the stale value stays in the
    // file; the running plugin.nix just ignores what it doesn't read.
    final existingCfgFile = File('${targetDir.path}/config.json');
    final preservedCfg = existingCfgFile.existsSync()
        ? existingCfgFile.readAsStringSync()
        : '{}\n';

    final tmpDir = await Directory.systemTemp.createTemp(
      'nixblitz-plugin-refresh-',
    );
    try {
      await _gitClone(parsed.cloneUrl, existing.branch, tmpDir.path);
      final pinnedRev = await _gitRevParseHead(tmpDir.path);

      // Early return when the upstream pin matches what we have.
      // `last_updated_at` semantically means "files changed", not
      // "we polled" — touching it on every no-op refresh would
      // dirty config.json with timestamp churn even when nothing
      // actually moved upstream. The plugin tree on disk also
      // stays untouched.
      if (pinnedRev == existing.pinnedRev) {
        LogService.info(
          'PluginService: refresh ${existing.id} no-op '
          '(pin already at $pinnedRev)',
        );
        return existing;
      }

      _rejectSymlinks(tmpDir.path);

      final pluginSourceDir = parsed.subdir == null
          ? tmpDir.path
          : '${tmpDir.path}/${parsed.subdir}';

      if (!File('$pluginSourceDir/manifest.json').existsSync()) {
        throw StateError(
          'manifest.json not found at subdir '
          '`${parsed.subdir ?? "(root)"}` in the refreshed repo.',
        );
      }
      final manifest = _readManifest(pluginSourceDir);
      _requirePluginNix(pluginSourceDir);

      // Approach A signature check. Three cases:
      // - existing pin null + new fp: silent upgrade — adopt the
      //   new fp into the entry.
      // - existing pin set + new fp matches: silent re-affirm.
      // - existing pin set + new fp differs (or new is empty):
      //   throw PluginSignatureMismatch. Caller decides how to
      //   surface (CLI prints + suggests `plugin remove` +
      //   `plugin add` to re-consent; refreshAll captures into
      //   `failures`).
      final newSignature =
          await GitService(repoDir: tmpDir.path).verifyCommit();
      final newFp = newSignature.fingerprint.isEmpty
          ? null
          : newSignature.fingerprint;
      if (existing.signatureFingerprint != null &&
          existing.signatureFingerprint != newFp) {
        throw PluginSignatureMismatch(
          pluginId: existing.id,
          expected: existing.signatureFingerprint!,
          actual: newFp,
        );
      }

      // Wipe + repopulate. Simple and matches the install shape;
      // any file the new plugin version no longer ships is gone
      // cleanly.
      targetDir.deleteSync(recursive: true);
      targetDir.createSync(recursive: true);

      for (final name in const [
        'plugin.nix',
        'manifest.json',
        'README.md',
        'LICENSE',
      ]) {
        final src = File('$pluginSourceDir/$name');
        if (src.existsSync()) {
          src.copySync('${targetDir.path}/$name');
        }
      }

      // Restore user config, overwriting the empty copy the manifest
      // flow might want to seed.
      existingCfgFile.writeAsStringSync(preservedCfg);

      final now = DateTime.now().toUtc();
      final refreshed = existing.copyWith(
        pinnedRev: pinnedRev,
        lastUpdatedAt: now,
        signatureFingerprint: newFp,
        clearSignatureFingerprint: newFp == null,
      );

      await _gitIntentToAdd(targetDir.path);

      final updated = List<PluginEntry>.from(config.plugins);
      updated[idx] = refreshed;
      await configService.writeConfig(
        config.copyWith(plugins: updated),
      );

      LogService.info(
        'PluginService: refreshed ${existing.id} '
        '(pin: ${existing.pinnedRev} → $pinnedRev, '
        'schema=${manifest.schemaVersion})',
      );
      return refreshed;
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Refresh every active (non-tombstoned) plugin in order.
  ///
  /// - When [includePinned] is `false`, plugins with
  ///   `auto_update == false` are skipped. Used by the Update-view
  ///   integration so per-plugin pins behave like opt-out from
  ///   system-wide refresh (D11).
  /// - Per-plugin refresh failures are **non-fatal**: errors are
  ///   logged + collected; the loop continues with the remaining
  ///   plugins. Returns a [PluginRefreshAllResult] capturing the
  ///   successes and the per-plugin failures so the caller can
  ///   surface them in its UI.
  Future<PluginRefreshAllResult> refreshAll({
    bool allowInsecure = false,
    bool includePinned = true,
  }) async {
    final active = await list();
    final refreshed = <PluginEntry>[];
    final failures = <({PluginEntry plugin, Object error})>[];
    final skipped = <PluginEntry>[];
    for (final p in active) {
      if (!includePinned && !p.autoUpdate) {
        skipped.add(p);
        continue;
      }
      try {
        refreshed.add(await refresh(p.id, allowInsecure: allowInsecure));
      } catch (e, st) {
        LogService.error(
          'PluginService.refreshAll: ${p.id} failed',
          e,
          st,
        );
        failures.add((plugin: p, error: e));
      }
    }
    return PluginRefreshAllResult(
      refreshed: refreshed,
      failures: failures,
      skipped: skipped,
    );
  }

  /// Mark [id] as `auto_update = false`. The next bulk refresh
  /// (Update-view "Update entire system") skips it. Direct
  /// `plugin refresh <id>` ignores the flag and still works.
  Future<PluginEntry> pin(String id) async => _setAutoUpdate(id, false);

  /// Inverse of [pin]: re-enable bulk auto-refresh for [id].
  Future<PluginEntry> unpin(String id) async => _setAutoUpdate(id, true);

  Future<PluginEntry> _setAutoUpdate(String id, bool value) async {
    final config = await configService.readConfig();
    final idx = config.plugins.indexWhere(
      (p) => p.id == id && p.uninstalledAt == null,
    );
    if (idx < 0) {
      throw StateError('Plugin not installed: $id');
    }
    final updatedEntry = config.plugins[idx].copyWith(autoUpdate: value);
    final updatedPlugins = List<PluginEntry>.from(config.plugins);
    updatedPlugins[idx] = updatedEntry;
    await configService.writeConfig(
      config.copyWith(plugins: updatedPlugins),
    );
    return updatedEntry;
  }

  /// Active plugins by default; pass [includeTombstones] for the full
  /// audit trail.
  Future<List<PluginEntry>> list({bool includeTombstones = false}) async {
    if (!configService.configExists()) return const [];
    final config = await configService.readConfig();
    if (includeTombstones) return config.plugins;
    return config.plugins.where((p) => p.uninstalledAt == null).toList();
  }

  /// Load an installed plugin's manifest from disk. Used by the
  /// Configure view to know which form fields to render. Throws
  /// [StateError] if the plugin dir / manifest.json is missing and
  /// [FormatException] / [PluginTooNewException] on parse failures.
  PluginManifest readManifest(String dirName) {
    final f = File('$pluginsDir/$dirName/manifest.json');
    if (!f.existsSync()) {
      throw StateError(
        'manifest.json not found for plugin `$dirName`. '
        'Is it installed?',
      );
    }
    return PluginManifest.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  }

  // ── private ──────────────────────────────────────────────────

  Future<void> _gitClone(String url, String branch, String target) async {
    final r = await Process.run(
      'git',
      [
        'clone',
        '--depth', '1',
        '--branch', branch,
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
  /// NixBlitz plugins (contain both manifest.json and plugin.nix).
  /// Used to build a helpful "pick one with --subdir" error when a
  /// user points at a multi-plugin repo without specifying which
  /// plugin they want. Sorted for stable output.
  List<String> _listPluginSubdirs(String repoDir) {
    final result = <String>[];
    for (final entity in Directory(repoDir).listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      final hasManifest =
          File('${entity.path}/manifest.json').existsSync();
      final hasPluginNix =
          File('${entity.path}/plugin.nix').existsSync();
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
  Future<void> _gitIntentToAdd(String path) async {
    try {
      final r = await Process.run(
        'git',
        ['add', '-N', path],
        workingDirectory: baseDir,
      );
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
  void _rejectSymlinks(String dir) {
    for (final entity in Directory(dir).listSync(
      recursive: true,
      followLinks: false,
    )) {
      // Skip the .git internals — Dart doesn't descend into them
      // automatically because of the default list behavior; we
      // check anyway to avoid flagging any internal link git uses.
      if (entity.path.contains('${Platform.pathSeparator}.git${Platform.pathSeparator}')) {
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

  Future<String> _gitRevParseHead(String repoDir) async {
    final r = await Process.run(
      'git',
      ['rev-parse', 'HEAD'],
      workingDirectory: repoDir,
    );
    if (r.exitCode != 0) {
      throw StateError(
        'git rev-parse failed: ${(r.stderr as String).trim()}',
      );
    }
    return (r.stdout as String).trim();
  }

  PluginManifest _readManifest(String dir) {
    final f = File('$dir/manifest.json');
    if (!f.existsSync()) {
      throw StateError('manifest.json not found at $dir');
    }
    return PluginManifest.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  }

  void _requirePluginNix(String dir) {
    if (!File('$dir/plugin.nix').existsSync()) {
      throw StateError('plugin.nix not found at $dir');
    }
  }

  /// Ensure dirName uniqueness across active + tombstoned entries
  /// (tombstones still occupy their slot conceptually — reinstall
  /// reuses it).
  String _resolveDirName(List<PluginEntry> existing, String base) {
    final claimed = existing.map((p) => p.dirName).toSet();
    if (!claimed.contains(base)) return base;
    var i = 2;
    while (claimed.contains('$base-$i')) {
      i++;
    }
    return '$base-$i';
  }
}

/// Aggregate result from [PluginService.refreshAll]. The Update-view
/// integration in `tui/lib/src/ui/views/update_view.dart` walks
/// these three lists to render successes / warnings / skipped lines
/// in the existing log surface.
class PluginRefreshAllResult {
  /// Plugins whose refresh advanced their pin successfully.
  final List<PluginEntry> refreshed;

  /// Plugins whose refresh threw. The error is whatever
  /// [PluginService.refresh] surfaces — typically [StateError] for
  /// network failures or malformed upstream output.
  final List<({PluginEntry plugin, Object error})> failures;

  /// Plugins skipped because [PluginService.refreshAll] was called
  /// with `includePinned: false` and the plugin had
  /// `auto_update == false`.
  final List<PluginEntry> skipped;

  const PluginRefreshAllResult({
    required this.refreshed,
    required this.failures,
    required this.skipped,
  });

  bool get hasAnyFailure => failures.isNotEmpty;
  int get totalAttempted => refreshed.length + failures.length;
}

/// Parsed plugin URL. Handles the D9 accepted schemes and the D8
/// subdirectory convention.
class PluginUrl {
  /// Normalized URL used as the D5 canonical ID.
  final String canonical;

  /// Real URL to pass to `git clone`.
  final String cloneUrl;

  /// Subdirectory inside the cloned repo that holds the plugin
  /// (manifest.json + plugin.nix). Null means the repo root is the
  /// plugin root.
  final String? subdir;

  /// True for schemes that bypass the default HTTPS-only posture.
  final bool insecure;

  const PluginUrl({
    required this.canonical,
    required this.cloneUrl,
    this.subdir,
    required this.insecure,
  });

  static PluginUrl parse(
    String raw, {
    bool allowInsecure = false,
    String? subdir,
  }) {
    // Canonical URLs for non-github schemes encode the subdir as
    // `?dir=<subdir>` (produced by [_withSubdir]). When we re-parse
    // a stored PluginEntry.id (e.g. during `plugin refresh`), split
    // that query-string suffix off before handing to the scheme
    // parsers — then fold it back in via [_withSubdir] on the way
    // out. Keeps the round-trip deterministic.
    String effectiveRaw = raw;
    String? embeddedSubdir;
    final qIdx = raw.indexOf('?dir=');
    if (qIdx >= 0) {
      embeddedSubdir = raw.substring(qIdx + '?dir='.length);
      effectiveRaw = raw.substring(0, qIdx);
    }

    final base = _parseBase(effectiveRaw, allowInsecure: allowInsecure);
    final finalSubdir = subdir ?? embeddedSubdir;
    if (finalSubdir == null || finalSubdir.isEmpty) return base;
    final normalized = finalSubdir.replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return base;
    if (base.subdir != null) {
      if (base.subdir == normalized) return base;
      throw FormatException(
        'URL `$raw` already specifies subdir `${base.subdir}`; '
        'cannot combine with --subdir=$normalized.',
      );
    }
    return base._withSubdir(normalized);
  }

  static PluginUrl _parseBase(String raw, {required bool allowInsecure}) {
    if (raw.startsWith('github:')) {
      return _parseGithub(raw);
    }
    if (raw.startsWith('forgejo:')) {
      return _parseHostedGit(raw, 'forgejo:');
    }
    if (raw.startsWith('gitea:')) {
      return _parseHostedGit(raw, 'gitea:');
    }
    if (raw.startsWith('https://')) {
      return PluginUrl(canonical: raw, cloneUrl: raw, insecure: false);
    }
    // Bare absolute local path — equivalent to file:// but saves the
    // user from worrying about URL syntax. Shell-expanded `~/...`
    // lands here.
    if (raw.startsWith('/')) {
      if (!allowInsecure) {
        throw FormatException(
          '`$raw` is a local path. Pass --insecure to opt in.',
        );
      }
      return PluginUrl(
        canonical: 'file://$raw',
        cloneUrl: 'file://$raw',
        insecure: true,
      );
    }
    if (raw.startsWith('file://') ||
        raw.startsWith('http://') ||
        raw.startsWith('ssh://')) {
      // `file://~/...` is a common footgun: the shell doesn't expand
      // `~` when it's inside a URL, so git reads `~` as the hostname
      // and fails with a confusing "does not appear to be a git
      // repository" message. Catch it here with a clearer hint.
      if (raw.startsWith('file://~')) {
        throw FormatException(
          '`$raw` contains `~` that the shell did not expand '
          '(because it sits inside a URL). Either drop the `file://` '
          'prefix so the shell expands `~/...`, or substitute your '
          'home path explicitly (e.g. file:///home/you/...).',
        );
      }
      if (!allowInsecure) {
        throw FormatException(
          '`$raw` uses an insecure scheme. Pass --insecure to override.',
        );
      }
      return PluginUrl(canonical: raw, cloneUrl: raw, insecure: true);
    }
    throw FormatException(
      'Unsupported URL in `$raw`. '
      'Accepted: github:owner/repo, forgejo:host/owner/repo, '
      'gitea:host/owner/repo, https://host/repo, or a bare '
      'absolute path (/home/you/...). '
      'file://, http://, ssh:// require --insecure.',
    );
  }

  static PluginUrl _parseGithub(String raw) {
    final path = raw.substring('github:'.length);
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) {
      throw FormatException(
        'Invalid github URL `$raw`. Expected `github:owner/repo[/subdir]`.',
      );
    }
    final owner = segments[0];
    final repo = segments[1];
    final subdirParts = segments.sublist(2);
    final subdir = subdirParts.isEmpty ? null : subdirParts.join('/');
    final canonical = subdir == null
        ? 'github:$owner/$repo'
        : 'github:$owner/$repo/$subdir';
    return PluginUrl(
      canonical: canonical,
      cloneUrl: 'https://github.com/$owner/$repo',
      subdir: subdir,
      insecure: false,
    );
  }

  /// Shared parser for self-hosted shortcut schemes (forgejo:, gitea:)
  /// where the host must be specified because the instance isn't
  /// implicit. Shape: `<scheme>host/owner/repo[/subdir]`.
  static PluginUrl _parseHostedGit(String raw, String schemePrefix) {
    final path = raw.substring(schemePrefix.length);
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 3) {
      throw FormatException(
        'Invalid $schemePrefix URL `$raw`. '
        'Expected `${schemePrefix}host/owner/repo[/subdir]`.',
      );
    }
    final host = segments[0];
    final owner = segments[1];
    final repo = segments[2];
    final subdirParts = segments.sublist(3);
    final subdir = subdirParts.isEmpty ? null : subdirParts.join('/');
    final canonical = subdir == null
        ? '$schemePrefix$host/$owner/$repo'
        : '$schemePrefix$host/$owner/$repo/$subdir';
    return PluginUrl(
      canonical: canonical,
      cloneUrl: 'https://$host/$owner/$repo',
      subdir: subdir,
      insecure: false,
    );
  }

  /// Return a copy with the subdir set. Updates [canonical] using
  /// the scheme's native convention — path-form for `github:`
  /// (matches Nix flake URI syntax), `?dir=<subdir>` query-form
  /// otherwise. Precondition: this PluginUrl has no subdir set.
  PluginUrl _withSubdir(String sub) {
    final newCanonical = canonical.startsWith('github:')
        ? '$canonical/$sub'
        : '$canonical?dir=$sub';
    return PluginUrl(
      canonical: newCanonical,
      cloneUrl: cloneUrl,
      subdir: sub,
      insecure: insecure,
    );
  }

  /// Directory name for this plugin under `~/nixblitz/plugins/`.
  /// Not guaranteed unique — [PluginService] resolves collisions by
  /// appending a numeric suffix.
  String deriveDirName() {
    final base = _deriveRepoBaseName();
    if (subdir == null || subdir!.isEmpty) return base;
    return '$base-${subdir!.replaceAll("/", "-")}';
  }

  String _deriveRepoBaseName() {
    // Shortcut schemes: pull owner/repo out of the canonical path,
    // skipping the scheme and (for self-hosted) the host segment.
    for (final entry in const {
      'github:': 0, // owner at index 0 after scheme
      'forgejo:': 1, // host owns index 0, owner at index 1
      'gitea:': 1,
    }.entries) {
      final scheme = entry.key;
      final ownerIdx = entry.value;
      if (!canonical.startsWith(scheme)) continue;
      final rest = canonical.substring(scheme.length);
      final stripped = rest.contains('?')
          ? rest.substring(0, rest.indexOf('?'))
          : rest;
      final segs = stripped.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.length >= ownerIdx + 2) {
        return '${segs[ownerIdx]}-${segs[ownerIdx + 1]}';
      }
      return segs.join('-');
    }
    final uri = Uri.tryParse(cloneUrl);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      var last = uri.pathSegments.last;
      if (last.endsWith('.git')) {
        last = last.substring(0, last.length - 4);
      }
      if (last.isNotEmpty) return _sanitize(last);
    }
    return 'plugin';
  }

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
