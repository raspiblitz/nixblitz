{
  lib,
  buildDartApplication,
  nixFilter,
  # Pinned wasmtime c-api (nix/wasmtime.nix). Its libwasmtime.so path is
  # baked into the compiled binary as a compile-time define, which
  # WasmtimeLibrary.discover() reads as its default — so the WASM sandbox
  # runtime is found with no WASMTIME_DART_LIB env var. This matters
  # because the TUI's self-update re-execs the raw nixblitz-bin directly
  # (bypassing any wrapper env), and a systemd/nix-run launch may never
  # set the env either. (patchelf'ing an RPATH onto the binary does NOT
  # work: `dart compile exe` appends the AOT snapshot past the ELF, and
  # patchelf's rewrite corrupts it — the binary then just prints dartvm
  # usage. The compile-time define never touches the built binary.)
  wasmtimePinned,
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
    # Default path to the WASM sandbox runtime lib; read by
    # WasmtimeLibrary.discover() when $WASMTIME_DART_LIB is unset.
    "--define=WASMTIME_DART_LIB=${wasmtimePinned}/lib/libwasmtime.so"
  ];

  src = nixFilter {
    root = ./..;
    include = [
      "common"
      "tui"
      # common depends on wasmtime_dart (the WASM sandbox binding), so its
      # source must be in the build sandbox for the workspace to resolve.
      "wasmtime_dart"
      "templates"
      "scripts"
      "branches.json"
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
    # Same hash for both: pub fetches the whole `nocterm` repo at
    # the pinned ref and uses `path:` to locate `nocterm_riverpod`
    # within it, so the on-disk content (and FOD hash) is identical
    # for the two derivations. Bumping the nocterm `ref:` requires
    # bumping BOTH hashes — the workstation tends to mask this via
    # FOD substitution from its store cache, but a fresh build
    # (e.g. live ISO) trips the mismatch every time.
    nocterm = "sha256-t/eJb/OJPh/MNvBKPDZfG6kVFZkvOH7VydNlyc6aMvQ=";
    nocterm_riverpod = "sha256-t/eJb/OJPh/MNvBKPDZfG6kVFZkvOH7VydNlyc6aMvQ=";
  };

  workspaceMembers = ["common" "tui" "wasmtime_dart"];
  workspaceMember = "tui";
  workspaceDependencyGraph = lib.importJSON ./workspace_dependency_graph.json;

  # Slim the workspace pubspec so the dartConfigHook's
  # workspace-package-config.py only walks members whose source
  # is actually present. The repo's pubspec lists `website` too,
  # but website/ isn't in our src filter — without this slim the
  # hook crashes with `FileNotFoundError: 'website/pubspec.yaml'`.
  postPatch = ''
    cat > pubspec.yaml <<'EOF'
    name: nixblitz_workspace
    publish_to: none

    environment:
      sdk: ^3.11.4

    workspace:
      - common
      - tui
      - wasmtime_dart
    EOF
  '';

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
  #
  # Also installs shell completion scripts at the standard NixOS
  # auto-source paths. The scripts themselves are generic shell stubs
  # (committed at tui/completions/) that call `nixblitz completion`
  # at runtime; cli_completion handles the actual command-tree
  # completion in-process. Operators on NixOS get tab completion
  # without ever running `install-completion-files`.
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

    install -Dm644 tui/completions/nixblitz.bash \
      $out/share/bash-completion/completions/nixblitz
    install -Dm644 tui/completions/nixblitz.zsh \
      $out/share/zsh/site-functions/_nixblitz
    # nushell 0.99+ auto-sources files in NU_VENDOR_AUTOLOAD_DIRS,
    # which NixOS wires up via environment.pathsToLink. The
    # completer is hand-written (cli_completion only ships bash +
    # zsh upstream) but uses the same COMP_LINE + COMP_POINT
    # protocol — see scripts/gen_completion_scripts.dart.
    install -Dm644 tui/completions/nixblitz.nu \
      $out/share/nushell/vendor/autoload/nixblitz.nu
  '';

  meta = with lib; {
    description = "NixBlitz - Bitcoin/Lightning node manager TUI";
    license = licenses.mit;
    version = derivationVersion;
    mainProgram = "nixblitz";
  };
}
