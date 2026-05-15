/// Build-time metadata baked into the website via `--dart-define=…`.
/// The Nix build (`nix/website_pkg.nix`) passes the values; local
/// dev (`just web-serve`) does the same after a quick `git rev-parse`.
/// Mirrors `tui/lib/src/build_info.dart` so the header on the website
/// looks like the header in the TUI.
library;

/// Optional URL prefix for serving the site from a subpath
/// (`projects.domain.com/nixblitz`). Empty string means "serve at /".
///
/// Passed via `--dart-define=BASE_PATH=/nixblitz` at build time.
/// The Nix derivation accepts a `basePath` arg and propagates it;
/// `just web-serve` and `just web-build` accept a positional override.
///
/// Must NOT have a trailing slash — [href] concatenates `$kBasePath$path`
/// where `path` always starts with `/`. The Nix build strips a trailing
/// slash defensively.
const String kBasePath = String.fromEnvironment('BASE_PATH', defaultValue: '');

/// Prefix [path] with [kBasePath]. Pass internal absolute paths that
/// start with `/`. Returns `path` unchanged when no base path is set
/// (the default), so it's a no-op for the canonical root-served build.
///
/// Use everywhere `href` / `src` would normally take a hardcoded `/…`
/// string. External URLs and anchor-only fragments should NOT pass
/// through this helper — they don't depend on the base path.
String href(String path) {
  assert(path.startsWith('/'), 'href() expects a path starting with /');
  return '$kBasePath$path';
}

/// Inverse of [href]: strip [kBasePath] from a request URL to recover
/// the internal-route path. Used by route-active comparisons and the
/// breadcrumb logic, which match against internal patterns like
/// `'/docs/architecture'` and shouldn't care that the deployment
/// happens to be at `/nixblitz/docs/architecture`.
String internalPath(String url) {
  if (kBasePath.isEmpty) return url;
  if (url == kBasePath) return '/';
  if (url.startsWith('$kBasePath/')) return url.substring(kBasePath.length);
  return url;
}

/// Semantic version string, e.g. "0.1.0". Same flake-level `version`
/// the TUI consumes; pinned in `flake.nix`, not in `pubspec.yaml`.
const String buildVersion = String.fromEnvironment(
  'BUILD_VERSION',
  defaultValue: '0.1.0-dev',
);

/// Git short hash (or "abc1234-dirty") of the source tree at build time.
/// "local" means this build ran outside the Nix derivation AND outside
/// `just web-serve` — e.g. a plain `jaspr build` from a tarball with
/// no git context.
const String buildGitHash = String.fromEnvironment(
  'BUILD_GIT_HASH',
  defaultValue: 'local',
);

/// Combined display string for the header's right segment.
///
/// - Nix release build:  "v0.1.0-abc1234"
/// - Dirty worktree:     "v0.1.0-abc1234-dirty"
/// - Plain dev build:    "v0.1.0-dev"
String get buildVersionString {
  if (buildGitHash.isEmpty ||
      buildGitHash == 'local' ||
      buildVersion.endsWith('-dev')) {
    return 'v$buildVersion';
  }
  return 'v$buildVersion-$buildGitHash';
}
