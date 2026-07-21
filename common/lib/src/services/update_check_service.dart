import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/sbom_change.dart';
import 'package:common/src/models/update_status.dart';
import 'package:common/src/services/update/update_check_types.dart';
import 'package:common/src/services/update/flake_lock_parse.dart';
import 'package:common/src/services/update/upstream_prober.dart';
import 'package:common/src/services/update/bounded_process.dart';

// Re-export so existing importers of update_check_service.dart keep
// seeing these types (UpstreamProbeResult / NixBuildPlan / parseDryRunStderr
// / FollowsInput / LockedInput).
export 'package:common/src/services/update/update_check_types.dart';
export 'package:common/src/services/update/flake_lock_parse.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/sbom_service.dart';
import 'package:common/src/services/staging_service.dart';
import 'package:common/src/services/system_service.dart'
    show rebuildAttributeFor;

/// Periodic update-availability checker, invoked by the systemd
/// `nixblitz-check` timer and by the in-TUI `[c]` action.
///
/// One method, one cadence: [runCheck] copies `~/nixblitz/` into a
/// tmpdir, walks plugin markers + flake inputs against their
/// upstream HEAD, runs `nix flake update` + `nix build --dry-run`
/// + `nvd diff`, then writes a [CheckResult] to
/// `update-status.json` and the candidate `flake.lock` /
/// plugin-pin data / nvd diff into the staging dir
/// (`/var/lib/nixblitz-tui/staging/`). Apply consumes the staging
/// artifacts on the next `[a]pply`.
///
/// The probe step is exposed separately as [probeUpstreamMovement]
/// for tests — it's pure-network and doesn't shell out, so unit
/// tests can stub the HTTP client without touching nix at all.
class UpdateCheckService {
  UpdateCheckService({
    required this.flakePath,
    required this.statusPath,
    StagingService? stagingService,
    http.Client? httpClient,
    List<PluginMarker> Function()? markersReader,
  }) : _prober = UpstreamProber(httpClient: httpClient ?? http.Client()),
       _staging = stagingService ?? StagingService(),
       _markersReader =
           markersReader ?? (() => _defaultMarkersReader(flakePath));

  /// Directory holding `flake.nix` + `flake.lock` (the user's
  /// `~/nixblitz/`).
  final String flakePath;

  /// Where to merge the result into. See [updateStatusPath] for the
  /// production default.
  final String statusPath;

  final UpstreamProber _prober;
  final StagingService _staging;

  /// Loads the set of installed plugin markers. Injected by tests
  /// so the plugin walk can run without seeded marker fixtures on
  /// disk. Production default reads `<flakePath>/plugins/` via
  /// [discoverInstalledMarkers].
  final List<PluginMarker> Function() _markersReader;

  // Wall-clock bounds for the shell-outs to nix. Offline, these calls
  // block forever on a git/https fetch to the forge, leaving the
  // dashboard's update-check spinner stuck with nothing surfaced
  // (issue #36). A working check finishes well inside these; they only
  // bite when the network path is actually gone, converting a silent
  // hang into a surfaced TimeoutException.
  static const _flakeUpdateTimeout = Duration(seconds: 60);
  static const _dryRunTimeout = Duration(minutes: 3);
  static const _buildTimeout = Duration(minutes: 10);

  static List<PluginMarker> _defaultMarkersReader(String flakePath) {
    try {
      return discoverInstalledMarkers('$flakePath/plugins');
    } catch (e, st) {
      LogService.error('UpdateCheckService: marker discovery failed', e, st);
      return const [];
    }
  }

  /// Read `system.platform` from the on-disk `config.json`. Falls
  /// back to `'x86'` on any I/O or parse error — that's also the
  /// hardcoded default of `SystemConfig.defaults()`, so a missing
  /// file makes the dry-run target match what a fresh-install
  /// `nixos-rebuild switch` would pick.
  String _readPlatform() {
    try {
      final f = File('$flakePath/config.json');
      if (!f.existsSync()) return 'x86';
      final raw = f.readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return NixblitzConfig.fromJson(json).system.platform;
    } catch (e, st) {
      LogService.warn('UpdateCheckService: platform read failed, default x86');
      LogService.error('platform read trace', e, st);
      return 'x86';
    }
  }

