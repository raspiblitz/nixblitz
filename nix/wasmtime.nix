# Pinned wasmtime C API — the ONE wasmtime version nixblitz controls.
#
# The wasmtime_dart binding is FFI: its generated bindings
# (wasmtime_dart/lib/src/generated/bindings.g.dart) are transcribed from a
# specific wasmtime major's C headers, so the runtime libwasmtime.so MUST
# match that version exactly — a mismatch is silent ABI drift. Unlike
# bitcoind (which we call as a subprocess with a stable CLI, so it floats
# with whatever nixpkgs a node has), wasmtime cannot float. We therefore
# pin it here, independent of the flake's nixpkgs inputs, using the
# official bytecodealliance c-api release artifacts (the same approach
# wasmtime-py takes) locked by sha256.
#
# Both outputs a consumer needs come from this one derivation:
#   ${wasmtimePinned}/lib/libwasmtime.so   → baked into the TUI wrapper
#                                             (WASMTIME_DART_LIB) and the
#                                             dev shell.
#   ${wasmtimePinned}/include              → ffigen header source for
#                                             `just gen-wasmtime-bindings`.
#
# BUMPING: change `version` + the two per-arch `hash`es (get them with
#   nix-prefetch-url <release-url>), then regenerate the bindings
#   (`just gen-wasmtime-bindings`) and run the wasmtime_dart tests. The
#   bindings and this lib move together, by construction.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}: let
  version = "46.0.1";

  # SRI hashes of wasmtime-v${version}-<arch>-linux-c-api.tar.xz — the
  # official sha256s from
  # https://github.com/bytecodealliance/wasmtime/releases/tag/v46.0.1
  hashes = {
    "x86_64-linux" = "sha256-S356zwhGfeYUfxHI+3HE23YjA1BkwJaXaqlp1UFx/tQ=";
    "aarch64-linux" = "sha256-NoQG24Anw2HhKtg4+1PwSbmSmFgGv7ElaruicRLf9a4=";
  };

  arch =
    {
      "x86_64-linux" = "x86_64";
      "aarch64-linux" = "aarch64";
    }
    .${
      stdenv.hostPlatform.system
    }
    or (throw "wasmtime-pinned: unsupported system ${stdenv.hostPlatform.system}");

  tarball = "wasmtime-v${version}-${arch}-linux-c-api";
in
  stdenv.mkDerivation {
    pname = "wasmtime-pinned-c-api";
    inherit version;

    src = fetchurl {
      url = "https://github.com/bytecodealliance/wasmtime/releases/download/v${version}/${tarball}.tar.xz";
      hash =
        hashes.${stdenv.hostPlatform.system}
        or (throw "wasmtime-pinned: no hash for ${stdenv.hostPlatform.system}");
    };

    # The prebuilt libwasmtime.so references a stock ld/glibc; autoPatchelf
    # rewrites its NEEDED libs against this stdenv so it loads on NixOS.
    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [stdenv.cc.cc.lib];

    # Tarball is a single top-level dir with lib/ + include/ (+ a `min/`
    # variant we ignore). Copy the full-featured lib + headers.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include
      cp -r lib/libwasmtime.so lib/libwasmtime.a $out/lib/
      cp -r include/* $out/include/
      runHook postInstall
    '';

    dontConfigure = true;
    dontBuild = true;

    meta = {
      description = "Pinned wasmtime ${version} C API (lib + headers) for wasmtime_dart";
      homepage = "https://wasmtime.dev/";
      license = with lib.licenses; [asl20 llvm-exception];
      platforms = ["x86_64-linux" "aarch64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
