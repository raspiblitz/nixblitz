import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:common/src/models/configure/app_config_field.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_install_preview.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/git_service.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_list_regen.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/plugin/plugin_git_ops.dart';
import 'package:common/src/services/plugin/plugin_url.dart';
import 'package:common/src/services/plugin/plugin_refresh_all_result.dart';
import 'package:common/src/services/wasm/sandbox_policy.dart';

// Re-export the co-located types so existing importers of
// plugin_service.dart keep seeing PluginUrl / PluginRefreshAllResult.
export 'package:common/src/services/plugin/plugin_url.dart';
export 'package:common/src/services/plugin/plugin_refresh_all_result.dart';

/// Install-time sandbox validation. A spend-capable method is only
/// permitted if (a) the daily budget is positive AND (b) its sat cost is
/// attributable from params (v1: only sendtoaddress). Rejecting here
/// means the runtime never faces an un-cappable spend.
void validateSandbox(PluginManifest manifest) {
  final cap = manifest.sandbox?.bitcoinRpc;
  if (cap == null) return;
  for (final method in cap.methods) {
    if (!isSpendCapable(method)) continue;
    if (cap.spendSatsPerDay <= 0) {
      throw FormatException(
        'sandbox: method `$method` can move funds but the plugin\'s '
        'spend_sats_per_day is ${cap.spendSatsPerDay}. Grant a positive '
        'daily budget or remove the method.',
      );
    }
    if (attributedSpendSats(method, const [0, 0.0]) == null) {
      throw FormatException(
        'sandbox: method `$method` has a spend cost that cannot be '
        'attributed from its arguments; it is not permitted in a sandboxed '
        'plugin (v1).',
      );
    }
  }
}

