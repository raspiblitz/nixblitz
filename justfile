set shell := ["nu", "-c"]

set positional-arguments

# Lists available commands
default:
	just --list

# Run all Dart tests (common + tui + wasmtime_dart) + the plugin-consistency invariant
test trace="":
  #!/usr/bin/env nu
  if ("{{trace}}" == "-t" or "{{trace}}" == "--trace") {
    $env.DART_VM_OPTIONS = "--enable-asserts"
    cd common
    dart test
    cd ../tui
    dart test
    cd ../wasmtime_dart
    dart test
    cd ..
    bash tests/scripts/check-plugin-consistency.sh
  } else if ("{{trace}}" == "") {
    cd common
    dart test
    cd ../tui
    dart test
    cd ../wasmtime_dart
    dart test
    cd ..
    bash tests/scripts/check-plugin-consistency.sh
  } else {
    print "Unknown argument '{{trace}}'. Pass '-t' for verbose or nothing for default."
  }

# Checks that the bitcoind/lnd/cln plugins agree on the nix-bitcoin rev
# and share the same lightning tile manifest (CI invariant).
#
# Check bitcoind/lnd/cln nix-bitcoin rev + lightning tile consistency
check-plugin-consistency:
  bash tests/scripts/check-plugin-consistency.sh

# Rebuilds node-summary's guest and byte-compares against the committed
# actions/summary.wasm, mirroring the tile-manifest invariant. wasm
# builds aren't guaranteed bit-reproducible; a mismatch means review the
# diff, not tampering.
#
# Dev-local guard, not wired into `ci`: node-summary lives in the
# nixblitz_official_plugins repo, checked out (optionally) at
# examples_redesign/, which is gitignored here and absent on a clean
# checkout / CI runner — that repo owns its own CI for this check.
#
# Fail if a plugin's committed .wasm is stale vs a fresh build
check-wasm-plugins:
  bash tests/scripts/check-wasm-plugins.sh

# Eval tier — instantiates the toplevel, no system build. First run on
# a cold store is heavy (realizes the build-input closure for both
# channels); subsequent runs hit the warm store.
# See docs/superpowers/specs/2026-05-19-config-channel-verification-design.md
#
# Verify the base node config evaluates against nixpkgs stable + unstable
test-config:
  #!/usr/bin/env nu
  nix build --no-link .#checks.x86_64-linux.config-installed-stable .#checks.x86_64-linux.config-installed-unstable .#checks.x86_64-linux.config-installer-stable .#checks.x86_64-linux.config-installer-unstable
  print "config eval matrix (stable + unstable): all green"

# Run dart analyze on all packages
analyze:
  #!/usr/bin/env nu
  cd common; dart analyze
  cd ../tui; dart analyze
  cd ../website; dart analyze
  cd ../wasmtime_dart; dart analyze

# Format Dart, Nix, and Markdown/YAML/JSON (skips ./examples_redesign + dev dirs)
format:
  #!/usr/bin/env nu
  do -c {
    print "Formatting Dart code..."
    let dirs = ["common", "tui", "website", "wasmtime_dart"]
    for dir in $dirs {
      if ($dir | path exists) {
        print $"Formatting ($dir)..."
        cd $dir
        dart format .
        cd ..
      }
    }
  }
  print "Formatting Nix code..."
  alejandra . --exclude ./examples_redesign --exclude ./.devenv --exclude ./.direnv --exclude ./.claude
  print "Formatting markdown / yaml / json..."
  prettier -w . --log-level warn

# Guards against someone editing templates/ or branches.json without
# re-running gen-templates. Snapshots the generated file, regenerates,
# and compares content (VCS-agnostic, so it works with an uncommitted
# fix in the tree too). On drift the file is left regenerated so you can
# review + commit it. This is the guard that turns a silently-shipped
# stale template into a hard failure.
#
# Fail if the embedded templates are stale (edited without gen-templates)
check-templates:
  #!/usr/bin/env nu
  let f = "common/lib/src/services/embedded_templates.g.dart"
  let before = (open --raw $f)
  dart run scripts/gen_embedded_templates.dart
  if ($before != (open --raw $f)) {
    print $"($f) was stale — regenerated in place; review and commit it."
    exit 1
  }
  print "Embedded templates are in sync."

