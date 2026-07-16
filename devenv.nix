{
  pkgs,
  inputs,
  ...
}: let
  pkgs-unstable = import inputs.nixpkgs-unstable {inherit (pkgs.stdenv) system;};
  # Pinned wasmtime c-api (see nix/wasmtime.nix) — the dev shell exports
  # its lib/headers so tests + gen-wasmtime-bindings use the exact version
  # the FFI bindings were generated against, same as the flake wrapper.
  wasmtimePinned = pkgs.callPackage ./nix/wasmtime.nix {};
  androidConfig = {
    platformVersion = "36";
    buildToolsVersion = "35.0.1"; # version for aapt, dx, apksigner
    platformToolsVersion = "35.0.1"; # version for adb, fastboot (Must be one of the available ones: 35.0.1, 36.0.1 etc)
    ndkVersion = "27.0.12077973";
  };
in {
  packages = [
    pkgs.alejandra
    pkgs.eslint
    pkgs.eslint_d
    pkgs.black
    pkgs.fixjson
    pkgs.git
    pkgs.yq
    pkgs.just
    pkgs.nixd
    pkgs.nodejs
    pkgs.pkg-config
    pkgs.prettierd
    pkgs.statix
    pkgs.topiary
    pkgs.sqlite
    pkgs.sqlitestudio
    pkgs.mailpit
    pkgs.lazysql
    pkgs.frp
    pkgs.mitmproxy
    pkgs.tailwindcss_4
    pkgs.tailwindcss-language-server
    pkgs-unstable.forgejo-cli
    pkgs.sshpass
    pkgs.prettier
    pkgs.attic-client
    # Terminal-session recording for the website / docs.
    # `asciinema` records sessions to .cast files (timeline + bytes).
    # `asciinema-agg` converts .cast into animated GIFs / mp4 for
    # embedding outside the asciinema-player JS widget.
    pkgs.asciinema
    pkgs.asciinema-agg
    # Pinned wasmtime (lib + headers) — the ONE version the FFI bindings
    # match. Same derivation the flake wrapper bakes; see nix/wasmtime.nix.
    wasmtimePinned
    pkgs-unstable.libclang.lib
  ];

  env = {
    WASMTIME_DART_LIB = "${wasmtimePinned}/lib/libwasmtime.so";
    WASMTIME_INCLUDE = "${wasmtimePinned}/include";
    LIBCLANG_PATH = "${pkgs-unstable.libclang.lib}/lib";
  };

  android = {
    enable = true;
    flutter = {
      enable = true;
      package = pkgs-unstable.flutter;
    };

    platforms.version = [androidConfig.platformVersion];
    emulator.enable = false;
    platformTools.version = androidConfig.platformToolsVersion;
    ndk = {
      enable = false;
      version = [androidConfig.ndkVersion];
    };
    buildTools.version = [androidConfig.buildToolsVersion];
    abis = ["x86_64"];

    android-studio.enable = false;
    googleAPIs.enable = false;
    googleTVAddOns.enable = false;
  };

  enterShell = ''
    echo "Adding \$HOME/.pub-cache/bin to \$PATH"
    export PATH="$PATH":"$HOME/.pub-cache/bin"
    echo "Disabling Dart analytics"
    dart --disable-analytics > /dev/null

    echo "Enabling Jaspr CLI"
    dart pub global activate jaspr_cli
    jaspr --disable-analytics

    echo "Disabling Flutter analytics"
    flutter config --no-analytics > /dev/null

    echo "Disabling Android SDK analytics"
    mkdir -p ~/.android
    echo "count=0" > ~/.android/analytics.settings
    echo "enabled=false" >> ~/.android/analytics.settings


    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [pkgs.sqlite]}:$LD_LIBRARY_PATH"

    echo "====== Android SDK env vars ======"
    echo "ANDROID_HOME:      $ANDROID_HOME"
    echo "ANDROID_NDK_HOME:  $ANDROID_NDK_HOME"
    echo "ANDROID_SDK_ROOT:  $ANDROID_SDK_ROOT"
    echo ""
    echo "====== Proxy & Inspection ======"
    echo "MITM Proxy: http://localhost:8091 -> Backend (8090)"
    echo "Web UI:     http://localhost:8082"
    echo "Mailpit:    http://localhost:8025 (SMTP: 1025)"
  '';

  processes = {
    # mitmweb-proxy = {
    #   exec = "mitmweb --mode reverse:http://localhost:8090 --listen-port 8091 --web-port 8082 --web-host 127.0.0.1";
    # };
    jaspr = {
      cwd = "./pwa";
      exec = "jaspr serve --dart-define=APP_VERSION=dev";
    };
    frpc = {
      cwd = ".";
      exec = "frpc --strict-config -c .frpc.toml";
    };
    mailpit = {
      exec = "mailpit --smtp-auth-accept-any --smtp-auth-allow-insecure --verbose";
    };
    backend = {
      cwd = "./backend";
      exec = ''
        go run . serve --dev
      '';
      process-compose = {
        environment = [
          "APP_CONFIG_PATH=../backend_config.json"
          "SMTP_HOST=127.0.0.1"
          "SMTP_PORT=1025"
        ];
      };
    };
    tailwindcss = {
      cwd = "./pwa";
      exec = "tailwindcss -i ./web/input.css -o ./web/styles.css --watch";
      process-compose = {
        is_tty = true;
        environment = ["DEBUG=tailwindcss:*"];
      };
    };
  };
}
