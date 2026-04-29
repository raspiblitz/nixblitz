import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:common/src/models/update_status.dart';
import 'package:common/src/services/log_service.dart';

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
  }) : _http = httpClient ?? http.Client();

  /// Directory holding `flake.nix` + `flake.lock` (the user's
  /// `~/nixblitz/`).
  final String flakePath;

  /// Where to merge the result into. See [updateStatusPath] for the
  /// production default.
  final String statusPath;

  final http.Client _http;

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

    _merge(
      LightCheck(
        checkedAt: now,
        ok: true,
        inputsAhead: ahead,
        error: errors.isEmpty ? null : errors.join('; '),
      ),
    );
    LogService.info(
      'UpdateCheckService.runLightweight: ${ahead.length} inputs ahead, '
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
      final upd = await Process.run('nix', [
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

      // 2. build new toplevel — realizes the derivation in the
      // store (mostly via binary-cache substitution) so nvd diff
      // can introspect it. `nix eval --raw` would only return a
      // hash-predicted path that doesn't exist on disk yet, and
      // nvd would fail with "Path does not exist".
      final eval = await Process.run('nix', [
        'build',
        '--no-link',
        '--print-out-paths',
        '$tmpFlake#nixosConfigurations.nixblitz.config.system.build.toplevel',
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

      // 3. compare to current.
      final readlink = await Process.run('readlink', [
        '-f',
        '/run/current-system',
      ]);
      final currentTop = (readlink.stdout as String).trim();
      if (currentTop == newTop) {
        _merge(HeavyCheck(checkedAt: now, ok: true, noChanges: true));
        return 0;
      }

      // 4. nvd diff.
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