  // ── Public entry points ────────────────────────────────────────

  /// Pure-network probe: walk root flake inputs + installed plugin
  /// markers, query each upstream HEAD, return what's moved. No
  /// subprocesses, no writes — exposed separately from [runCheck]
  /// so unit tests can stub the HTTP client without touching nix.
  Future<UpstreamProbeResult> probeUpstreamMovement() async {
    final lockFile = File('$flakePath/flake.lock');
    if (!lockFile.existsSync()) {
      return UpstreamProbeResult(
        inputsAhead: const [],
        pluginsAhead: const [],
        errors: ['flake.lock not found at $flakePath'],
      );
    }

    final inputsAhead = <InputAhead>[];
    final pluginsAhead = <PluginAhead>[];
    final errors = <String>[];

    try {
      final lock =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
      final inputs = parseRootInputs(lock);
      for (final entry in inputs) {
        try {
          final upstream = await _prober.queryUpstreamRev(entry);
          if (upstream == null) {
            errors.add('${entry.name}: upstream not queryable');
            continue;
          }
          if (upstream != entry.lockedRev) {
            inputsAhead.add(
              InputAhead(
                name: entry.name,
                currentRev: entry.lockedRev,
                upstreamRev: upstream,
                url: entry.urlForDisplay,
              ),
            );
          }
        } catch (e, st) {
          LogService.error(
            'UpdateCheckService: input ${entry.name} threw',
            e,
            st,
          );
          errors.add('${entry.name}: $e');
        }
      }
    } catch (e, st) {
      LogService.error(
        'UpdateCheckService.probe: flake.lock parse failed',
        e,
        st,
      );
      errors.add('flake.lock parse failed: $e');
    }

    // Plugin walk. Each non-disabled, auto-update plugin marker
    // gets its upstream HEAD probed the same way root flake inputs
    // do. Failures here are isolated per-plugin so one bad URL
    // doesn't sink the whole run.
    try {
      final markers = _markersReader();
      for (final p in markers) {
        if (p.disabled) continue;
        if (!p.autoUpdate) continue;
        final li = lockedInputForPlugin(p);
        if (li == null) continue; // unsupported transport — skip silently
        try {
          final ahead = await _probePlugin(p, li);
          if (ahead != null) pluginsAhead.add(ahead);
        } catch (e, st) {
          LogService.error('UpdateCheckService: plugin ${p.id} threw', e, st);
          errors.add('plugin ${p.id}: $e');
        }
      }
    } catch (e, st) {
      LogService.error('UpdateCheckService: plugin walk failed', e, st);
      errors.add('plugin walk: $e');
    }

    return UpstreamProbeResult(
      inputsAhead: inputsAhead,
      pluginsAhead: pluginsAhead,
      errors: errors,
    );
  }

