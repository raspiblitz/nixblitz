import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/models/update_status.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/system_service.dart'
    show rebuildAttributeFor;

/// Periodic update-availability checker, invoked by systemd timers
/// via the `nixblitz check {light|heavy}` subcommands.
///
/// Two methods, two cadences:
///
/// - [runLightweight] — daily-ish. Parses `flake.lock`, calls
///   GitHub / Forgejo APIs to discover whether each input's
///   upstream branch HEAD has moved past our locked rev. No
///   tarball fetch, no eval. ~5 HTTP calls per run.
/// - [runHeavy] — weekly-ish. Copies `~/nixblitz/` into a tmpdir,
///   runs `nix flake update` + `nix eval` + `nvd diff` there,
///   captures the per-package version delta. Bandwidth: ~125 MB
///   per run for a typical input set.
///
/// Both methods write into the same `update-status.json` (preserving
/// the other section) so the TUI dashboard banner can read either
/// or both.
class UpdateCheckService {
  UpdateCheckService({
    required this.flakePath,
    required this.statusPath,
    http.Client? httpClient,
    List<PluginMarker> Function()? markersReader,
  }) : _http = httpClient ?? http.Client(),
       _markersReader =
           markersReader ?? (() => _defaultMarkersReader(flakePath));

  /// Directory holding `flake.nix` + `flake.lock` (the user's
  /// `~/nixblitz/`).
  final String flakePath;

  /// Where to merge the result into. See [updateStatusPath] for the
  /// production default.
  final String statusPath;

  final http.Client _http;

  /// Loads the set of installed plugin markers. Injected by tests
  /// so the plugin walk can run without seeded marker fixtures on
  /// disk. Production default reads `<flakePath>/plugins/` via
  /// [discoverInstalledMarkers].
  final List<PluginMarker> Function() _markersReader;

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

  /// HTTP timeout for upstream-HEAD calls. Stops a misbehaving forge
  /// from holding the timer indefinitely.
  static const Duration _httpTimeout = Duration(seconds: 15);

  // ── Public entry points ────────────────────────────────────────