# Guards against editing ffigen.yaml or bumping wasmtime without
# regenerating. Snapshots the generated file, regenerates, compares
# content; on drift the file is left regenerated so you can review +
# commit it (same pattern as check-templates).
#
# Fail if wasmtime_dart's generated bindings are stale
check-wasmtime-bindings:
  #!/usr/bin/env nu
  let f = "wasmtime_dart/lib/src/generated/bindings.g.dart"
  let before = (open --raw $f)
  just gen-wasmtime-bindings
  if ($before != (open --raw $f)) {
    print $"($f) was stale — regenerated in place; review and commit it."
    exit 1
  }
  print "wasmtime_dart bindings are in sync."

# Runs the Dart format check without writes. The heavier nix
# config-eval matrix lives in `test-config` and is intentionally left
# out of this gate.
#
# Fast CI gate: tests + analyzer + template freshness + format check
ci:
  #!/usr/bin/env nu
  just test
  just analyze
  just check-templates
  just check-wasmtime-bindings
  cd common; dart format --output=none --set-exit-if-changed .
  cd ../tui; dart format --output=none --set-exit-if-changed .
  cd ../website; dart format --output=none --set-exit-if-changed .
  cd ../wasmtime_dart; dart format --output=none --set-exit-if-changed .
  cd ..
  print "CI gate green."

# Run the TUI
run:
  cd tui; dart run bin/nixblitz.dart

# Run the dev TUI (separate entry point with widget/view demos)
run-dev:
  cd tui; dart run bin/nixblitz_dev.dart

# Generate Nix lock files from pubspec.lock
gen-locks: gen-workspace-lock gen-workspace-graph

# Generate workspace pubspec lock JSON for Nix
gen-workspace-lock:
  nu scripts/gen_workspace_lock.nu

# Generate workspace dependency graph JSON for Nix
gen-workspace-graph:
  python3 scripts/gen_workspace_graph.py

# Regenerate embedded templates from templates/ directory
gen-templates:
  dart run scripts/gen_embedded_templates.dart

# Regenerate embedded dashboard manifests from bundled/manifests/
gen-manifests:
  dart run scripts/gen_dashboard_manifests.dart

# Regenerate embedded app config schemas from bundled/manifests/
gen-app-schemas:
  dart run scripts/gen_app_config_schemas.dart

# These are generic shell stubs that call `nixblitz completion` at
# runtime; they only need regeneration when the cli_completion
# package is bumped, not when our command tree changes.
#
# Regenerate shell completion scripts (tui/completions/nixblitz.{bash,zsh})
gen-completions:
  dart run scripts/gen_completion_scripts.dart

