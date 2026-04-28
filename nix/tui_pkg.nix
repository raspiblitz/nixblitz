{
  lib,
  buildDartApplication,
  nixFilter,
  version,
  gitHash ? "local",
  # Version string used for the derivation's `pname-version`
  # name. Defaults to [version], but the flake passes
  # "${version}+${gitHash}" so nvd's package diff can detect
  # commit-to-commit nixblitz updates (it compares by package
  # name, not by store-path digest, so a constant `version`
  # makes every rebuild look like a no-op even when the binary
  # changed). Display strings still use plain [version].
  derivationVersion ? version,
}:
buildDartApplication {
  pname = "nixblitz";
  version = derivationVersion;

  # Bake version + git hash into the compiled binary via
  # `const String.fromEnvironment('…')`. See tui/lib/src/build_info.dart.
  # Note: BUILD_VERSION uses the short [version] so the TUI header
  # and `nixblitz --version` stay readable; the augmented
  # [derivationVersion] is only for nvd's benefit.
  dartCompileFlags = [
    "--define=BUILD_VERSION=${version}"
    "--define=BUILD_GIT_HASH=${gitHash}"
  ];

  src = nixFilter {
    root = ./..;
    include = [
      "common"
      "tui"
      "templates"
      "scripts"
      "pubspec.yaml"
      "analysis_options.yaml"
    ];
  };

  sourceRoot = "source";

  dartEntryPoints = {
    "bin/nixblitz-bin" = "tui/bin/nixblitz.dart";
  };

  pubspecLock = lib.importJSON ./workspace_pubspec.lock.json;

  gitHashes = {
    nocterm_riverpod = "sha256-wMHvhmFyu8Y3wf57MUACFmDELAxivFUIJXni3Bz9ssA=";
  };

  workspaceMembers = ["common" "tui"];
  workspaceMember = "tui";
  workspaceDependencyGraph = lib.importJSON ./workspace_dependency_graph.json;

  preBuild = ''
    mkdir -p bin
    # Regenerate embedded templates from source files
    dart run scripts/gen_embedded_templates.dart
  '';

  # Wrap the compiled binary with a tiny shell loop that restarts when the
  # inner process exits with code 42. The TUI returns 42 after a rebuild
  # puts a new nixblitz-bin on the "current system" symlink, letting us
  # pick up the freshly-installed binary without the user re-typing the
  # command. On non-NixOS (e.g. `nix run` on the live ISO) we fall back
  # to the sibling nixblitz-bin in the same /nix/store path.
  postInstall = ''
    cat > $out/bin/nixblitz <<'EOF'
    #!/usr/bin/env bash
    while true; do
      target=/run/current-system/sw/bin/nixblitz-bin
      if [ ! -x "$target" ]; then
        target="$(dirname "$(readlink -f "$0")")/nixblitz-bin"
      fi
      "$target" "$@"
      code=$?
      if [ $code -ne 42 ]; then
        exit $code
      fi
      echo
      echo "Restarting nixblitz with updated binary..."
    done
    EOF
    chmod +x $out/bin/nixblitz
  '';

  meta = with lib; {
    description = "NixBlitz - Bitcoin/Lightning node manager TUI";
    license = licenses.mit;
    version = derivationVersion;
    mainProgram = "nixblitz";
  };
}
