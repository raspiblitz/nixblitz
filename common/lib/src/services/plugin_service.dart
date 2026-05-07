import 'dart:async';
import 'dart:io';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_install_preview.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/git_service.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_list_regen.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

/// Manages installed plugins under `~/nixblitz/plugins/<id>/`.
///
/// Path-A unified plugin design: each install writes a per-plugin
/// marker file at `<pluginsDir>/<id>/.nixblitz-installed.json` and
/// triggers a regenerate of `<baseDir>/plugins.list` so
/// `installed.nix` picks up the new module on next eval.
///
/// Side effects land in the working tree — no git commits here. The
/// user's next Apply captures every change via `git add -A`.
class PluginService {
  final String baseDir;
  final ConfigService configService;

  /// Fixed clone timeout. Remote repos that misbehave shouldn't hang
  /// the TUI — 60 s is generous for a shallow clone.
  static const _cloneTimeout = Duration(seconds: 60);

  PluginService({required this.baseDir})
    : configService = ConfigService(baseDir: baseDir);

  String get pluginsDir => '$baseDir/plugins';

  /// Install a plugin from [rawUrl]. Clones to a tmpdir, validates
  /// the manifest, then (optionally) hands a [PluginInstallPreview]
  /// to [confirm] before copying the plugin tree into
  /// `plugins/<id>/`, writing the [PluginMarker], and regenerating
  /// `plugins.list`.
  ///
  /// [allowInsecure] must be true for `file://`, `http://`, or
  /// `ssh://` URLs.
  ///
  /// [confirm] runs after the manifest has been parsed but before
  /// any state lands on disk. Returning `false` aborts cleanly with
  /// [PluginInstallCancelled]. `null` (the default) skips the prompt
  /// — the caller has either already collected consent (`--yes`) or
  /// is invoking install from a non-interactive context.
  ///
  /// ID collisions reject hard: if `<pluginsDir>/<id>/` already
  /// exists with a marker pinning a different URL, this throws
  /// [StateError] rather than auto-suffixing.
  Future<PluginMarker> install(
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

    final tmpDir = await Directory.systemTemp.createTemp('nixblitz-plugin-');

    // Tracks the post-manifest plugin dir so we can roll back a
    // half-created install on failure. Stays null until we've
    // resolved the manifest's id and committed to a target dir,
    // which means errors thrown earlier (parse, clone, manifest
    // missing) won't mistakenly wipe an unrelated existing plugin.
    Directory? committedPluginDir;

    try {
      await _gitClone(parsed.cloneUrl, branch, tmpDir.path);
      final pinnedRev = await _gitRevParseHead(tmpDir.path);

      // Safety: the source repo must not contain symlinks. A
      // malicious plugin could ship plugin.nix as a symlink to e.g.
      // /etc/shadow; `File.copySync` follows links, which would
      // land sensitive content in the tracked config repo.
      _rejectSymlinks(tmpDir.path);

      final pluginSourceDir = parsed.subdir == null
          ? tmpDir.path
          : '${tmpDir.path}/${parsed.subdir}';

      // If there's no manifest where we expected one, the repo is
      // likely a multi-plugin bundle — scan for candidates and list
      // them so the user can re-run with --subdir.
      if (!File('$pluginSourceDir/plugin.json').existsSync()) {
        if (parsed.subdir == null) {
          final candidates = _listPluginSubdirs(tmpDir.path);
          if (candidates.isEmpty) {
            throw StateError(
              'No plugin found in this repo: no plugin.json at the root '
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
            'plugin.json not found at subdir `${parsed.subdir}` in the '
            'cloned repo.',
          );
        }
      }

      final manifest = _readManifest(pluginSourceDir);
      _requirePluginNix(pluginSourceDir);

      final id = manifest.id;
      final pluginDir = Directory('$pluginsDir/$id');
      // ID collision: a different URL already owns this id, or the
      // same URL is already actively installed.
      if (pluginDir.existsSync()) {
        final existing = readMarker(pluginDir.path);
        if (existing != null && existing.url != parsed.canonical) {
          throw StateError(
            'Plugin id collision: `$id` is already installed from '
            '${existing.url}. Cannot install ${parsed.canonical} '
            'under the same id.',
          );
        }
        if (existing != null && !existing.disabled) {
          throw StateError('Plugin already installed: $id');
        }
      }

      // Capture commit signature (Approach A) BEFORE the consent
      // callback so the preview can render fingerprint + status.
      final signature = await GitService(repoDir: tmpDir.path).verifyCommit();

      // Consent gate. Hand the manifest metadata + signature to the
      // caller's prompt; if it returns false, abort cleanly so
      // nothing lands on disk.
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

      // Move staging into place. If a disabled marker existed, wipe
      // first — reinstall over a disabled plugin is a fresh install.
      //
      // KNOWN EDGE CASE: this wipes the existing dir BEFORE the new
      // copy / marker write succeeds, so a mid-install failure
      // (disk-full mid-copy, network glitch on intent-to-add) leaves
      // the operator with neither the old disabled plugin nor a
      // working new one. Phase 1 was safe by construction (always-new
      // dirName); reusing the slot here introduces a small destructive
      // window. Acceptable for alpha; revisit by staging to <id>.tmp/
      // and atomic-rename if a real operator hits it.
      if (!Directory(pluginsDir).existsSync()) {
        Directory(pluginsDir).createSync(recursive: true);
      }
      if (pluginDir.existsSync()) {
        pluginDir.deleteSync(recursive: true);
      }
      pluginDir.createSync();
      committedPluginDir = pluginDir;

      // Copy the plugin's published files. Anything else in the
      // upstream repo (.git/, top-level docs, tests/) is dropped —
      // we only ship what installed.nix needs to import + the docs
      // an operator might want to read post-install.
      _copyPluginFiles(pluginSourceDir, pluginDir.path);

      // Initialize app_configs.<id> from the manifest's config_schema
      // defaults if the operator doesn't already have an entry.
      // Idempotent on reinstall — preserves the operator's edits.
      if (manifest.configSchema != null) {
        final config = configService.configExists()
            ? await configService.readConfig()
            : NixblitzConfig.defaults();
        if (!config.appConfigs.containsKey(id)) {
          final defaults = <String, dynamic>{};
          for (final field in manifest.configSchema!.fields) {
            defaults[field.name] = _defaultValueOf(field);
          }
          await configService.writeConfig(config.setAppConfig(id, defaults));
        }
      }

      // Write the marker.
      final marker = PluginMarker(
        id: id,
        url: parsed.canonical,
        version: manifest.version ?? '',
        rev: pinnedRev,
        installedAt: DateTime.now().toUtc(),
        disabled: false,
        branch: branch,
        autoUpdate: true,
        signatureFingerprint: signature.fingerprint.isEmpty
            ? null
            : signature.fingerprint,
      );
      writeMarker(pluginDir.path, marker);

      // Mark the new plugin files as intent-to-add so the Apply
      // view's `git diff` renders them as new-file additions
      // instead of hiding them as untracked. Best-effort.
      await _gitIntentToAdd(pluginDir.path);

      // Regenerate plugins.list from the marker set. We pass every
      // non-disabled marker id as `satisfied` because PluginService
      // doesn't have a synchronous view of the dep-check result at
      // install time — the Riverpod provider that reads markers
      // applies dep filtering at runtime for the streamer registry,
      // and each plugin's `lib.mkIf cfg.enable` gate keeps inactive
      // plugins inert at Nix-eval time.
      _regen();

      LogService.info(
        'PluginService: installed $id '
        '($pinnedRev, schema=${manifest.schemaVersion})',
      );
      return marker;
    } catch (e, st) {
      // Roll back a half-created plugin dir so the user's next
      // Apply review isn't littered with partial state. Only fires
      // when we got past _readManifest — earlier errors have no
      // committedPluginDir.
      if (committedPluginDir != null && committedPluginDir.existsSync()) {
        try {
          committedPluginDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      // User-cancellation is an expected outcome — log at info, no
      // stack.
      if (e is PluginInstallCancelled) rethrow;
      LogService.error('PluginService.install failed for $rawUrl', e, st);
      rethrow;
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Hard delete: wipes the marker, the plugin directory, and
  /// triggers a `plugins.list` regen. No tombstone.
  Future<void> remove(String id) async {
    final pluginDir = Directory('$pluginsDir/$id');
    if (!pluginDir.existsSync()) {
      throw StateError('Plugin not installed: $id');
    }
    pluginDir.deleteSync(recursive: true);
    _regen();
    LogService.info('PluginService: removed $id');
  }

  /// Soft toggle — flips `disabled: true` on the marker, leaves the
  /// dir in place, regenerates plugins.list (drops the path).
  Future<PluginMarker> disable(String id) async => _setDisabled(id, true);

  /// Inverse of [disable].
  Future<PluginMarker> enable(String id) async => _setDisabled(id, false);

  Future<PluginMarker> _setDisabled(String id, bool disabled) async {
    final pluginDir = Directory('$pluginsDir/$id');
    final m = readMarker(pluginDir.path);
    if (m == null) throw StateError('Plugin not installed: $id');
    final updated = m.copyWith(disabled: disabled);
    writeMarker(pluginDir.path, updated);
    _regen();
    return updated;
  }

  /// Re-fetch a plugin from its stored URL, updating the pinned
  /// rev + file contents. Used as a less-destructive alternative to
  /// the `plugin remove && plugin add` dance whenever the upstream
  /// plugin source moves.
  ///
  /// The plugin's `id` and `branch` stay the same; only `rev`,
  /// `version`, and `signatureFingerprint` are updated. Leaves the
  /// working tree dirty — next Apply commits the refreshed files
  /// alongside any other staged changes.
  ///
  /// Approach-A signature mismatch (pinned fingerprint differs from
  /// the new commit's fingerprint, or the new commit is unsigned
  /// where the old was signed) throws [PluginSignatureMismatch].
  Future<PluginMarker> refresh(String id, {bool allowInsecure = false}) async {
    final pluginDir = Directory('$pluginsDir/$id');
    final existing = readMarker(pluginDir.path);
    if (existing == null) throw StateError('Plugin not installed: $id');
    final parsed = PluginUrl.parse(existing.url, allowInsecure: allowInsecure);

    final tmpDir = await Directory.systemTemp.createTemp(
      'nixblitz-plugin-refresh-',
    );
    try {
      await _gitClone(parsed.cloneUrl, existing.branch, tmpDir.path);
      final pinnedRev = await _gitRevParseHead(tmpDir.path);

      // Idempotent no-op when pin matches. Touching the marker on
      // every poll would dirty the working tree even when nothing
      // moved upstream.
      if (pinnedRev == existing.rev) {
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

      if (!File('$pluginSourceDir/plugin.json').existsSync()) {
        throw StateError(
          'plugin.json not found at subdir '
          '`${parsed.subdir ?? "(root)"}` in the refreshed repo.',
        );
      }
      final manifest = _readManifest(pluginSourceDir);
      _requirePluginNix(pluginSourceDir);

      // Approach A signature check. Three cases:
      // - existing pin null + new fp: silent upgrade — adopt the
      //   new fp into the marker.
      // - existing pin set + new fp matches: silent re-affirm.
      // - existing pin set + new fp differs (or new is empty):
      //   throw PluginSignatureMismatch. Caller decides how to
      //   surface (CLI prints + suggests `plugin remove` +
      //   `plugin add` to re-consent; refreshAll captures into
      //   `failures`).
      final newSignature = await GitService(
        repoDir: tmpDir.path,
      ).verifyCommit();
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

      // Wipe + repopulate. Marker is rewritten with the new rev;
      // there's no per-plugin config.json to preserve since plugin
      // config now lives in the main config.json's app_configs map.
      pluginDir.deleteSync(recursive: true);
      pluginDir.createSync(recursive: true);
      _copyPluginFiles(pluginSourceDir, pluginDir.path);

      final updated = existing.copyWith(
        version: manifest.version ?? existing.version,
        rev: pinnedRev,
        signatureFingerprint: newFp,
        clearSignatureFingerprint: newFp == null,
      );
      writeMarker(pluginDir.path, updated);

      await _gitIntentToAdd(pluginDir.path);
      _regen();

      LogService.info(
        'PluginService: refreshed ${existing.id} '
        '(pin: ${existing.rev} → $pinnedRev, '
        'schema=${manifest.schemaVersion})',
      );
      return updated;
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Refresh every installed plugin in order.
  ///
  /// - When [includePinned] is `false`, plugins with
  ///   `autoUpdate == false` are skipped. Used by the Update-view
  ///   integration so per-plugin pins behave like opt-out from
  ///   system-wide refresh.
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
    final refreshed = <PluginMarker>[];
    final failures = <({PluginMarker plugin, Object error})>[];
    final skipped = <PluginMarker>[];
    for (final p in active) {
      if (!includePinned && !p.autoUpdate) {
        skipped.add(p);
        continue;
      }
      try {
        refreshed.add(await refresh(p.id, allowInsecure: allowInsecure));
      } catch (e, st) {
        LogService.error('PluginService.refreshAll: ${p.id} failed', e, st);
        failures.add((plugin: p, error: e));
      }
    }
    return PluginRefreshAllResult(
      refreshed: refreshed,
      failures: failures,
      skipped: skipped,
    );
  }

  /// Mark [id] as `autoUpdate = false`. The next bulk refresh skips
  /// it. Direct `plugin refresh <id>` ignores the flag and still
  /// works.
  Future<PluginMarker> pin(String id) async => _setAutoUpdate(id, false);

  /// Inverse of [pin]: re-enable bulk auto-refresh for [id].
  Future<PluginMarker> unpin(String id) async => _setAutoUpdate(id, true);

  Future<PluginMarker> _setAutoUpdate(String id, bool value) async {
    final pluginDir = Directory('$pluginsDir/$id');
    final m = readMarker(pluginDir.path);
    if (m == null) throw StateError('Plugin not installed: $id');
    final updated = m.copyWith(autoUpdate: value);
    writeMarker(pluginDir.path, updated);
    return updated;
  }

  /// Active markers, sorted by id for stable output. Pass
  /// [includeDisabled] for the disabled set too.
  Future<List<PluginMarker>> list({bool includeDisabled = false}) async {
    final markers = discoverInstalledMarkers(pluginsDir);
    final filtered = includeDisabled
        ? markers
        : markers.where((m) => !m.disabled).toList();
    filtered.sort((a, b) => a.id.compareTo(b.id));
    return filtered;
  }

  /// Load an installed plugin's manifest from disk. Used by the
  /// Configure view to know which form fields to render. Throws
  /// [StateError] if the plugin dir / plugin.json is missing and
  /// [FormatException] / [PluginTooNewException] on parse failures.
  PluginManifest readManifest(String id) {
    final f = File('$pluginsDir/$id/plugin.json');
    if (!f.existsSync()) {
      throw StateError(
        'plugin.json not found for plugin `$id`. Is it installed?',
      );
    }
    return PluginManifest.fromJsonString(f.readAsStringSync());
  }

  // ── private ──────────────────────────────────────────────────

  /// Regenerate plugins.list from the current marker set. Passes
  /// every non-disabled marker id as `satisfied` — see
  /// `regeneratePluginsList` in `plugin_list_regen.dart`. The Nix
  /// module path includes every marker; runtime gating (dep check)
  /// happens in the Riverpod provider for the streamer registry,
  /// and at Nix-eval time via each plugin's `lib.mkIf cfg.enable`
  /// gate inside its plugin.nix.
  void _regen() {
    final markers = discoverInstalledMarkers(pluginsDir);
    final eligibleIds = markers
        .where((m) => !m.disabled)
        .map((m) => m.id)
        .toSet();
    regeneratePluginsList(baseDir: baseDir, satisfiedPluginIds: eligibleIds);
  }

  /// Copy the canonical plugin file set from [src] into [dst].
  /// `plugin.json` and `plugin.nix` are required (caller has
  /// already verified them); `README.md` and `LICENSE` are copied
  /// when present; the optional `streamers/` directory is copied
  /// recursively when present.
  void _copyPluginFiles(String src, String dst) {
    for (final name in const [
      'plugin.json',
      'plugin.nix',
      'README.md',
      'LICENSE',
    ]) {
      final f = File('$src/$name');
      if (f.existsSync()) f.copySync('$dst/$name');
    }
    final streamers = Directory('$src/streamers');
    if (streamers.existsSync()) {
      _copyDir(streamers, Directory('$dst/streamers'));
    }
  }

  void _copyDir(Directory src, Directory dst) {
    if (!dst.existsSync()) dst.createSync(recursive: true);
    for (final entity in src.listSync(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (entity is File) {
        entity.copySync('${dst.path}/$name');
      } else if (entity is Directory) {
        _copyDir(entity, Directory('${dst.path}/$name'));
      }
      // Links rejected upstream by _rejectSymlinks; ignore
      // defensively here so a future refactor doesn't accidentally
      // open a hole.
    }
  }

  /// Pull a config_schema field's default value out without
  /// caring about its concrete subtype. AppConfigField is sealed
  /// with five subclasses, each declaring its own `defaultValue`
  /// of a different type (bool / String / int / list…); this helper
  /// uses dynamic dispatch through `(field as dynamic).defaultValue`
  /// so the install path doesn't need a per-type switch.
  Object? _defaultValueOf(dynamic field) {
    try {
      return field.defaultValue;
    } catch (_) {
      return null;
    }
  }

  Future<void> _gitClone(String url, String branch, String target) async {
    final r = await Process.run(
      'git',
      [
        'clone',
        '--depth',
        '1',
        '--branch',
        branch,
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
  List<String> _listPluginSubdirs(String repoDir) {
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
  Future<void> _gitIntentToAdd(String path) async {
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
  void _rejectSymlinks(String dir) {
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

  Future<String> _gitRevParseHead(String repoDir) async {
    final r = await Process.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: repoDir);
    if (r.exitCode != 0) {
      throw StateError('git rev-parse failed: ${(r.stderr as String).trim()}');
    }
    return (r.stdout as String).trim();
  }

  PluginManifest _readManifest(String dir) {
    final f = File('$dir/plugin.json');
    if (!f.existsSync()) {
      throw StateError('plugin.json not found at $dir');
    }
    return PluginManifest.fromJsonString(f.readAsStringSync());
  }

  void _requirePluginNix(String dir) {
    if (!File('$dir/plugin.nix').existsSync()) {
      throw StateError('plugin.nix not found at $dir');
    }
  }
}

/// Aggregate result from [PluginService.refreshAll]. The Update-view
/// integration in `tui/lib/src/ui/views/update_view.dart` walks
/// these three lists to render successes / warnings / skipped lines
/// in the existing log surface.
class PluginRefreshAllResult {
  /// Plugins whose refresh advanced their pin successfully.
  final List<PluginMarker> refreshed;

  /// Plugins whose refresh threw. The error is whatever
  /// [PluginService.refresh] surfaces — typically [StateError] for
  /// network failures or malformed upstream output, or
  /// [PluginSignatureMismatch] when the publisher key changed.
  final List<({PluginMarker plugin, Object error})> failures;

  /// Plugins skipped because [PluginService.refreshAll] was called
  /// with `includePinned: false` and the plugin had
  /// `autoUpdate == false`.
  final List<PluginMarker> skipped;

  const PluginRefreshAllResult({
    required this.refreshed,
    required this.failures,
    required this.skipped,
  });

  bool get hasAnyFailure => failures.isNotEmpty;
  int get totalAttempted => refreshed.length + failures.length;
}

/// Parsed plugin URL. Handles the accepted schemes and the
/// subdirectory convention.
class PluginUrl {
  /// Normalized URL used as the canonical ID.
  final String canonical;

  /// Real URL to pass to `git clone`.
  final String cloneUrl;

  /// Subdirectory inside the cloned repo that holds the plugin
  /// (plugin.json + plugin.nix). Null means the repo root is the
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
    // a stored marker.url (e.g. during `plugin refresh`), split
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

  /// Heuristic directory-name derivation kept around for callers
  /// (e.g. older test fixtures) that want a friendly slug for a
  /// URL. The unified design uses the manifest's `id` as the
  /// on-disk directory name, so PluginService itself no longer
  /// needs this helper at install time.
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
