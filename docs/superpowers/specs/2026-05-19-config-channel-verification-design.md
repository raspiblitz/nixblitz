# Config channel verification — design

> Verify the nixblitz node config evaluates cleanly against multiple
> nixpkgs channels (stable + vanilla unstable), so nixpkgs drift
> (renamed options, removed packages) is caught before it reaches an
> operator's rebuild.

## Context

The node configuration lives in `templates/flake.nix`, whose
`nixpkgs` follows `nixos-raspberrypi/nixpkgs` (pinned to nvmd's tag
for Pi 5 cache alignment — see CLAUDE.md "Flake input rules"). That
pin is deliberately conservative, which means the config is only
ever evaluated against _one_ nixpkgs in practice. When nixpkgs
stable advances (a point release) or when we eventually want to
track unstable, an option rename or a removed package surfaces as a
broken `nixos-rebuild` on the operator's box — the operator is the
canary.

Today's testing (`just test`) is Dart unit tests + a plugin-
consistency shell check. There is **no** Nix-level verification of
the config at all, and `just vm-boot` is fully manual. Issue #26
proposes a tiered testing strategy (eval → build → VM boot); this
spec implements the **eval tier, channel axis** of that strategy:
does the base config still _evaluate_ against stable and unstable.

## Goals

- Catch nixpkgs-drift breakage (renamed/removed options + packages)
  in the modules nixblitz owns (`templates/modules/`), against both
  a stable release and vanilla unstable, before an operator hits it.
- A single command (`just test-config`) the operator runs locally;
  a future Forgejo Actions job calls the same.
- Structure the harness so the deferred build + VM-boot tiers slot
  in **additively** — no rewrite of the matrix or config-construction
  core when those land.

## Non-goals (this deliverable)

- Build tier (`nix build` the toplevel) and VM-boot tier
  (`nixosTest`). Designed for, not implemented now.
- Plugin-combination matrix (bitcoind × ln × api × web). Base config
  only; the apps are plugins now and would need fixture snapshots.
- Pi 5 configs. Locked to nvmd's nixpkgs by design; varying their
  nixpkgs is meaningless and defeats the cache story.