  /// Full check: probe upstream movement, evaluate the would-be
  /// system in a tmpdir, write the candidate `flake.lock` /
  /// plugin-pin data / nvd diff into staging, persist a
  /// [CheckResult] to `update-status.json`. Returns 0 on success
  /// (including the "needs local compile" bail), non-zero on a
  /// fatal infrastructure error.
  Future<int> runCheck() async {
    LogService.info('UpdateCheckService.runCheck: starting');
    final now = DateTime.now().toUtc();

    // Step 1: pure-network probe. Results merged into the final
    // CheckResult regardless of how the heavy step goes — a
    // network-only success is still useful signal for the
    // dashboard banner.
    final probe = await probeUpstreamMovement();

    Directory? tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('nixblitz-check-');
      final tmpFlake = '${tmp.path}/flake';
      Directory(tmpFlake).createSync();

      stdout.writeln('• copying flake to ${tmp.path}');
      final cp = await Process.run('cp', ['-aT', flakePath, tmpFlake]);
      if (cp.exitCode != 0) {
        return _persist(
          now,
          probe,
          ok: false,
          error: 'cp failed: ${cp.stderr}',
        );
      }

      // 1. flake update.
      //
      // `--accept-flake-config` is critical here AND in the build
      // steps below. nixos-raspberrypi's flake declares its
      // `extra-substituters = ["https://nixos-raspberrypi.cachix.org"]`
      // via `nixConfig`, and Nix only honours nixConfig from a
      // flake whose path has been "accepted" by the user. The
      // operator's `~/nixblitz` is accepted, but our tmpdir copy
      // is a different path so the acceptance doesn't apply there
      // — without this flag, dry-run runs WITHOUT the Pi cache as
      // a substituter and reports every page-size-16k
      // jemalloc-affected derivation as "will be built". On the
      // real `nixos-rebuild switch` those same paths fetch from
      // cache and only the operator's truly out-of-cache packages
      // compile.
      stdout.writeln('• nix flake update');
      final upd = await runBounded(
        'nix',
        ['--accept-flake-config', 'flake', 'update'],
        workingDirectory: tmpFlake,
        timeout: _flakeUpdateTimeout,
        label: 'nix flake update',
      );
      if (upd.exitCode != 0) {
        return _persist(
          now,
          probe,
          ok: false,
          error:
              'nix flake update failed (exit ${upd.exitCode}): '
              '${(upd.stderr as String).trim()}',
        );
      }

      // Stage candidate flake.lock if it actually moved relative
      // to the live one. Even when `nix flake update` rewrites the
      // file with no input changes, byte-equality is the right
      // gate — if the bytes match, nixos-rebuild would build the
      // same closure either way and there's nothing for Apply to
      // promote.
      final tmpLock = File('$tmpFlake/flake.lock');
      final liveLock = File('$flakePath/flake.lock');
      final lockBumped =
          tmpLock.existsSync() &&
          liveLock.existsSync() &&
          tmpLock.readAsStringSync() != liveLock.readAsStringSync();
      if (lockBumped) {
        _staging.writeLockBump(tmpLock);
      } else {
        _staging.clearLockBump();
      }

      // 2. dry-run probe.
      final platform = _readPlatform();
      final attrName = rebuildAttributeFor(platform);
      final attr =
          '$tmpFlake#nixosConfigurations.$attrName.config.system.build.toplevel';
      LogService.info(
        'UpdateCheckService.runCheck: platform=$platform attr=$attrName',
      );
      stdout.writeln('• nix build --dry-run (probing cache)');
      final dry = await runBounded(
        'nix',
        ['--accept-flake-config', 'build', '--dry-run', '--no-link', attr],
        workingDirectory: tmpFlake,
        timeout: _dryRunTimeout,
        label: 'nix build --dry-run',
      );
      if (dry.exitCode != 0) {
        return _persist(
          now,
          probe,
          ok: false,
          error:
              'nix build --dry-run failed: '
              '${(dry.stderr as String).trim()}',
        );
      }
      final plan = parseDryRunStderr(dry.stderr as String);
      if (plan.wouldBuild.isNotEmpty) {
        stdout.writeln(
          '! ${plan.wouldBuild.length} package(s) would need local compile:',
        );
        for (final name in plan.wouldBuild.take(20)) {
          stdout.writeln('    $name');
        }
        if (plan.wouldBuild.length > 20) {
          stdout.writeln('    … (${plan.wouldBuild.length - 20} more)');
        }
        stdout.writeln('  skipping nvd diff — Apply when ready to compile.');
        // Bail before realising the toplevel: on aarch64 with no
        // cache hits, rustc/llvm storms can pin all cores for
        // hours, which is exactly the spike the background check
        // should suppress. The TUI surfaces the would-build names
        // so the operator decides.
        return _persist(now, probe, ok: true, wouldBuild: plan.wouldBuild);
      }

      // 3. realise the toplevel (substitute-only when dry-run is empty).
      stdout.writeln(
        '• ${plan.wouldFetch.length} path(s) will be fetched from cache',
      );
      stdout.writeln('• nix build (substitute-only)');
      final eval = await runBounded(
        'nix',
        [
          '--accept-flake-config',
          'build',
          '--no-link',
          '--print-out-paths',
          attr,
        ],
        workingDirectory: tmpFlake,
        timeout: _buildTimeout,
        label: 'nix build (substitute)',
      );
      if (eval.exitCode != 0) {
        return _persist(
          now,
          probe,
          ok: false,
          error: 'nix build failed: ${(eval.stderr as String).trim()}',
        );
      }
      final newTop = (eval.stdout as String).trim();
      if (!newTop.startsWith('/nix/store/')) {
        return _persist(
          now,
          probe,
          ok: false,
          error: 'nix build did not return a store path: $newTop',
        );
      }

      // 4. compare to current.
      final readlink = await Process.run('readlink', [
        '-f',
        '/run/current-system',
      ]);
      final currentTop = (readlink.stdout as String).trim();
      if (currentTop == newTop) {
        return _persist(now, probe, ok: true, noChanges: true);
      }

      // 5. nvd diff.
      try {
        final nvd = await Process.run('nvd', [
          'diff',
          '/run/current-system',
          newTop,
        ]);
        final diff = (nvd.stdout as String) + (nvd.stderr as String);
        _staging.writeNvdDiff(diff);
        _staging.writeNewToplevel(newTop);
        _staging.writeCheckedAt(now);
        // Look-ahead: diff a candidate SBOM (the realized new toplevel) against
        // the committed one so the operator previews package-version changes.
        // Skipped (empty) when there's no committed baseline yet. Best-effort.
        var sbomChanges = const <SbomChange>[];
        final committedSbom = '$flakePath/sbom.cdx.json';
        if (File(committedSbom).existsSync()) {
          const sbom = SbomService();
          final candTmp =
              '${Directory.systemTemp.createTempSync('sbom-check').path}'
              '/cand.cdx.json';
          final genOk = await sbom.generate(closure: newTop, outPath: candTmp);
          if (genOk) {
            sbomChanges = sbom.diffComponents(
              sbom.readComponents(committedSbom),
              sbom.readComponents(candTmp),
            );
          }
        }
        return _persist(
          now,
          probe,
          ok: true,
          diffText: diff,
          sbomChanges: sbomChanges,
        );
      } on ProcessException catch (e) {
        return _persist(
          now,
          probe,
          ok: false,
          error: 'nvd not on PATH: ${e.message}',
        );
      }
    } catch (e, st) {
      LogService.error('UpdateCheckService.runCheck failed', e, st);
      return _persist(now, probe, ok: false, error: '$e');
    } finally {
      if (tmp != null) {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Reads the current status file (returns empty if missing/corrupt).
  /// Public so the TUI dashboard banner can call it directly.
  UpdateStatus readStatus() {
    final f = File(statusPath);
    if (!f.existsSync()) return UpdateStatus.empty();
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return UpdateStatus.fromJson(j);
    } catch (e, st) {
      LogService.error('UpdateCheckService.readStatus: parse failed', e, st);
      return UpdateStatus.empty();
    }
  }

  // ── Private helpers ────────────────────────────────────────────

  /// Persist a [CheckResult] to `update-status.json` and (when
  /// plugins have moved) write `staging/plugin-pins.json`. Combines
  /// the probe-stage data ([probe]) with the heavy-stage outcome.
  ///
  /// Returns 0 on `ok=true`, 1 otherwise — wired straight to the
  /// CLI exit code.
  int _persist(
    DateTime now,
    UpstreamProbeResult probe, {
    required bool ok,
    String? error,
    String diffText = '',
    bool noChanges = false,
    List<String> wouldBuild = const [],
    List<SbomChange> sbomChanges = const [],
  }) {
    final errors = [...probe.errors];
    if (error != null) errors.add(error);
    final result = CheckResult(
      checkedAt: now,
      ok: ok,
      error: errors.isEmpty ? null : errors.join('; '),
      inputsAhead: probe.inputsAhead,
      pluginsAhead: probe.pluginsAhead,
      diffText: diffText,
      noChanges: noChanges,
      wouldBuild: wouldBuild,
      sbomChanges: sbomChanges,
    );
    final f = File(statusPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(UpdateStatus(checkResult: result).toJson()),
    );
    if (probe.pluginsAhead.isNotEmpty) {
      _staging.writePluginPins(probe.pluginsAhead);
    } else {
      _staging.clearPluginPins();
    }
    LogService.info(
      'UpdateCheckService.runCheck: ok=$ok inputs=${probe.inputsAhead.length} '
      'plugins=${probe.pluginsAhead.length} wouldBuild=${wouldBuild.length} '
      'errors=${errors.length}',
    );
    return ok ? 0 : 1;
  }

  /// Per-plugin probe driving the version-tracking flow described in
  /// `docs/decisions/2026-05-14-plugin-version-tracking.md`. Returns
  /// a [PluginAhead] when the plugin has a pending update (semver
  /// upgrade, downgrade with the `isDowngrade` flag, or SHA-only
  /// fallback for unversioned plugins). Returns null when nothing's
  /// changed.
  ///
  /// Version-tracking semantics layer over the existing SHA path:
  ///
  /// - Both sides have a parseable `version` → compare semver, emit
  ///   PluginAhead with `upstreamVersion`+`currentVersion` and a new
  ///   pin candidate from the introducing-commit walk.
  /// - Either side missing version → fall back to SHA equality
  ///   (today's behavior).
  /// - Upstream version parses lower than ours → soft-refuse via
  ///   `isDowngrade=true`; row still emitted so the operator sees it.
  /// - Pinned rev no longer reachable on the upstream branch →
  ///   `forcePushDetected=true`. Auto-update proceeds; sign-key
  ///   verification (out of scope here) is the real security gate.
  Future<PluginAhead?> _probePlugin(PluginMarker marker, LockedInput li) async {
    final upstreamRev = await _prober.queryUpstreamRev(li);
    if (upstreamRev == null) {
      throw StateError('upstream not queryable');
    }

    // Try the version-tracking path first. When the upstream
    // manifest has a parseable `version`, version comparison is
    // authoritative; SHA equality becomes a tiebreaker. When it
    // doesn't, we drop straight to SHA tracking — same shape as
    // today.
    final subdir = subdirFor(marker.url);
    final upstreamManifest = await _prober.fetchManifestAt(
      li,
      subdir: subdir,
      ref: upstreamRev,
    );
    final upstreamVersion = upstreamManifest?.parsedVersion;
    final pinnedVersion = _parseMarkerVersion(marker);

    // Force-push check: does the SHA we pinned still exist on the
    // upstream branch? Skip when upstream SHA == pinned SHA — the
    // pinned commit IS the branch HEAD, no reason to probe.
    final forcePush =
        (upstreamRev != marker.rev) &&
        !(await _prober.isCommitReachable(li, marker.rev));
    if (forcePush) {
      LogService.warn(
        'plugin ${marker.id}: pinned rev ${marker.rev} is not reachable '
        'on ${li.urlForDisplay}; history was likely force-pushed. '
        'Continuing with the new upstream HEAD as the update candidate.',
      );
    }

    // SHA-tracking fallback when either side lacks a parseable version.
    if (upstreamVersion == null || pinnedVersion == null) {
      if (upstreamRev == marker.rev && !forcePush) return null;
      return PluginAhead(
        pluginId: marker.id,
        currentRev: marker.rev,
        upstreamRev: upstreamRev,
        url: marker.url,
        currentVersion: marker.version.isEmpty ? null : marker.version,
        upstreamVersion: upstreamManifest?.version,
        forcePushDetected: forcePush,
      );
    }

    // Both sides have parseable semver. Compare.
    if (upstreamVersion == pinnedVersion) {
      // Same version on both sides — nothing pending. If the SHA
      // moved on its own (commit on top without a version bump),
      // ignore it: that's the very situation the introducing-commit
      // pin is designed to suppress.
      return null;
    }
    if (upstreamVersion < pinnedVersion) {
      // Downgrade — emit a row, flagged amber. The operator opts
      // into rollback explicitly; we don't auto-apply.
      return PluginAhead(
        pluginId: marker.id,
        currentRev: marker.rev,
        upstreamRev: upstreamRev,
        url: marker.url,
        currentVersion: marker.version,
        upstreamVersion: upstreamManifest!.version,
        isDowngrade: true,
        forcePushDetected: forcePush,
      );
    }

    // Upstream is newer. Walk back to find the commit that
    // introduced that version — that's our new pin candidate.
    final introducing = await _prober.findIntroducingCommit(
      li,
      subdir: subdir,
      ref: upstreamRev,
      targetVersion: upstreamVersion,
    );
    return PluginAhead(
      pluginId: marker.id,
      currentRev: marker.rev,
      upstreamRev: introducing ?? upstreamRev,
      url: marker.url,
      currentVersion: marker.version,
      upstreamVersion: upstreamManifest!.version,
      forcePushDetected: forcePush,
    );
  }

  /// Parse the marker's stored version string. Empty string ⇒ the
  /// plugin was installed before the manifest had a `version` field
  /// (or had a malformed one); fall back to SHA tracking.
  static Version? _parseMarkerVersion(PluginMarker marker) {
    if (marker.version.isEmpty) return null;
    try {
      return Version.parse(marker.version);
    } on FormatException {
      return null;
    }
  }

  /// Re-check cached [InputAhead]s against the live `flake.lock` at
  /// [flakePath] and drop any input whose lock has moved since the
  /// cache was taken.
  ///
  /// The lightweight check writes a snapshot of `(locked, upstream)`
  /// pairs at run time. Between scheduled checks, the operator may
  /// run Update — advancing `flake.lock` — and the cached snapshot
  /// then over-reports pending updates ("updates available: nixblitz"
  /// even though the lock just moved and `nix flake update` is now a
  /// no-op).
  ///
  /// We compare the live lock against the cached `currentRev`, not
  /// `upstreamRev`: the lock may have advanced *past* the cached
  /// upstream (a newer commit was pushed between the lightweight
  /// check and this Update run, or the lock was bumped to a different
  /// branch). Either way, "lock moved" ⇒ snapshot is stale ⇒ drop the
  /// entry and let the next scheduled check refresh.
  ///
  /// Returns the original list unchanged when `flake.lock` is missing
  /// or unparseable; we'd rather trust the cache than silently hide a
  /// real update on the back of a transient read failure.
  static List<InputAhead> filterStillAhead(
    List<InputAhead> cached, {
    required String flakePath,
  }) {
    final lockFile = File('$flakePath/flake.lock');
    if (!lockFile.existsSync()) return cached;
    try {
      final lock =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
      final liveByName = <String, String>{
        for (final i in parseRootInputs(lock)) i.name: i.lockedRev,
      };
      return cached.where((e) {
        final liveRev = liveByName[e.name];
        // Input no longer in the lock (renamed / removed) — keep the
        // cached entry so the operator notices something's off.
        if (liveRev == null) return true;
        // Lock unchanged since the cache; entry is still ahead.
        // Any other live rev means the snapshot is stale.
        return liveRev == e.currentRev;
      }).toList();
    } catch (_) {
      return cached;
    }
  }

  void close() {
    _prober.close();
  }
}
