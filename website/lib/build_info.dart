/// Build-time metadata baked into the website via `--dart-define=…`.
/// The Nix build (`nix/website_pkg.nix`) passes the values; local
/// dev (`just web-serve`) does the same after a quick `git rev-parse`.
/// Mirrors `tui/lib/src/build_info.dart` so the header on the website
/// looks like the header in the TUI.
library;

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
