{
  lib,
  buildDartApplication,
  nixFilter,
  tailwindcss_4,
  which,
  version,
  gitHash ? "local",
  derivationVersion ? version,
}:
buildDartApplication {
  pname = "nixblitz-website";
  version = derivationVersion;

  src = nixFilter {
    root = ./..;
    include = [
      "website"
      "pubspec.yaml"
      "pubspec.lock"
      "analysis_options.yaml"
    ];
  };

  sourceRoot = "source";

  pubspecLock = lib.importJSON ./workspace_pubspec.lock.json;

  # jaspr_cli pulled from forge.f44.fyi/f44/jaspr (cli_build_daemon_bypass
  # branch). Single-commit fork carrying the offline-build patch we
  # PRed upstream — see jaspr_cli's lib/src/dev/util.dart.
  gitHashes = {
    jaspr_cli = "sha256-lZ0Qo3u3D3dqHD/MBbzdhCXsOZKONyNTxEy5Skfdpoc=";
  };

  workspaceMembers = ["website"];
  workspaceMember = "website";
  workspaceDependencyGraph = lib.importJSON ./workspace_dependency_graph.json;
  workspaceIncludeDevDependencies = true;

  # `which` because jaspr_cli locates the Dart SDK via `which dart`
  # (see jaspr_cli's project.dart) and the Nix sandbox doesn't ship
  # it by default. tailwindcss_4 because jaspr_tailwind shells out
  # to `tailwindcss` during the build_runner pass.
  nativeBuildInputs = [tailwindcss_4 which];

  dartEntryPoints = {};

  # The vendored workspace pubspec.yaml lists common + tui + website
  # as workspace members. build_runner walks every member and demands
  # all their deps; since we only fetch website's deps, walking tui
  # would crash on missing git deps (nocterm, etc.). Slim the
  # workspace pubspec to website-only for the build.
  postPatch = ''
    cat > pubspec.yaml <<'EOF'
    name: nixblitz_workspace
    publish_to: none

    environment:
      sdk: ^3.11.4

    workspace:
      - website
    EOF
  '';

  # Skip the default `dart compile exe` flow. We run jaspr_cli via
  # `packageRun` (JIT) — sidesteps the webdev SDK-lookup bug that
  # bites the AOT-compiled jaspr_cli binary.
  #
  # The forked jaspr_cli (forge.f44.fyi/f44/jaspr) carries a single
  # patch — `startBuildDaemon` uses the low-level
  # `dart --packages=<package_config> <bin>` invocation instead of
  # `dart run build_runner daemon`. The high-level form revalidates
  # pubspec.lock against package_config and tries `pub get` on
  # mismatch — fatal offline. The fork is upstreamable; once the PR
  # lands at schultek/jaspr we can switch to the published version.
  buildPhase = ''
    runHook preBuild

    export HOME=$(mktemp -d)

    # Pub respects PUB_CACHE for transitive subprocesses; our
    # offline cache is exposed via the same var name in the shell.
    export PUB_CACHE="$pubcache"

    _wsPackageConfig="$(pwd)/.dart_tool/package_config.json"

    # Synthesize website/.dart_tool/package_config.json with the
    # workspace root removed (build_runner refuses two members
    # claiming the same rootUri) and relative rootUris rebased to
    # `../` so they resolve from website/.dart_tool/.
    mkdir -p website/.dart_tool
    jq '
      .packages |= [
        .[]
        | select(.name != "nixblitz_workspace")
        | if (.rootUri | test("^file://")) then . else .rootUri = ("../" + .rootUri) end
      ]
    ' "$_wsPackageConfig" > website/.dart_tool/package_config.json

    # build_runner expects pubspec.lock in the package directory.
    ln -sf ../pubspec.lock website/pubspec.lock

    cd website

    # Compile Tailwind from input.css → styles.css inside the
    # sandbox. The on-disk web/styles.css from a prior local
    # `just web-css` invocation (if any) is overwritten.
    tailwindcss -i web/input.css -o web/styles.css

    packageRun jaspr_cli -e jaspr build -O4

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r build/jaspr/. $out/

    # Drop the build_web_compilers debug bundle — useful only for
    # `jaspr serve`, not for shipping behind a static-file server.
    rm -rf $out/packages
    rm -f $out/.build.manifest

    runHook postInstall
  '';

  meta = with lib; {
    description = "NixBlitz static landing page, docs, and changelog (Jaspr-rendered)";
    license = licenses.mit;
    inherit version;
  };
}