/// Install-time validation of `wasm:` action module paths (design spec
/// §1a). Each action's `module` is resolved against [pluginDir] and must:
///
/// - stay within [pluginDir] (no `../` escape), checked structurally so
///   it also catches a target that doesn't exist yet;
/// - not be reachable only via a symlink pointing outside [pluginDir];
/// - exist as a regular file.
///
/// A malicious/broken path is otherwise only discovered when
/// `WasmActionRunner` tries to load it at action-run time — validating
/// here fails the install/refresh/switch-branch up front, before the
/// plugin tree lands on disk or gets a chance to run.
void validateWasmModulePaths(PluginManifest manifest, String pluginDir) {
  final root = Directory(pluginDir).resolveSymbolicLinksSync();
  final normalizedPluginDir = p.normalize(pluginDir);
  for (final entry in manifest.actions.entries) {
    final wasm = entry.value.wasm;
    if (wasm == null) continue;

    final joined = p.normalize(p.join(pluginDir, wasm.module));
    if (joined != normalizedPluginDir &&
        !p.isWithin(normalizedPluginDir, joined)) {
      throw FormatException(
        'action `${entry.key}`: wasm module `${wasm.module}` escapes the '
        'plugin directory',
      );
    }

    final file = File(joined);
    if (!file.existsSync()) {
      throw FormatException(
        'action `${entry.key}`: wasm module `${wasm.module}` does not exist',
      );
    }

    // Symlink check: the entry itself passed the structural check above,
    // but its target could still point outside the plugin dir. Resolve
    // the real path and require it stays under the plugin dir's real
    // path too.
    final resolved = file.resolveSymbolicLinksSync();
    if (resolved != root && !p.isWithin(root, resolved)) {
      throw FormatException(
        'action `${entry.key}`: wasm module `${wasm.module}` is a symlink '
        'that escapes the plugin directory',
      );
    }
  }
}

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
    String? branch,
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
      // Initial clone — uses the caller's branch when explicit,
      // otherwise falls back to the remote's default HEAD. The
      // manifest may redirect us to a different ref via its
      // `branches` block; a second clone below handles that case.
      await gitClonePlugin(parsed.cloneUrl, branch, tmpDir.path);
      var pinnedRev = await gitRevParseHead(tmpDir.path);

      // Safety: the source repo must not contain symlinks. A
      // malicious plugin could ship plugin.nix as a symlink to e.g.
      // /etc/shadow; `File.copySync` follows links, which would
      // land sensitive content in the tracked config repo.
      rejectSymlinks(tmpDir.path);

      final pluginSourceDir = parsed.subdir == null
          ? tmpDir.path
          : '${tmpDir.path}/${parsed.subdir}';

      // If there's no manifest where we expected one, the repo is
      // likely a multi-plugin bundle — scan for candidates and list
      // them so the user can re-run with --subdir.
      if (!File('$pluginSourceDir/plugin.json').existsSync()) {
        if (parsed.subdir == null) {
          final candidates = listPluginSubdirs(tmpDir.path);
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

      var manifest = readPluginManifest(pluginSourceDir);
      validateSandbox(manifest);
      requireModuleOrLogicOnly(pluginSourceDir, manifest);
      validateWasmModulePaths(manifest, pluginSourceDir);

      // Default-branch resolution: when the caller didn't pin a
      // branch and the manifest declares a default, re-clone at the
      // declared default's ref. Explicit --branch always wins; a
      // manifest without a branches block or without a default:true
      // entry falls through to whatever the remote served up on the
      // initial clone (typically `main`).
      if (branch == null && manifest.branches?.defaultKey != null) {
        final dk = manifest.branches!.defaultKey!;
        final resolvedRef = manifest.branches!.branches[dk]!.ref;
        // Skip the re-clone when the initial clone already landed on
        // the declared default — saves a network round-trip on the
        // happy path where the publisher's remote HEAD matches their
        // declared default.
        final currentBranch = await gitCurrentBranch(tmpDir.path);
        if (currentBranch != resolvedRef) {
          await tmpDir.delete(recursive: true);
          await Directory(tmpDir.path).create(recursive: true);
          await gitClonePlugin(parsed.cloneUrl, resolvedRef, tmpDir.path);
          pinnedRev = await gitRevParseHead(tmpDir.path);
          rejectSymlinks(tmpDir.path);
          // Re-validate the manifest at the resolved ref. The
          // publisher's branches block should be consistent across
          // branches, but the per-branch manifest may legitimately
          // diverge (e.g. different `version`); reading from the
          // chosen ref keeps marker.version honest.
          if (!File('$pluginSourceDir/plugin.json').existsSync()) {
            throw StateError(
              'plugin.json not found at the resolved branch `$resolvedRef`',
            );
          }
          manifest = readPluginManifest(pluginSourceDir);
          validateSandbox(manifest);
          requireModuleOrLogicOnly(pluginSourceDir, manifest);
          validateWasmModulePaths(manifest, pluginSourceDir);
        }
        branch = resolvedRef;
      }

      // Marker.branch must always be a concrete ref name. When the
      // caller didn't pin one and no manifest default applied,
      // capture the cloned HEAD's branch so refresh() has something
      // to re-clone from.
      final effectiveBranch = branch ?? await gitCurrentBranch(tmpDir.path);

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
          branch: effectiveBranch,
          pinnedRev: pinnedRev,
          schemaVersion: manifest.schemaVersion,
          signature: signature,
          secretFieldNames: _secretFieldNames(manifest),
          sandbox: manifest.sandbox,
          hasNixModule: manifest.module != null,
          isLogicOnly: manifest.isLogicOnly,
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
      // an operator might want to read post-install. Tile manifests
      // declared in the plugin's manifest are pulled along by path.
      _copyPluginFiles(
        pluginSourceDir,
        pluginDir.path,
        extraRelPaths: manifest.tileManifests,
      );

      // Initialize app_configs.<id> from the manifest's config_schema
      // defaults if the operator doesn't already have an entry.
      // Idempotent on reinstall — preserves the operator's edits.
      //
      // Override: force `enabled = true` regardless of the manifest's
      // own default. The catalog UI calls this action "Install" — an
      // operator clicking that expects the plugin to be running after
      // Apply, not sitting on disk inert until they go re-toggle it
      // in Configure. Plugins whose manifest defaults `enabled: false`
      // were doing it for safety, but the operator's explicit
      // install-via-UI is the consent signal that supersedes that
      // default. Apply still gates activation, so the operator has
      // one more checkpoint before the service starts.
      if (manifest.configSchema != null) {
        final config = configService.configExists()
            ? await configService.readConfig()
            : NixblitzConfig.defaults();
        if (!config.appConfigs.containsKey(id)) {
          final defaults = <String, dynamic>{};
          for (final field in manifest.configSchema!.fields) {
            defaults[field.name] = _defaultValueOf(field);
          }
          if (defaults.containsKey('enabled')) {
            defaults['enabled'] = true;
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
        branch: effectiveBranch,
        autoUpdate: true,
        signatureFingerprint: signature.fingerprint.isEmpty
            ? null
            : signature.fingerprint,
      );
      writeMarker(pluginDir.path, marker);

      // Mark the new plugin files as intent-to-add so the Apply
      // view's `git diff` renders them as new-file additions
      // instead of hiding them as untracked. Best-effort.
      await gitIntentToAdd(pluginDir.path, baseDir: baseDir);

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
      await gitClonePlugin(parsed.cloneUrl, existing.branch, tmpDir.path);
      final pinnedRev = await gitRevParseHead(tmpDir.path);

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

      rejectSymlinks(tmpDir.path);

      final pluginSourceDir = parsed.subdir == null
          ? tmpDir.path
          : '${tmpDir.path}/${parsed.subdir}';

      if (!File('$pluginSourceDir/plugin.json').existsSync()) {
        throw StateError(
          'plugin.json not found at subdir '
          '`${parsed.subdir ?? "(root)"}` in the refreshed repo.',
        );
      }
      final manifest = readPluginManifest(pluginSourceDir);
      validateSandbox(manifest);
      requireModuleOrLogicOnly(pluginSourceDir, manifest);
      validateWasmModulePaths(manifest, pluginSourceDir);

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
      _copyPluginFiles(
        pluginSourceDir,
        pluginDir.path,
        extraRelPaths: manifest.tileManifests,
      );

      final updated = existing.copyWith(
        version: manifest.version ?? existing.version,
        rev: pinnedRev,
        signatureFingerprint: newFp,
        clearSignatureFingerprint: newFp == null,
      );
      writeMarker(pluginDir.path, updated);

      await gitIntentToAdd(pluginDir.path, baseDir: baseDir);
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

  /// Re-clone the plugin's source at [newBranch] (mirrors `install` /
  /// `refresh` but takes a branch override). Used to switch branches
  /// after install.
  ///
  /// Refuses on pinned plugins (`autoUpdate == false`) — throws
  /// [PluginPinnedException]. Idempotent no-op when [newBranch]
  /// matches the marker's current branch.
  ///
  /// [confirm] is invoked with a [PluginInstallPreview] built from the
  /// new clone (branch, rev, manifest, signature) before any files
  /// land on disk. Returning `false` aborts with
  /// [PluginInstallCancelled]. The new fingerprint replaces the
  /// marker's pinned one on confirm (unlike `refresh`, which throws on
  /// fingerprint change — branch switch is explicit, not a quiet
  /// upgrade, so the operator's confirmation IS the re-consent).
  Future<PluginMarker> switchBranch(
    String id,
    String newBranch, {
    bool allowInsecure = false,
    PluginInstallConfirm? confirm,
  }) async {
    final pluginDir = Directory('$pluginsDir/$id');
    final existing = readMarker(pluginDir.path);
    if (existing == null) throw StateError('Plugin not installed: $id');

    if (!existing.autoUpdate) throw PluginPinnedException(pluginId: id);

    if (newBranch == existing.branch) {
      LogService.info(
        'PluginService: switchBranch $id no-op (already on $newBranch)',
      );
      return existing;
    }

    final parsed = PluginUrl.parse(existing.url, allowInsecure: allowInsecure);

    final tmpDir = await Directory.systemTemp.createTemp(
      'nixblitz-plugin-switch-',
    );
    try {
      await gitClonePlugin(parsed.cloneUrl, newBranch, tmpDir.path);
      final pinnedRev = await gitRevParseHead(tmpDir.path);

      rejectSymlinks(tmpDir.path);

      final pluginSourceDir = parsed.subdir == null
          ? tmpDir.path
          : '${tmpDir.path}/${parsed.subdir}';

      if (!File('$pluginSourceDir/plugin.json').existsSync()) {
        throw StateError(
          'plugin.json not found at subdir '
          '`${parsed.subdir ?? "(root)"}` in the switched repo.',
        );
      }
      final manifest = readPluginManifest(pluginSourceDir);
      validateSandbox(manifest);
      requireModuleOrLogicOnly(pluginSourceDir, manifest);
      validateWasmModulePaths(manifest, pluginSourceDir);

      final newSignature = await GitService(
        repoDir: tmpDir.path,
      ).verifyCommit();
      final newFp = newSignature.fingerprint.isEmpty
          ? null
          : newSignature.fingerprint;

      // Soft signature check: unlike refresh (which hard-throws on
      // fingerprint mismatch), the consent prompt surfaces the new
      // fingerprint and the operator's confirmation IS the re-consent.
      final preview = PluginInstallPreview(
        name: manifest.name,
        description: manifest.description,
        url: existing.url,
        branch: newBranch,
        pinnedRev: pinnedRev,
        schemaVersion: manifest.schemaVersion,
        signature: newSignature,
        secretFieldNames: _secretFieldNames(manifest),
        sandbox: manifest.sandbox,
        hasNixModule: manifest.module != null,
        isLogicOnly: manifest.isLogicOnly,
      );
      if (confirm != null) {
        final ok = await confirm(preview);
        if (!ok) throw const PluginInstallCancelled();
      }

      // Wipe + repopulate under the new branch.
      pluginDir.deleteSync(recursive: true);
      pluginDir.createSync(recursive: true);
      _copyPluginFiles(
        pluginSourceDir,
        pluginDir.path,
        extraRelPaths: manifest.tileManifests,
      );

      final updated = existing.copyWith(
        branch: newBranch,
        version: manifest.version ?? existing.version,
        rev: pinnedRev,
        signatureFingerprint: newFp,
        clearSignatureFingerprint: newFp == null,
      );
      writeMarker(pluginDir.path, updated);

      await gitIntentToAdd(pluginDir.path, baseDir: baseDir);
      _regen();

      LogService.info(
        'PluginService: switched $id branch ${existing.branch} → $newBranch '
        '(pin ${existing.rev} → $pinnedRev)',
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
    final advanced = <PluginMarker>[];
    final unchanged = <PluginMarker>[];
    final failures = <({PluginMarker plugin, Object error})>[];
    final skipped = <PluginMarker>[];
    for (final p in active) {
      if (!includePinned && !p.autoUpdate) {
        skipped.add(p);
        continue;
      }
      try {
        final result = await refresh(p.id, allowInsecure: allowInsecure);
        if (result.rev == p.rev) {
          unchanged.add(result);
        } else {
          advanced.add(result);
        }
      } catch (e, st) {
        LogService.error('PluginService.refreshAll: ${p.id} failed', e, st);
        failures.add((plugin: p, error: e));
      }
    }
    return PluginRefreshAllResult(
      advanced: advanced,
      unchanged: unchanged,
      failures: failures,
      skipped: skipped,
    );
  }

  /// Mark [id] as `autoUpdate = false`. The next bulk refresh skips
  /// it. Direct `plugin update <id>` ignores the flag and still
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

  /// Names of `type: "secret"` config fields declared by [manifest].
  /// Drives the consent prompt's cleartext-storage warning — see
  /// [PluginInstallPreview.secretFieldNames].
  static List<String> _secretFieldNames(PluginManifest manifest) => [
    for (final f in manifest.configSchema?.fields ?? const <AppConfigField>[])
      if (f is SecretField) f.name,
  ];

  /// Regenerate plugins.list from the current marker set. Passes
  /// every non-disabled, non-logic-only marker id as `satisfied` — see
  /// `regeneratePluginsList` in `plugin_list_regen.dart`. The Nix
  /// module path includes every listed marker; runtime gating (dep
  /// check) happens in the Riverpod provider for the streamer
  /// registry, and at Nix-eval time via each plugin's `lib.mkIf
  /// cfg.enable` gate inside its plugin.nix.
  ///
  /// Logic-only plugins (manifest.isLogicOnly — their entire surface is
  /// sandboxed wasm actions) are excluded. `templates/flake.nix`'s
  /// `pluginModules` derivation imports `<id>/plugin.nix` (falling back
  /// to that filename when the manifest declares no `module`) for
  /// every id in `plugins.list`; a logic-only plugin legitimately ships
  /// no `plugin.nix` at all, so listing it would break the next
  /// `nixos-rebuild` eval with "path does not exist". The wasm runtime
  /// discovers logic-only plugins straight from the marker set — it
  /// has no need for `plugins.list`.
  void _regen() {
    final markers = discoverInstalledMarkers(pluginsDir);
    final eligibleIds = <String>{};
    for (final m in markers) {
      if (m.disabled) continue;
      if (_isLogicOnlyPlugin(m.id)) continue;
      eligibleIds.add(m.id);
    }
    regeneratePluginsList(baseDir: baseDir, satisfiedPluginIds: eligibleIds);
  }

  /// Best-effort `manifest.isLogicOnly` lookup for plugin [id] used by
  /// [_regen]. A manifest that fails to read or parse is treated as
  /// NOT logic-only — the safer failure mode: a genuine module gets
  /// listed and surfaces its error at the next nix eval, rather than a
  /// broken manifest silently vanishing from `plugins.list` with no
  /// operator-visible signal.
  bool _isLogicOnlyPlugin(String id) {
    final f = File('$pluginsDir/$id/plugin.json');
    try {
      final manifest = PluginManifest.fromJsonString(f.readAsStringSync());
      return manifest.isLogicOnly;
    } catch (e, st) {
      LogService.error(
        'PluginService._regen: failed to read/parse manifest for `$id`; '
        'treating as not logic-only so it stays listed',
        e,
        st,
      );
      return false;
    }
  }

  /// Copy the plugin's entire source tree from [src] into [dst].
  ///
  /// A plugin is its directory: `plugin.json` / `plugin.nix` (the
  /// caller already verified these), `README.md`, `LICENSE`, any
  /// helper modules `plugin.nix` imports (e.g. `extension-lib.nix`),
  /// the optional `streamers/` directory, and any declared
  /// `tile_manifests` — all of it. A hardcoded whitelist silently
  /// dropped helper modules, breaking plugins whose `plugin.nix`
  /// imported them; copying the whole tree is the robust shape.
  ///
  /// Only VCS metadata is skipped (`.git`, in [_copyDir]). Symlinks
  /// were rejected upstream by `rejectSymlinks`.
  ///
  /// [extraRelPaths] is the manifest's declared `tile_manifests`; the
  /// files themselves are already copied by the full-tree copy, so we
  /// use the list only to warn when a declared manifest is missing
  /// from the source — a packaging error the dashboard would hit at
  /// runtime.
  void _copyPluginFiles(
    String src,
    String dst, {
    List<String> extraRelPaths = const [],
  }) {
    _copyDir(Directory(src), Directory(dst));

    for (final relPath in extraRelPaths) {
      if (!File('$src/$relPath').existsSync()) {
        LogService.warn(
          'plugin install: declared tile manifest $relPath missing in source',
        );
      }
    }
  }

  void _copyDir(Directory src, Directory dst) {
    if (!dst.existsSync()) dst.createSync(recursive: true);
    for (final entity in src.listSync(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      // Never copy VCS metadata — a root-level plugin source (no
      // subdir) is a git clone, so `.git` would otherwise be dragged
      // into the node's plugin dir.
      if (name == '.git') continue;
      if (entity is File) {
        entity.copySync('${dst.path}/$name');
      } else if (entity is Directory) {
        _copyDir(entity, Directory('${dst.path}/$name'));
      }
      // Links rejected upstream by rejectSymlinks; ignore
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
}
