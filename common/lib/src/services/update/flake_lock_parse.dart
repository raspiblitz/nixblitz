import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/update/update_check_types.dart';

// flake.lock -> LockedInput / FollowsInput parsing, plus the plugin-marker
// URL helpers. Pure functions extracted from UpdateCheckService.

/// Returns the subdir within the upstream repo where the plugin's
/// `plugin.json` lives, or null when the repo root is the plugin
/// root.
///
/// Mirrors the parsing in [lockedInputForPlugin] (which drops
/// subdir info because it only needs owner/repo for the branch-
/// HEAD probe). For the manifest-fetch path we need the inverse.
String? subdirFor(String url) {
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

/// Public for tests: pulls the inputs the user actually depends
/// on out of a parsed flake.lock JSON.
List<LockedInput> parseRootInputs(Map<String, dynamic> lock) {
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

/// Sibling to [parseRootInputs] for the *follows* entries — inputs
/// declared as `inputs.foo.follows = "bar/baz"` in `flake.nix`,
/// which appear in the lock as a list value under `root.inputs`
/// rather than a node-name string. They share another node's lock
/// (so there's no independent rev to probe), but operators expect
/// to see them in the inputs list — hiding them produces the
/// "where's nixpkgs?" puzzlement when nixpkgs follows
/// nixos-raspberrypi.
///
/// Returns one [FollowsInput] per such entry, with `target` joined
/// by `/` so `nixpkgs.follows = ["nixos-raspberrypi", "nixpkgs"]`
/// renders as `nixos-raspberrypi/nixpkgs` in the panel.
List<FollowsInput> parseRootFollows(Map<String, dynamic> lock) {
  final nodes = lock['nodes'] as Map<String, dynamic>?;
  if (nodes == null) return const [];
  final root = nodes['root'] as Map<String, dynamic>?;
  if (root == null) return const [];
  final rootInputs = (root['inputs'] as Map<String, dynamic>?) ?? const {};

  final out = <FollowsInput>[];
  for (final e in rootInputs.entries) {
    final v = e.value;
    if (v is! List) continue;
    final segs = v.whereType<String>().toList();
    if (segs.isEmpty) continue;
    out.add(FollowsInput(name: e.key, target: segs.join('/')));
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
LockedInput? lockedInputForPlugin(PluginMarker marker) {
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

_ParsedGitUrl? _parseGitUrl(String url) {
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
