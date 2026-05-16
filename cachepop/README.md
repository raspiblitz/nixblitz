# cachepop

Attic cache populator for nixblitz build hosts. Runs as a systemd timer
on a beefy x86 machine (typically with `boot.binfmt.emulatedSystems =
["aarch64-linux"]` for Pi 5 cross-builds), periodically rebuilding
configured targets and pushing the closures to an Attic cache.

## Why

The Pi 5 hits cache misses on `cache.nixos.org` for the page-size-16k
jemalloc rebuild chain (any Rust/Python-FFI package that vendors
`jemalloc-sys` — `uv`, `aiohttp`'s ruff stack, etc.). The standard
aarch64 substitutes are 4K-aligned and SIGBUS on the Pi's 16K kernel.
Local rebuilds on the Pi itself take hours and thermal-stress the
hardware. The operator's own Attic cache, populated by a faster x86
build host, sidesteps both problems.

cachepop automates the build-host side: bootstrap per-target profiles,
advance flake inputs, build, push.

## Usage as a NixOS module

In the build host's flake:

```nix
{
  inputs.nixblitz.url = "git+https://forge.f44.fyi/f44/nixblitz_ng";

  outputs = inputs: {
    nixosConfigurations.buildhost = inputs.nixpkgs.lib.nixosSystem {
      modules = [
        inputs.nixblitz.nixosModules.cachepop
        {
          boot.binfmt.emulatedSystems = ["aarch64-linux"];

          services.nixblitz-cachepop = {
            enable = true;
            atticCache = "f44:nixblitz";
            atticEndpoint = "https://attic.f44.fyi/";
            atticTokenFile = "/run/secrets/cachepop-token";
            targets = [
              { name = "pi5-mainnet";
                flakeAttr = "nixblitz-pi5";
                platform = "pi5";
                plugins = ["bitcoind" "lnd" "blitz-api" "blitz-web" "lnbits" "tailscale"]; }
            ];
          };
        }
      ];
    };
  };
}
```

The first timer fire (or `systemctl start nixblitz-cachepop.service`)
bootstraps each target's profile — runs `nixblitz init`, installs the
configured plugins, flips `initialized: true`. Then it advances flake
inputs, builds the closure, pushes to Attic. On the Pi side, the next
`nixos-rebuild switch` substitutes from cache instead of compiling.

## Workstation vs. dedicated build host

The defaults assume your build host is a workstation you actively use,
not a 24/7 build farm:

- `enableTimer = true`, `schedule = "daily"` — change to `false` for
  manual-only operation (`systemctl start nixblitz-cachepop.service`
  when you've got CPU to spare).
- `maxJobs = 1`, `cpuCores = 0` — one derivation at a time, each
  unbounded internally. Set `cpuCores = N` to cap per-derivation
  parallelism at N cores (also enforces `CPUQuota = N*100%` at the
  cgroup level). Total CPU pressure stays ≤ N because `maxJobs = 1`.
- `Nice = 10`, best-effort I/O priority 7 — the build yields to
  interactive use under contention.

For a dedicated build host where "go fast" is the goal:

```nix
services.nixblitz-cachepop = {
  maxJobs = "auto";     # nix sizes to nproc
  cpuCores = 0;          # no per-derivation cap
};
```

`nix-daemon` does the actual compilation work, in its own cgroup —
the service's CPUQuota only constrains the cachepop process and
`nix build` client. The real CPU brake is `cores × max-jobs`. With
`maxJobs = 1` and `cpuCores = 12` the daemon never spins up a
17-derivation parallel storm.

## Generating the Attic token

```bash
attic make-token --sub buildhost --validity 90d \
  --pull '*' --push 'nixblitz'
```

Store the resulting token in your sops secrets (or wherever your secret
plumbing lives) and point `atticTokenFile` at the decrypted path. The
token never enters the nix store — only the file path does.

## Usage as a standalone CLI

If you'd rather drive cachepop manually (testing, ad-hoc cache fills),
the binary lives at `result/bin/cachepop` after `nix build .#cachepop`.
It expects a config at one of (in priority order):

1. `--config PATH`
2. `$CACHEPOP_CONFIG`
3. `$XDG_CONFIG_HOME/cachepop/config.json`
4. `$HOME/.config/cachepop/config.json`

Schema:

```json
{
  "stateDir": "/var/lib/nixblitz-cachepop",
  "atticCache": "f44:nixblitz",
  "atticEndpoint": "https://attic.f44.fyi/",
  "targets": [
    {
      "name": "pi5-mainnet",
      "flakeAttr": "nixblitz-pi5",
      "platform": "pi5",
      "plugins": ["bitcoind", "lnd", "blitz-api"]
    }
  ]
}
```

Subcommands:

| Verb              | Purpose                                                 |
| ----------------- | ------------------------------------------------------- |
| `init <target>`   | Bootstrap a profile dir (requires `--flake-attr`, etc.) |
| `check`           | Advance flake inputs, report which moved                |
| `build [target…]` | Build each target's `system.build.toplevel`             |
| `push [target…]`  | Push last build to Attic                                |
| `sync`            | check → if drift: build + push. Timer entry point.      |
| `status`          | Pretty-print the status JSON                            |

## First-run expectations

- **Pi 5 kernel + page-size-16k jemalloc**: a few minutes (substituted
  from `nixos-raspberrypi.cachix.org` if the build host has it
  configured).
- **`uv` + `aiohttp` Python wheels**: 10-30 minutes on a fast x86 box
  with binfmt aarch64 (these are the structural cache misses).
- **Closure push to Attic**: ~5 minutes for the initial full closure
  (~1.5 GB); subsequent pushes only upload diffs.

After the first cycle, the Pi side substitutes everything cachepop has
populated — including the jemalloc-sys chain that previously SIGBUS'd
on `cache.nixos.org`'s 4K-aligned aarch64 builds.

## State layout

```
/var/lib/nixblitz-cachepop/
├── status.json
├── .config/attic/config.toml          # rendered at service start
└── targets/
    └── <target-name>/
        ├── home/nixblitz/             # per-target profile (config.json, flake.nix, plugins/...)
        ├── lock.prev.json             # last-seen flake.lock for drift compare
        └── last-build.txt             # outPath of the last successful build
```

`systemctl status nixblitz-cachepop` and `journalctl -fu
nixblitz-cachepop` cover observability for now.