# Resolves the wasmtime C headers + libclang, symlinks them to stable
# paths (ffigen.yaml cannot expand env vars), and runs ffigen. The
# wasmtime headers come from our PINNED wasmtime (.#wasmtime-pinned,
# nix/wasmtime.nix) — the same derivation whose lib the TUI wrapper
# bakes — so the generated bindings and the runtime library are the same
# version by construction. Prefers $WASMTIME_INCLUDE if the devenv
# exported it (also the pinned one). Rerun after a wasmtime bump in
# nix/wasmtime.nix; commit the result.
#
# Regenerate wasmtime_dart's raw FFI bindings from the wasmtime C headers
gen-wasmtime-bindings:
  #!/usr/bin/env nu
  let dev_include = (if ($env.WASMTIME_INCLUDE? | is-not-empty) {
    $env.WASMTIME_INCLUDE
  } else {
    let dev = (nix build ".#wasmtime-pinned" --no-link --print-out-paths | str trim)
    $"($dev)/include"
  })
  let libclang_lib = (if ($env.LIBCLANG_PATH? | is-not-empty) {
    $env.LIBCLANG_PATH
  } else {
    $"(nix build nixpkgs#libclang.lib --no-link --print-out-paths | str trim)/lib"
  })
  # libclang (invoked directly, not via the gcc/clang wrapper) doesn't
  # pick up glibc's headers on its own on NixOS; symlink them next to
  # the wasmtime headers so ffigen.yaml's compiler-opts can reach them
  # without hardcoding a nix store path. No devenv env var covers this
  # one, so it stays on the flake registry.
  let glibc = (nix build nixpkgs#glibc.dev --no-link --print-out-paths | str trim)
  cd wasmtime_dart
  mkdir .dart_tool
  ^ln -sfn $dev_include .dart_tool/wasmtime-include
  ^ln -sfn $libclang_lib .dart_tool/libclang-lib
  ^ln -sfn $"($glibc)/include" .dart_tool/glibc-include
  dart run ffigen --config ffigen.yaml

# Compile Tailwind CSS for the website (web/input.css → web/styles.css)
web-css:
  #!/usr/bin/env nu
  cd website; tailwindcss -i web/input.css -o web/styles.css

# Watch and recompile Tailwind CSS as you edit
web-css-watch:
  #!/usr/bin/env nu
  cd website; tailwindcss -i web/input.css -o web/styles.css --watch

# Passes BUILD_VERSION + BUILD_GIT_HASH the same way `nix build .#website`
# does so the header version string shows real git context during dev.
# Optional positional argument is the BASE_PATH for previewing a
# subpath-served build (e.g. `just web-serve /nixblitz`). The dev
# server still binds at /, so the rendered href()-prefixed links go
# 404 — that's the visual check that prefixing is happening at all.
#
# Serve the website locally with hot reload (http://localhost:8383)
web-serve base_path="": web-css
  #!/usr/bin/env nu
  let hash = (git rev-parse --short=7 HEAD | str trim)
  let dirty = ((git status --porcelain | str length) > 0)
  let tagged = (if $dirty { $"($hash)-dirty" } else { $hash })
  cd website
  jaspr serve --dart-define=BUILD_VERSION=0.1.0 --dart-define=BUILD_GIT_HASH=($tagged) --dart-define=BASE_PATH={{base_path}}

# Optional positional argument sets the BASE_PATH override for the
# subpath build (e.g. `just web-build /nixblitz`).
#
# Build the website via Nix (output symlink: ./result/)
web-build base_path="":
  #!/usr/bin/env nu
  if "{{base_path}}" == "" {
    nix build .#website
  } else {
    nix build --expr $"\(builtins.getFlake \"(pwd)\"\).packages.x86_64-linux.website.override { basePath = \"{{base_path}}\"; }" --impure
  }

# Faster dev iteration than the Nix build; needs `jaspr` on PATH.
# Optional positional argument sets the BASE_PATH (see `web-serve`).
#
# Build the website locally with jaspr (output: website/build/jaspr/)
web-build-local base_path="": web-css
  #!/usr/bin/env nu
  let hash = (git rev-parse --short=7 HEAD | str trim)
  let dirty = ((git status --porcelain | str length) > 0)
  let tagged = (if $dirty { $"($hash)-dirty" } else { $hash })
  cd website
  jaspr build -O4 --dart-define=BUILD_VERSION=0.1.0 --dart-define=BUILD_GIT_HASH=($tagged) --dart-define=BASE_PATH={{base_path}}

# Serve the Nix-built bundle on http://localhost:8383
web-serve-prod: web-build
  #!/usr/bin/env nu
  cd result; python3 -m http.server 8383

# Clean local build artifacts (nix-built ./result/ is unaffected)
web-clean:
  #!/usr/bin/env nu
  cd website; rm -rf build .dart_tool

# Build the x86_64 installer ISO (carries the nixblitz TUI)
iso-build:
  #!/usr/bin/env nu
  nix build .#installer-iso
  let iso = (ls result/iso/*.iso | get name | first)
  print $"ISO built: ($iso)"

# Boot the nixblitz installer ISO in QEMU for testing the installer
vm-boot:
  #!/usr/bin/env nu
  # Build the nixblitz installer ISO if it isn't present, then boot it.
  # (Cheap when the store is warm.) Was previously a hand-downloaded
  # stock nixos-minimal ISO; now we boot our own TUI-carrying image.
  if not ('result/iso' | path exists) {
    print "Building installer ISO (just iso-build)..."
    nix build .#installer-iso
  }
  let iso = (ls result/iso/*.iso | get name | first)

  if not ($iso | path exists) {
    print $"ISO not found at ($iso) — run 'just iso-build'"
    exit 1
  }

  if not ('nixblitz-disk.qcow2' | path exists) {
    print "Creating 150G disk image 'nixblitz-disk.qcow2'..."
    qemu-img create -f qcow2 nixblitz-disk.qcow2 150G
  }

  print "Booting NixOS installer VM..."
  print "  SSH:    ssh -p 10022 nixos@localhost"
  print "  HTTP:   http://localhost:18080  (nginx)"
  print "  LNBits: http://localhost:18231  (when installed)"
  print "  Disk:   nixblitz-disk.qcow2 (virtio)"
  (qemu-system-x86_64 -enable-kvm -m 8192 -smp 4
    -netdev user,id=mynet0,hostfwd=tcp::10022-:22,hostfwd=tcp::18080-:80,hostfwd=tcp::18231-:8231
    -device virtio-net-pci,netdev=mynet0
    -drive file=nixblitz-disk.qcow2,if=none,id=virtio0,format=qcow2
    -device virtio-blk-pci,drive=virtio0
    -cdrom $iso)

# Boot the installed system from the qcow2 disk (no ISO)
vm-run:
  #!/usr/bin/env nu
  if not ('nixblitz-disk.qcow2' | path exists) {
    print "Disk image 'nixblitz-disk.qcow2' not found. Run 'just vm-boot' first."
    exit 1
  }

  print "Booting installed NixOS VM..."
  print "  SSH:    ssh -p 10022 admin@localhost"
  print "  HTTP:   http://localhost:18080  (nginx)"
  print "  LNBits: http://localhost:18231  (when installed)"
  (qemu-system-x86_64 -enable-kvm -m 8192 -smp 4
    -netdev user,id=mynet0,hostfwd=tcp::10022-:22,hostfwd=tcp::18080-:80,hostfwd=tcp::18231-:8231
    -device virtio-net-pci,netdev=mynet0
    -drive file=nixblitz-disk.qcow2,if=none,id=virtio0,format=qcow2
    -device virtio-blk-pci,drive=virtio0)

# Deploy unwrapped nixblitz binary to VM for quick testing (no disko).
# The binary carries the pinned wasmtime lib path as a compile-time
# define (see nix/tui_pkg.nix), so it finds the sandbox runtime with no
# env var — but that store path must exist in the VM store, so we copy
# the closure over first (best-effort; it's usually already there from
# an installed wrapped system).
#
# Deploy the dev TUI to the VM for quick testing
vm-deploy:
  #!/usr/bin/env nu
  let unwrapped = (nix build .#nixblitz-unwrapped --print-out-paths | str trim)
  let wt = (nix build ".#wasmtime-pinned" --print-out-paths | str trim)
  let sshopts = "-oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no"
  # Ensure the baked wasmtime path exists in the VM store. Non-fatal on
  # failure (e.g. an untrusted nixos user) — the closure is usually
  # already present via the installed system.
  print $"Ensuring pinned wasmtime closure on VM ($wt)..."
  try {
    with-env {NIX_SSHOPTS: $"($sshopts) -p 10022"} {
      nix copy --to "ssh://nixos@localhost" --no-check-sigs $wt
    }
  } catch {
    print "  nix copy skipped (closure likely already present via the system)"
  }
  print $"Deploying ($unwrapped)/bin/nixblitz-bin to VM..."
  ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no nixos@localhost -p 10022 'rm -f /tmp/nixblitz /tmp/nixblitz-bin; rm -rf ~/nixblitz; rm -f ~/nixblitz.log'
  scp -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -P 10022 $"($unwrapped)/bin/nixblitz-bin" nixos@localhost:/tmp/nixblitz
  print "Deployed. Run on VM: /tmp/nixblitz"
  print "For full install test (with disko), run on the VM instead:"
  print "  nix run git+https://forge.f44.fyi/f44/nixblitz_ng"

# SSH into the installer VM (live ISO)
vm-ssh-installer:
  ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no nixos@localhost -p 10022

# SSH into the installed VM
vm-ssh:
  ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no admin@localhost -p 10022

# Delete the disk image to start fresh
vm-clean:
  rm -f nixblitz-disk.qcow2