- Driving the nocterm TUI from a test driver (#26 tier 3).

## Architecture

Three layers, each with one job. The bottom two are tier-agnostic;
only the top layer knows about eval vs build vs boot.

### Layer 1 — config-construction core (shared by all tiers)

A single function builds a node config for a given channel + host:

```nix
# tests/config/default.nix
mkNodeConfig = { channelPkgs, hostName }:
  channelPkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { nixblitz = self; };   # self == nixblitz_ng
    modules =
      (findModules ../../templates/modules)        # real module set
      ++ [
        (profile + "/hosts/${hostName}.nix")       # host, profile-merged
        disko.nixosModules.default                 # root flake's disko
      ];
  };
```

The module set is pulled by **relative import** of
`templates/modules` (replicating templates/flake.nix's ~12-line
`findModules` directory walk) plus the root flake's existing
`disko` input — _not_ by adding `templates` as a flake input.
Rationale (operator's call): a `templates.url = "path:./templates"`
input would drag templates' whole closure (nixos-raspberrypi's
vendor-kernel flake + a remote git fetch of nixblitz_ng) into the
otherwise-lean root lock. Relative import keeps the root flake's
only new input `nixpkgs-vanilla-unstable`. The duplicated
`findModules` is small and stable.

`(findModules ../../templates/modules)` reproduces exactly what
`templates.nixosModules.default` assembles minus the plugin list
(empty for the base config) — same modules, only the `nixpkgs`
handle varies, which is the variable under test.

**Profile merge (the host-module wrinkle).** `templates/hosts/
installed.nix` reads `../config.json` _unconditionally_ (line 7) and
imports `../hardware-configuration.nix` (line 32) — both generated
by `nixblitz init` / install, absent from the templates source.
So the host module can't be imported straight from the `templates`
input; its two sibling files must exist. We supply them via a tiny
fixture + an import-from-derivation merge:

```nix
profile = pkgs.runCommand "nixblitz-test-profile" {} ''
  mkdir -p $out/hosts
  cp ${../../templates/hosts/installed.nix} $out/hosts/installed.nix
  cp ${../../templates/hosts/installer.nix} $out/hosts/installer.nix
  cp ${./fixtures/base/config.json}              $out/config.json
  cp ${./fixtures/base/hardware-configuration.nix} $out/hardware-configuration.nix
'';
```

`profile/hosts/installed.nix` then resolves `../config.json` →
`profile/config.json` and `../hardware-configuration.nix` →
`profile/hardware-configuration.nix`. The host module is _copied
fresh from the `templates` input each eval_, so it never rots — only
the two fixture files are committed. installed.nix imports no
`../modules/*` files (verified), so there's no double-import clash
with `templates.nixosModules.default`. IFD is allowed under
`nix flake check` by default.

The fixture `config.json` is a schema-v18 minimal x86 profile with
`initialized: true` (so service-wiring modules actually evaluate —
more drift coverage than the bootstrap `initialized: false` path)
and `app_configs: {}` (base config, no plugins). The fixture
`hardware-configuration.nix` is the minimal stub needed to satisfy
eval-time assertions (root filesystem + boot device); the exact
content is settled empirically during implementation (start with
`{...}: {}`, add `fileSystems` / `boot.loader` only if eval demands
them — disko may already supply them).

### Layer 2 — the matrix (channels × hosts), defined once

```nix
channels = {
  stable   = nixpkgs;                 # github:nixos/nixpkgs/nixos-25.11
  unstable = nixpkgs-vanilla-unstable; # github:nixos/nixpkgs/nixos-unstable
};
hosts = {
  installed = templates + "/hosts/installed.nix";
  installer = templates + "/hosts/installer.nix";
};
# Cartesian product → { installed-stable = cfg; installed-unstable = …; … }
matrix = <product of channels × hosts through mkNodeConfig>;
```

Four entries today (2 hosts × 2 channels). Adding a channel or host
is one line here; nothing downstream changes.

### Layer 3 — tier appliers (the only tier-aware code)

Each tier is a function that turns a built config into a check
derivation. The eval tier is the only one implemented now; the
others are the extensibility contract:

```nix
# Implemented now:
evalGate = name: cfg:
  pkgs.runCommand "config-eval-${name}" {} ''
    # Referencing .drvPath forces full module evaluation (the
    # derivation gets instantiated) without realizing the system.
    # If eval throws — renamed option, removed package — this
    # runCommand can't be produced and `nix flake check` fails.
    echo ${cfg.config.system.build.toplevel.drvPath} > $out
  '';

# Future (sketched, NOT built — documents the additive shape):
# buildGate = name: cfg: cfg.config.system.build.toplevel;
# bootGate  = name: cfg: pkgs.nixosTest { name = "config-boot-${name}";
#                          nodes.machine = { ... }; testScript = ...; };
```

`checks.x86_64-linux` is the eval tier mapped over the matrix:

```nix
checks.x86_64-linux =
  lib.mapAttrs' (n: cfg: lib.nameValuePair "config-${n}" (evalGate n cfg)) matrix;
# → config-installed-stable, config-installed-unstable,
#   config-installer-stable, config-installer-unstable
```

When the build tier lands, it's a second `mapAttrs'` with `buildGate`
and a `build-` prefix over the **same** `matrix`. Zero churn to
layers 1-2. The `<tier>-<host>-<channel>` naming keeps tiers
namespaced.

### File layout

Test harness lives under `tests/` (alongside the existing
`tests/scripts/check-plugin-consistency.sh`), not `nix/` — `nix/`
is package-build definitions (`tui_pkg.nix`, `website_pkg.nix`,
lock JSON), whereas this is a test. A `tests/config/` subdir
carves out a home for the whole config-verification effort so the
deferred build/boot tiers + a future combo-matrix fixture set land
without relocating anything.

```
tests/
├── scripts/
│   └── check-plugin-consistency.sh     (existing)
└── config/
    ├── default.nix                     (Layers 1-3)
    └── fixtures/
        └── base/
            ├── config.json             (schema-v18 minimal x86)
            └── hardware-configuration.nix  (eval-assertion stub)
                                         future: more fixtures, tier siblings
```

- `tests/config/default.nix` — new. Layers 1-3 + a local
  `findModules`. Takes `{ self, lib, nixpkgs,
nixpkgs-vanilla-unstable, disko, system }`, returns the `checks`
  attrset.
- `tests/config/fixtures/base/{config.json,hardware-configuration.nix}`
  — new. The two files the host module needs as siblings.
- `flake.nix` — add the `nixpkgs-vanilla-unstable` input; wire
  `checks = import ./tests/config { … }` inside the
  `eachDefaultSystem` block, gated to `x86_64-linux`.
- `justfile` — add `test-config` recipe.

## Channels + new input

```nix
# flake.nix inputs — ONE new input
nixpkgs.url = "github:nixOS/nixpkgs/nixos-25.11";          # existing — stable
nixpkgs-vanilla-unstable.url = "github:nixos/nixpkgs/nixos-unstable"; # NEW
```

The existing `nixpkgs-unstable` (the `dart-workspace-member-filter`
fork) stays as-is — it's for building the TUI and is the wrong
nixpkgs for node-config testing. `nixpkgs-vanilla-unstable` needs no
`follows` (it only supplies `lib.nixosSystem` + `pkgs` for the eval).
No `templates` input is added — the harness uses relative imports +
the root flake's existing `disko`, keeping the lock lean.

## Entry points

```bash
just test-config   # nix build the 4 config-* checks, --no-link
```

Scoped to the config-eval checks only (fast, focused) by naming the
attrs explicitly rather than `nix flake check` (which would also
build the TUI package + website checks). A future Forgejo Actions
job runs the same recipe. `nix flake check` remains the separate,
heavier "everything" gate.

## Acceptance / self-test

The gate is only useful if it actually bites:

1. `just test-config` → all 4 pass on the current tree.
2. Temporarily break a module against unstable — e.g. reference a
   removed package or a renamed option in a `templates/modules/`
   file — run `just test-config`, confirm the `-unstable` checks
   fail (and, if the break is channel-independent, the `-stable`
   ones too) with a legible Nix eval error. Revert.
3. `just test` / `just analyze` / `just format` stay green
   (this change is Nix-only + a justfile recipe; no Dart touched).

## Risks / things to verify during implementation

- **hardware-configuration stub completeness** — `config.system.
build.toplevel` forces `config.assertions`, which include "set a
  root filesystem" / "set a boot loader." If disko (pulled via
  `templates.nixosModules.default`) already supplies `fileSystems`
  - a boot device, the stub can be `{...}: {}`; otherwise it needs
    minimal `fileSystems."/"` + `boot.loader` entries. Settle by
    running the eval and reading the assertion error. This is the one
    genuinely empirical step.
- **`specialArgs = { nixblitz = self; }`** — `installed.nix` consumes
  the `nixblitz` specialArg. `self` (the root flake) _is_ nixblitz_ng,
  so it should match what templates' own `nixblitz` input resolves
  to. Verify `installed.nix` doesn't reach for a flake output the
  local `self` lacks.
- **IFD under `nix flake check`** — the profile-merge is an
  import-from-derivation. Allowed by default; flagged here so a
  future `--no-allow-import-from-derivation` CI flag doesn't
  silently break the checks.
- **disko under a foreign nixpkgs** — the harness uses the root
  flake's `disko` (pinned to stable nixpkgs) even when evaluating
  the unstable config. The disko _module_ is option-tree code
  (nixpkgs-agnostic); only confirm eval doesn't trip on a disko
  package reference under unstable. Low risk at eval tier.
- **unstable churn** — `nixos-unstable` moves daily; a red unstable
  check may reflect a transient upstream breakage, not our bug. That's
  acceptable signal (it's exactly "the config doesn't work against
  unstable right now"); the operator decides whether to chase it.

## Out of scope

- Build + VM-boot tiers (designed-for, deferred — see Layer 3).
- Plugin-combination matrix (#26's other axis).
- Pi 5 channel matrix.
- TUI-driving operator-simulation tests (#26 tier 3).
- Auto-bumping nixpkgs / channel-tracking config. This verifies
  compatibility; it does not change which channel the node uses.
