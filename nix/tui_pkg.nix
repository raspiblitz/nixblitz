{
  lib,
  buildDartApplication,
  nixFilter,
  version,
}:
buildDartApplication {
  pname = "nixblitz";
  inherit version;

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
    inherit version;
    mainProgram = "nixblitz";
  };
}
