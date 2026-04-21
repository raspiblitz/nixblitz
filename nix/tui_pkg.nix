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
    "bin/nixblitz" = "tui/bin/nixblitz.dart";
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

  meta = with lib; {
    description = "NixBlitz - Bitcoin/Lightning node manager TUI";
    license = licenses.mit;
    inherit version;
    mainProgram = "nixblitz";
  };
}