  Future<int> runLightweight() async {
    LogService.info('UpdateCheckService.runLightweight: starting');
    final now = DateTime.now().toUtc();

    final lockFile = File('$flakePath/flake.lock');
    if (!lockFile.existsSync()) {
      _merge(
        LightCheck(
          checkedAt: now,
          ok: false,
          error: 'flake.lock not found at $flakePath',
        ),
      );
      return 1;
    }

    final List<InputAhead> ahead = [];
    final List<String> errors = [];
    try {
      final lock =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
      final inputs = parseRootInputs(lock);
      for (final entry in inputs) {
        try {
          final upstream = await _queryUpstreamRev(entry);
          if (upstream == null) {
            errors.add('${entry.name}: upstream not queryable');
            continue;
          }
          if (upstream != entry.lockedRev) {
            ahead.add(
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
      LogService.error('UpdateCheckService.runLightweight failed', e, st);
      _merge(
        LightCheck(
          checkedAt: now,
          ok: false,
          error: 'flake.lock parse failed: $e',
        ),
      );
      return 1;
    }

    // Plugin walk. Each non-disabled, auto-update plugin marker
    // gets its upstream HEAD probed the same way root flake inputs
    // do. Failures here are isolated per-plugin so one bad URL
    // doesn't sink the whole run, and marker-load failure just
    // means "no plugin entries surfaced this run" — the inputs
    // result still ships.
    final List<PluginAhead> pluginsAhead = [];
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

    _merge(
      LightCheck(
        checkedAt: now,
        ok: true,
        inputsAhead: ahead,
        pluginsAhead: pluginsAhead,
        error: errors.isEmpty ? null : errors.join('; '),
      ),
    );
    LogService.info(
      'UpdateCheckService.runLightweight: ${ahead.length} inputs ahead, '
      '${pluginsAhead.length} plugins ahead, '
      '${errors.length} errors',
    );
    return 0;
  }

  Future<int> runHeavy() async {
    LogService.info('UpdateCheckService.runHeavy: starting');
    final now = DateTime.now().toUtc();
    Directory? tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('nixblitz-check-heavy-');
      final tmpFlake = '${tmp.path}/flake';
      Directory(tmpFlake).createSync();

      // Copy just enough for an eval: flake.{nix,lock}, hosts/,
      // modules/, plugins/, hardware-configuration.nix, config.json.
      stdout.writeln('• copying flake to ${tmp.path}');
      final cp = await Process.run('cp', ['-aT', flakePath, tmpFlake]);
      if (cp.exitCode != 0) {
        _merge(
          HeavyCheck(
            checkedAt: now,
            ok: false,
            error: 'cp failed: ${cp.stderr}',
          ),
        );
        return 1;
      }

      // 1. flake update.
      //
      // `--accept-flake-config` is critical here AND in the build
      // steps below. nixos-raspberrypi's flake declares its
      // `extra-substituters = ["https://nixos-raspberrypi.cachix.org"]`
      // via `nixConfig`, and Nix only honours nixConfig from a
      // flake whose path has been "accepted" by the user. The
      // operator's `~/nixblitz` is accepted (typically via the
      // first `nixos-rebuild switch` they ran), but our tmpdir
      // copy is a different path so the acceptance doesn't apply
      // there — without this flag, dry-run runs WITHOUT the Pi
      // cache as a substituter and reports every page-size-16k
      // jemalloc-affected derivation as "will be built". On the
      // real `nixos-rebuild switch` those same paths fetch from
      // cache and only the operator's truly out-of-cache packages
      // compile. We hit this with a 108-vs-1 discrepancy that
      // took a while to track down.
      stdout.writeln('• nix flake update');
      final upd = await Process.run('nix', [
        '--accept-flake-config',
        'flake',
        'update',
      ], workingDirectory: tmpFlake);
      if (upd.exitCode != 0) {
        _merge(
          HeavyCheck(
            checkedAt: now,
            ok: false,
            error:
                'nix flake update failed (exit ${upd.exitCode}): '
                '${(upd.stderr as String).trim()}',
          ),
        );
        return 1;
      }

      // 2. dry-run probe — ask Nix what *would* happen if we built
      // the new toplevel: which paths come from cache (free) vs.
      // which need to be compiled locally (expensive). `nvd diff`
      // needs realised paths, so we can't *just* dry-run when the
      // operator wants a per-package version delta; but if anything
      // would need a local build, we bail before the CPU storm
      // (rustc, llvm, etc. on aarch64 with no cache hits can pin
      // all cores for hours — see the heavy-check bail in #N/A).
      // The operator sees the would-build list, decides whether to
      // wait, then triggers the actual build via System → Apply.
      // Per-platform attribute. On the Pi, `nixblitz` evaluates to
      // the x86_64-linux toplevel — which an aarch64 daemon can't
      // substitute or build, so every derivation in its closure
      // surfaces as "will be built" (we hit a 108-vs-1 discrepancy
      // against the real `nixos-rebuild switch`, which uses the
      // correct per-platform attr). Read the operator's
      // `config.json` to pick the matching attribute the way
      // `apply_view._continueApply` does.
      final platform = _readPlatform();
      final attrName = rebuildAttributeFor(platform);
      final attr =
          '$tmpFlake#nixosConfigurations.$attrName.config.system.build.toplevel';
      LogService.info(
        'UpdateCheckService.runHeavy: platform=$platform attr=$attrName',
      );
      stdout.writeln('• nix build --dry-run (probing cache)');
      final dry = await Process.run('nix', [
        '--accept-flake-config',
        'build',
        '--dry-run',
        '--no-link',
        attr,
      ], workingDirectory: tmpFlake);
      if (dry.exitCode != 0) {
        _merge(
          HeavyCheck(
            checkedAt: now,
            ok: false,
            error:
                'nix build --dry-run failed: '
                '${(dry.stderr as String).trim()}',
          ),
        );
        return 1;
      }
      final plan = parseDryRunStderr(dry.stderr as String);
      if (plan.wouldBuild.isNotEmpty) {
        stdout.writeln(
          '! ${plan.wouldBuild.length} package(s) would need local compile:',
        );
        // Cap the printed list so a runaway dependency tree doesn't
        // flood the runningCheck pane; the full list lives on
        // HeavyCheck.wouldBuild and the TUI's Status panel surfaces
        // the count.
        for (final name in plan.wouldBuild.take(20)) {
          stdout.writeln('    $name');
        }
        if (plan.wouldBuild.length > 20) {
          stdout.writeln('    … (${plan.wouldBuild.length - 20} more)');
        }
        stdout.writeln('  skipping nvd diff — Apply when ready to compile.');
        // Cache miss — local build needed. Don't realise the
        // toplevel just to render a diff; doing so on aarch64 can
        // take hours and that's exactly the spike we're trying to
        // suppress in the background check. The TUI will surface
        // the would-build names so the operator can decide.
        _merge(
          HeavyCheck(checkedAt: now, ok: true, wouldBuild: plan.wouldBuild),
        );
        return 0;
      }

      // 3. realise the toplevel. We only get here when dry-run says
      // every path is substitutable, so this is bounded by network
      // throughput, not CPU. `nix eval --raw` would skip the
      // download entirely but then nvd can't introspect the store
      // path; the realise step is the cost of a useful diff.
      stdout.writeln(
        '• ${plan.wouldFetch.length} path(s) will be fetched from cache',
      );
      stdout.writeln('• nix build (substitute-only)');
      final eval = await Process.run('nix', [
        '--accept-flake-config',
        'build',
        '--no-link',
        '--print-out-paths',
        attr,
      ], workingDirectory: tmpFlake);
      if (eval.exitCode != 0) {
        _merge(
          HeavyCheck(
            checkedAt: now,
            ok: false,
            error: 'nix build failed: ${(eval.stderr as String).trim()}',
          ),
        );
        return 1;
      }
      final newTop = (eval.stdout as String).trim();
      if (!newTop.startsWith('/nix/store/')) {
        _merge(
          HeavyCheck(
            checkedAt: now,
            ok: false,
            error: 'nix build did not return a store path: $newTop',
          ),
        );
        return 1;
      }

      // 4. compare to current.
      final readlink = await Process.run('readlink', [
        '-f',
        '/run/current-system',
      ]);
      final currentTop = (readlink.stdout as String).trim();
      if (currentTop == newTop) {
        _merge(HeavyCheck(checkedAt: now, ok: true, noChanges: true));
        return 0;
      }

      // 5. nvd diff.
      try {
        final nvd = await Process.run('nvd', [
          'diff',
          '/run/current-system',
          newTop,
        ]);
        final diff = (nvd.stdout as String) + (nvd.stderr as String);
        _merge(HeavyCheck(checkedAt: now, ok: true, diffText: diff));
        return 0;
      } on ProcessException catch (e) {
        _merge(
          HeavyCheck(
            checkedAt: now,
            ok: false,
            error: 'nvd not on PATH: ${e.message}',
          ),
        );
        return 1;
      }
    } catch (e, st) {
      LogService.error('UpdateCheckService.runHeavy failed', e, st);
      _merge(HeavyCheck(checkedAt: now, ok: false, error: '$e'));
      return 1;
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

  void _merge(Object section) {
    final existing = readStatus();
    final next = section is LightCheck
        ? existing.copyWith(lightweight: section)
        : existing.copyWith(heavy: section as HeavyCheck);
    final f = File(statusPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(next.toJson()),
    );
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
    final upstreamRev = await _queryUpstreamRev(li);
    if (upstreamRev == null) {
      throw StateError('upstream not queryable');
    }

    // Try the version-tracking path first. When the upstream
    // manifest has a parseable `version`, version comparison is
    // authoritative; SHA equality becomes a tiebreaker. When it
    // doesn't, we drop straight to SHA tracking — same shape as
    // today.
    final subdir = _subdirFor(marker.url);
    final upstreamManifest = await _fetchManifestAt(
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
        !(await _isCommitReachable(li, marker.rev));
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
    final introducing = await _findIntroducingCommit(
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

  /// Returns the subdir within the upstream repo where the plugin's
  /// `plugin.json` lives, or null when the repo root is the plugin
  /// root.
  ///
  /// Mirrors the parsing in [lockedInputForPlugin] (which drops
  /// subdir info because it only needs owner/repo for the branch-
  /// HEAD probe). For the manifest-fetch path we need the inverse.
  static String? _subdirFor(String url) {
    if (url.startsWith('github:')) {
      // github:owner/repo[/subdir1/subdir2][?dir=…]. Either form is
      // accepted; the `?dir=` form wins when both are present.
      final body = url.substring('github:'.length);
      final qIdx = body.indexOf('?dir=');
      if (qIdx >= 0) return body.substring(qIdx + '?dir='.length);
      final parts = body.split('/');
      if (parts.length <= 2) return null;
      return parts.sublist(2).join('/');
    }
    if (url.startsWith('forgejo:') || url.startsWith('gitea:')) {
      final scheme = url.startsWith('forgejo:') ? 'forgejo:' : 'gitea:';
      final body = url.substring(scheme.length);
      final qIdx = body.indexOf('?dir=');
      if (qIdx >= 0) return body.substring(qIdx + '?dir='.length);
      // host/owner/repo[/subdir1/subdir2]
      final parts = body.split('/');
      if (parts.length <= 3) return null;
      return parts.sublist(3).join('/');
    }
    if (url.startsWith('git+')) {
      final qIdx = url.indexOf('?dir=');
      if (qIdx >= 0) return url.substring(qIdx + '?dir='.length);
    }
    return null;
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

  /// Fetch and parse the plugin's manifest at a specific ref.
  /// Returns null on 404 (subdir renamed / deleted) or any decode
  /// failure — the caller drops back to SHA-based tracking for that
  /// plugin without poisoning the rest of the walk.
  Future<PluginManifest?> _fetchManifestAt(
    LockedInput entry, {
    String? subdir,
    required String ref,
  }) async {
    final path = subdir == null || subdir.isEmpty
        ? 'plugin.json'
        : '$subdir/plugin.json';
    final content = await _fetchFileAt(entry, path: path, ref: ref);
    if (content == null) return null;
    try {
      return PluginManifest.fromJsonString(content);
    } catch (e) {
      LogService.warn(
        'plugin ${entry.name}: failed to parse manifest at $ref: $e',
      );
      return null;
    }
  }

  /// Raw file fetch at a ref; returns the decoded text content or
  /// null if the file isn't there (404) / decode fails. Both
  /// GitHub's and Forgejo/Gitea's `contents` endpoints return a JSON
  /// object with a base64-encoded `content` field and the same
  /// shape — collapse on that.
  Future<String?> _fetchFileAt(
    LockedInput entry, {
    required String path,
    required String ref,
  }) async {
    Uri uri;
    if (entry.type == 'github') {
      uri = Uri.parse(
        'https://api.github.com/repos/${entry.owner}/${entry.repo}'
        '/contents/${Uri.encodeComponent(path)}?ref=$ref',
      );
    } else if (entry.type == 'git' && entry.host != null) {
      uri = Uri.parse(
        'https://${entry.host}/api/v1/repos/${entry.owner}/${entry.repo}'
        '/contents/${Uri.encodeComponent(path)}?ref=$ref',
      );
    } else {
      return null;
    }

    final resp = await _http.get(uri).timeout(_httpTimeout);
    if (resp.statusCode != 200) {
      // 404 = subdir renamed / deleted / plugin file missing.
      // 4xx / 5xx = transient API error or rate-limit.
      // Either way we lose version-tracking for this plugin, but
      // the SHA-only fallback in `_probePlugin` still works. Log
      // and return null so the caller treats this plugin as
      // unversioned for this round.
      if (resp.statusCode != 404) {
        LogService.warn(
          '${entry.name}: contents API ${resp.statusCode} for $path@$ref',
        );
      }
      return null;
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final encoded = j['content'] as String?;
    if (encoded == null) return null;
    // GitHub wraps base64 content with newlines every 60 chars;
    // strip whitespace before decoding to be safe across providers.
    try {
      final bytes = base64.decode(encoded.replaceAll(RegExp(r'\s+'), ''));
      return utf8.decode(bytes);
    } on FormatException catch (e) {
      LogService.warn(
        '${entry.name}: contents response not valid base64: ${e.message}',
      );
      return null;
    }
  }

  /// Walk the upstream commit history backward from [ref] on commits
  /// affecting `<subdir>/plugin.json`, looking for the most ancient
  /// commit that still reports [targetVersion]. That's the
  /// "introducing commit" for the version — pinning there means
  /// subsequent post-version commits don't sneak into our trust
  /// model under the same label.
  ///
  /// Cost: O(N) HTTP calls where N is the number of commits touching
  /// `<subdir>/plugin.json` since the version bump. Typically 1-2;
  /// capped at [maxCommits] (50 default) to bound pathological cases.
  /// Returns null when the walk fails to identify a single
  /// introducing commit; caller falls back to the branch HEAD SHA.
  Future<String?> _findIntroducingCommit(
    LockedInput entry, {
    String? subdir,
    required String ref,
    required Version targetVersion,
    int maxCommits = 50,
  }) async {
    final path = subdir == null || subdir.isEmpty
        ? 'plugin.json'
        : '$subdir/plugin.json';
    final commits = await _listCommitsAffectingPath(
      entry,
      path: path,
      ref: ref,
      limit: maxCommits,
    );
    if (commits.isEmpty) return null;

    String? candidate;
    for (final sha in commits) {
      // Newest first. The introducing commit is the OLDEST commit
      // that still shows targetVersion (i.e., the first one walking
      // backward where the version differs becomes the boundary,
      // and the previous candidate is the introducing commit).
      final m = await _fetchManifestAt(entry, subdir: subdir, ref: sha);
      if (m?.parsedVersion == targetVersion) {
        candidate = sha;
        continue;
      }
      // Hit a commit with a different version — stop. The candidate
      // we have is the introducing commit.
      return candidate;
    }
    // Walked the whole window without seeing a version change. Either
    // the version has been stable for the full window (return our
    // last-seen candidate) or we ran past the cap. Return whatever
    // we held; if commits exhausted, candidate is the oldest fetched.
    return candidate;
  }

  Future<List<String>> _listCommitsAffectingPath(
    LockedInput entry, {
    required String path,
    required String ref,
    int limit = 50,
  }) async {
    Uri uri;
    if (entry.type == 'github') {
      uri = Uri.parse(
        'https://api.github.com/repos/${entry.owner}/${entry.repo}/commits'
        '?path=${Uri.encodeQueryComponent(path)}'
        '&sha=$ref&per_page=$limit',
      );
    } else if (entry.type == 'git' && entry.host != null) {
      uri = Uri.parse(
        'https://${entry.host}/api/v1/repos/${entry.owner}/${entry.repo}/commits'
        '?path=${Uri.encodeQueryComponent(path)}'
        '&sha=$ref&limit=$limit',
      );
    } else {
      return const [];
    }
    final resp = await _http.get(uri).timeout(_httpTimeout);
    if (resp.statusCode != 200) {
      throw StateError('commits API ${resp.statusCode}: ${resp.body}');
    }
    final list = jsonDecode(resp.body);
    if (list is! List) return const [];
    return [
      for (final c in list)
        if (c is Map<String, dynamic>) c['sha'] as String,
    ];
  }

  /// Cheap probe: does [sha] exist on [entry]'s branch? GitHub and
  /// Forgejo both expose `/commits/{sha}` returning 200 when the
  /// commit is reachable. Returns false ONLY on a definitive 404 /
  /// 422 from the provider — anything else (5xx, network, parse) is
  /// "we don't know," which we treat as reachable to avoid
  /// false-positive force-push banners.
  Future<bool> _isCommitReachable(LockedInput entry, String sha) async {
    Uri uri;
    if (entry.type == 'github') {
      uri = Uri.parse(
        'https://api.github.com/repos/${entry.owner}/${entry.repo}'
        '/commits/$sha',
      );
    } else if (entry.type == 'git' && entry.host != null) {
      uri = Uri.parse(
        'https://${entry.host}/api/v1/repos/${entry.owner}/${entry.repo}'
        '/git/commits/$sha',
      );
    } else {
      return true; // unsupported transport — don't flag
    }
    try {
      final resp = await _http.get(uri).timeout(_httpTimeout);
      // GitHub returns 422 on malformed SHA strings; Forgejo returns
      // 404. Both unambiguously mean "not on this branch."
      if (resp.statusCode == 404 || resp.statusCode == 422) return false;
      return true; // 200 ⇒ reachable; 5xx / other ⇒ unknown, assume reachable
    } catch (_) {
      return true; // transient network error — don't false-flag
    }
  }

  Future<String?> _queryUpstreamRev(LockedInput entry) async {
    if (entry.type == 'github') {
      final ref = entry.ref;
      final api = ref == null
          ? 'https://api.github.com/repos/${entry.owner}/${entry.repo}/commits?per_page=1'
          : 'https://api.github.com/repos/${entry.owner}/${entry.repo}/commits/$ref';
      final resp = await _http.get(Uri.parse(api)).timeout(_httpTimeout);
      if (resp.statusCode != 200) {
        throw StateError('GitHub API ${resp.statusCode}: ${resp.body}');
      }
      final j = jsonDecode(resp.body);
      if (j is List && j.isNotEmpty) return j.first['sha'] as String?;
      if (j is Map<String, dynamic>) return j['sha'] as String?;
      return null;
    }
    if (entry.type == 'git' && entry.host != null) {
      // Forgejo / Gitea API shape (forge.f44.fyi runs Forgejo).
      final ref = entry.ref ?? 'main';
      final api =
          'https://${entry.host}/api/v1/repos/${entry.owner}/${entry.repo}'
          '/branches/$ref';
      final resp = await _http.get(Uri.parse(api)).timeout(_httpTimeout);
      if (resp.statusCode != 200) {
        throw StateError('Forgejo API ${resp.statusCode}: ${resp.body}');
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return ((j['commit'] as Map?)?['id']) as String?;
    }
    return null; // unsupported transport
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

  /// Public for tests: pulls the inputs the user actually depends
  /// on out of a parsed flake.lock JSON.
  static List<LockedInput> parseRootInputs(Map<String, dynamic> lock) {
    final nodes = lock['nodes'] as Map<String, dynamic>?;
    if (nodes == null) return const [];
    final root = nodes['root'] as Map<String, dynamic>?;
    if (root == null) return const [];
    final rootInputs = (root['inputs'] as Map<String, dynamic>?) ?? const {};

    final out = <LockedInput>[];
    for (final e in rootInputs.entries) {
      // Each value is either a node-name string or a follows array.
      // `follows` inputs share another node's lock; skip them since
      // querying that other node covers the same upstream.
      if (e.value is! String) continue;
      final nodeName = e.value as String;
      final node = nodes[nodeName] as Map<String, dynamic>?;
      if (node == null) continue;
      final locked = node['locked'] as Map<String, dynamic>?;
      final original = node['original'] as Map<String, dynamic>?;
      if (locked == null) continue;

      final type = locked['type'] as String?;
      final rev = locked['rev'] as String?;
      if (rev == null) continue;

      String? owner;
      String? repo;
      String? host;
      String? urlField;

      if (type == 'github') {
        owner = locked['owner'] as String?;
        repo = locked['repo'] as String?;
      } else if (type == 'git') {
        urlField = locked['url'] as String?;
        if (urlField == null) continue;
        final parsed = _parseGitUrl(urlField);
        host = parsed?.host;
        owner = parsed?.owner;
        repo = parsed?.repo;
      } else {
        continue; // path:, tarball:, indirect:, … — skip
      }

      if (owner == null || repo == null) continue;

      out.add(
        LockedInput(
          name: e.key,
          type: type!,
          owner: owner,
          repo: repo,
          host: host,
          ref: original?['ref'] as String?,
          lockedRev: rev,
          urlForDisplay: urlField ?? 'github:$owner/$repo',
        ),
      );
    }
    return out;
  }

  /// Translates a plugin marker's url/branch/rev into the same
  /// shape [_queryUpstreamRev] expects. Returns `null` when the plugin
  /// uses a transport we can't probe (file://, https:// without a
  /// recognised forge host, etc.) — caller skips those silently.
  ///
  /// Supported schemes: `github:owner/repo`, `forgejo:host/owner/repo`,
  /// `gitea:host/owner/repo`. The `https://` scheme is *not* supported
  /// here because the plain URL doesn't tell us which forge API to
  /// call; if a plugin uses https://forge.example/owner/repo and we
  /// want to probe it, the operator should switch the URL to the
  /// `forgejo:` form first.
  static LockedInput? lockedInputForPlugin(PluginMarker marker) {
    final raw = marker.url;
    final ref = marker.branch;
    final lockedRev = marker.rev;

    if (raw.startsWith('github:')) {
      final body = raw.substring('github:'.length);
      // Strip ?dir=... canonical-subdir suffix if present.
      final qIdx = body.indexOf('?dir=');
      final core = qIdx >= 0 ? body.substring(0, qIdx) : body;
      final parts = core.split('/');
      if (parts.length < 2) return null;
      final owner = parts[0];
      final repo = parts[1];
      if (owner.isEmpty || repo.isEmpty) return null;
      return LockedInput(
        name: marker.id,
        type: 'github',
        owner: owner,
        repo: repo,
        host: null,
        ref: ref,
        lockedRev: lockedRev,
        urlForDisplay: raw,
      );
    }

    if (raw.startsWith('forgejo:') || raw.startsWith('gitea:')) {
      final scheme = raw.startsWith('forgejo:') ? 'forgejo:' : 'gitea:';
      final body = raw.substring(scheme.length);
      final qIdx = body.indexOf('?dir=');
      final core = qIdx >= 0 ? body.substring(0, qIdx) : body;
      final parts = core.split('/');
      if (parts.length < 3) return null;
      final host = parts[0];
      final owner = parts[1];
      final repo = parts[2];
      if (host.isEmpty || owner.isEmpty || repo.isEmpty) return null;
      return LockedInput(
        name: marker.id,
        type: 'git',
        owner: owner,
        repo: repo,
        host: host,
        ref: ref,
        lockedRev: lockedRev,
        urlForDisplay: raw,
      );
    }

    return null;
  }

  static _ParsedGitUrl? _parseGitUrl(String url) {
    // Strip `git+` prefix.
    var clean = url;
    if (clean.startsWith('git+')) clean = clean.substring(4);
    // Strip query (`?dir=...`, `?ref=...`).
    final q = clean.indexOf('?');
    if (q >= 0) clean = clean.substring(0, q);
    final uri = Uri.tryParse(clean);
    if (uri == null) return null;
    if (uri.host.isEmpty) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    var repo = segments[1];
    if (repo.endsWith('.git')) {
      repo = repo.substring(0, repo.length - 4);
    }
    return _ParsedGitUrl(host: uri.host, owner: segments[0], repo: repo);
  }

  void close() {
    _http.close();
  }
}

/// Result of parsing `nix build --dry-run` stderr. Both lists hold
/// short derivation names ("the readable part" of
/// `/nix/store/HASH-NAME.drv` — e.g. `rustc-1.87.0`) so the UI can
/// show a compact summary without dragging store hashes around.
/// Lists are alphabetically sorted for stability.
class NixBuildPlan {
  const NixBuildPlan({required this.wouldBuild, required this.wouldFetch});

  /// Paths that would be compiled locally (cache miss / non-
  /// substitutable). Non-empty list = "huge update incoming."
  final List<String> wouldBuild;

  /// Paths that would be downloaded from a binary cache. Surfaced
  /// for completeness; not currently used by the TUI gating logic.
  final List<String> wouldFetch;
}

/// Parse the stderr output of `nix build --dry-run` into a
/// [NixBuildPlan]. Nix prints two stanzas when there's work to do:
///
/// ```
/// these 3 derivations will be built:
///   /nix/store/abc-rustc-1.87.0.drv
///   ...
/// these 12 paths will be fetched (456 MB):
///   /nix/store/xyz-foo.drv
///   ...
/// ```
///
/// Either stanza may be absent (or both — `noChanges`). Parsing is
/// lenient: unknown lines are ignored, and we only key off the
/// leading whitespace + `/nix/store/` marker for the path lines.
/// Singular `derivation` / `path` variants are accepted.
NixBuildPlan parseDryRunStderr(String stderr) {
  final lines = const LineSplitter().convert(stderr);
  final built = <String>[];
  final fetched = <String>[];
  // 0 = looking for a header; 1 = inside builds; 2 = inside fetches.
  var section = 0;
  for (final raw in lines) {
    final line = raw.trimRight();
    final t = line.trimLeft();
    // Stanza headers — match both "this/these N derivation(s) will
    // be built:" and the fetch counterpart.
    final builtRe = RegExp(
      r'^(?:this|these).*derivations? will be built:',
      caseSensitive: false,
    );
    final fetchRe = RegExp(
      r'^(?:this|these).*paths? will be fetched',
      caseSensitive: false,
    );
    if (builtRe.hasMatch(t)) {
      section = 1;
      continue;
    }
    if (fetchRe.hasMatch(t)) {
      section = 2;
      continue;
    }
    // Path lines: indented + start with /nix/store/. A blank line
    // or any other unindented line ends the current section.
    if (section != 0 && t.startsWith('/nix/store/')) {
      final name = _derivationShortName(t);
      if (section == 1) {
        built.add(name);
      } else {
        fetched.add(name);
      }
    } else if (line.isEmpty || !line.startsWith(' ')) {
      section = 0;
    }
  }
  built.sort();
  fetched.sort();
  return NixBuildPlan(wouldBuild: built, wouldFetch: fetched);
}

/// Strip `/nix/store/<hash>-` prefix and the trailing `.drv` from a
/// store path so the UI shows `rustc-1.87.0` instead of
/// `/nix/store/abc123…-rustc-1.87.0.drv`. Returns the input
/// unchanged when the shape doesn't match — defensive against
/// hypothetical future Nix output changes.
String _derivationShortName(String storePath) {
  final m = RegExp(r'^/nix/store/[^-]+-(.+)$').firstMatch(storePath);
  if (m == null) return storePath;
  var name = m.group(1)!;
  if (name.endsWith('.drv')) {
    name = name.substring(0, name.length - 4);
  }
  return name;
}

/// Record of a flake input we know how to query upstream against.
/// Returned by [UpdateCheckService.parseRootInputs].
class LockedInput {
  const LockedInput({
    required this.name,
    required this.type,
    required this.owner,
    required this.repo,
    required this.host,
    required this.ref,
    required this.lockedRev,
    required this.urlForDisplay,
  });

  final String name;
  final String type; // 'github' | 'git'
  final String owner;
  final String repo;
  final String? host; // populated for 'git' type
  final String? ref;
  final String lockedRev;
  final String urlForDisplay;
}

class _ParsedGitUrl {
  const _ParsedGitUrl({
    required this.host,
    required this.owner,
    required this.repo,
  });
  final String host;
  final String owner;
  final String repo;
}
