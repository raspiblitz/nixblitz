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
    // a stored marker.url (e.g. during `plugin update`), split
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
