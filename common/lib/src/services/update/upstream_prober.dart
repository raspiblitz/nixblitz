import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/update/update_check_types.dart';

/// Probes a plugin's upstream git host over HTTP: whether the tracked
/// branch has moved, whether a commit is reachable, and at which commit a
/// given manifest version was introduced. Owns the shared http client so
/// UpdateCheckService stays focused on orchestration + persistence.
class UpstreamProber {
  UpstreamProber({
    required http.Client httpClient,
    Duration timeout = const Duration(seconds: 15),
  }) : _http = httpClient,
       _httpTimeout = timeout;

  final http.Client _http;
  final Duration _httpTimeout;

  /// Fetch and parse the plugin's manifest at a specific ref.
  /// Returns null on 404 (subdir renamed / deleted) or any decode
  /// failure — the caller drops back to SHA-based tracking for that
  /// plugin without poisoning the rest of the walk.
  Future<PluginManifest?> fetchManifestAt(
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
  Future<String?> findIntroducingCommit(
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
      final m = await fetchManifestAt(entry, subdir: subdir, ref: sha);
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
  Future<bool> isCommitReachable(LockedInput entry, String sha) async {
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

  Future<String?> queryUpstreamRev(LockedInput entry) async {
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
      // Forgejo / Gitea API shape (third-party forges, e.g. Codeberg).
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

  /// Close the underlying http client.
  void close() => _http.close();
}
