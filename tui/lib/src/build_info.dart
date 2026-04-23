/// Build-time metadata baked into the binary via `dart compile --define=…`.
/// See `nix/tui_pkg.nix`'s `dartCompileFlags`. Defaults are used when
/// running via `dart run` (local dev — no define flags).
library;

/// Semantic version string, e.g. "0.1.0".
const String buildVersion = String.fromEnvironment(
  'BUILD_VERSION',
  defaultValue: '0.1.0-dev',
);

/// Git short hash (or "abc1234-dirty") of the source tree at build time.
/// "local" means this binary was built outside Nix (e.g. `dart run`).
const String buildGitHash = String.fromEnvironment(
  'BUILD_GIT_HASH',
  defaultValue: 'local',
);

/// Combined display string for the app header and `--version`.
///
/// - Nix release build:  "v0.1.0-abc1234"
/// - Nix dirty worktree: "v0.1.0-abc1234-dirty"
/// - Local `dart run`:   "v0.1.0-dev"
String get buildVersionString {
  if (buildGitHash.isEmpty ||
      buildGitHash == 'local' ||
      buildVersion.endsWith('-dev')) {
    return 'v$buildVersion';
  }
  return 'v$buildVersion-$buildGitHash';
}
