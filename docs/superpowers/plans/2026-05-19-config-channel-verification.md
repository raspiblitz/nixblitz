# Config Channel Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the base x86 nixblitz node config evaluates cleanly against nixpkgs stable + vanilla unstable, so option renames / removed packages are caught before an operator's rebuild.

**Architecture:** A new `tests/config/default.nix` builds the node config for each (host × channel) via a shared `mkNodeConfig`, forces full module eval via `.config.system.build.toplevel.drvPath` inside a trivial `runCommand` (eval-gate, no build), and exposes the four results as `checks.x86_64-linux.config-*` in the root flake. The host module's `../config.json` + `../hardware-configuration.nix` sibling reads are satisfied by a tiny committed fixture merged onto the templates `hosts/` via IFD. Module set comes from a relative `findModules templates/modules` walk + the root flake's existing `disko` (no new heavy flake inputs).

**Tech Stack:** Nix flakes, `nixpkgs.lib.nixosSystem`, `nix flake check`, just (nushell recipes).

**Spec:** `docs/superpowers/specs/2026-05-19-config-channel-verification-design.md`

---

### Task 1: Fixture profile files

**Files:**

- Create: `tests/config/fixtures/base/config.json`
- Create: `tests/config/fixtures/base/hardware-configuration.nix`

- [ ] **Step 1: Write the fixture config.json**

Schema-v18 minimal x86 profile. `initialized: true` so the service-
wiring modules actually evaluate (more drift coverage than the
bootstrap `false` path); `app_configs: {}` keeps it base (no
plugins). `platform: "x86"` makes `installed.nix` enable `disko-x86`.

`tests/config/fixtures/base/config.json`:

```json
{
  "schema_version": 18,
  "min_compatible_version": 1,
  "initialized": true,
  "setup_step_completed": "summary",
  "system": {
    "hostname": "nixblitz",
    "timezone": "UTC",
    "platform": "x86",
    "disk_device": "/dev/vda",
    "shell": "bash"
  },
  "app_configs": {}
}
```

- [ ] **Step 2: Write the fixture hardware-configuration.nix stub**

The host module imports this unconditionally. It can be empty:
`disko-x86` (enabled by `installed.nix` for platform x86) generates
`fileSystems` + sets `boot.loader.grub`, so no fs/boot stub is
needed — the file only has to exist.

`tests/config/fixtures/base/hardware-configuration.nix`:

```nix
# Test fixture — stands in for the `nixos-generate-config` output
# that install writes to ~/nixblitz/. The host module imports it
# unconditionally; for an eval-only config check it can be empty,
# because disko (enabled by installed.nix for platform x86)
# generates fileSystems + sets boot.loader.grub. See
# docs/superpowers/specs/2026-05-19-config-channel-verification-design.md.
{...}: {}
```

- [ ] **Step 3: Commit**

```bash
git add tests/config/fixtures/base/config.json \
        tests/config/fixtures/base/hardware-configuration.nix
git commit -m "$(cat <<'EOF'
test(config): add base x86 fixture profile for channel verification

Schema-v18 config.json (initialized, no plugins) + an empty
hardware-configuration.nix stub. These are the two sibling files
templates/hosts/installed.nix reads unconditionally; committing
them lets the config-eval harness merge a populated profile.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The eval harness

**Files:**

- Create: `tests/config/default.nix`

- [ ] **Step 1: Write the harness**

Layers 1-3 + a local `findModules` (the same ~12-line walk
`templates/flake.nix` uses, duplicated to keep the root lock free
of the templates input closure).

`tests/config/default.nix`:

```nix
# Config channel verification — eval tier.
# See docs/superpowers/specs/2026-05-19-config-channel-verification-design.md
#
# Returns a `checks`-shaped attrset (one eval-gate per host ×
# channel) for the root flake to expose under checks.x86_64-linux.
{
  self,
  lib,
  nixpkgs,
  nixpkgs-vanilla-unstable,
  disko,
  system ? "x86_64-linux",
}: let
  pkgs = nixpkgs.legacyPackages.${system};

  excludedFiles = ["package.nix" "flake.nix"];

  # Same directory walk templates/flake.nix uses to collect its
  # module set. Duplicated (not imported as a flake input) to keep
  # the root flake's lock free of templates' closure
  # (nixos-raspberrypi + a remote nixblitz fetch).
  findModules = dir: let
    entries = builtins.readDir dir;
    processEntry = name: type: let
      path = dir + "/${name}";
    in
      if type == "directory"
      then findModules path
      else if type == "regular"
        && lib.hasSuffix ".nix" name
        && !builtins.elem name excludedFiles
      then [path]
      else [];
  in
    lib.concatLists (lib.mapAttrsToList processEntry entries);

  # installed.nix reads `../config.json` and imports
  # `../hardware-configuration.nix` (both generated at install,
  # absent from source). Merge the committed fixture onto a fresh
  # copy of the host modules so those sibling reads resolve. IFD:
  # this derivation builds before the config evaluates.
  profile = pkgs.runCommand "nixblitz-test-profile" {} ''
    mkdir -p $out/hosts
    cp ${../../templates/hosts/installed.nix} $out/hosts/installed.nix
    cp ${../../templates/hosts/installer.nix} $out/hosts/installer.nix
    cp ${./fixtures/base/config.json} $out/config.json
    cp ${./fixtures/base/hardware-configuration.nix} $out/hardware-configuration.nix
  '';

  # Layer 1 — build a node config for a channel + host.
  mkNodeConfig = {channelPkgs, hostName}:
    channelPkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {nixblitz = self;};
      modules =
        (findModules ../../templates/modules)
        ++ [
          (profile + "/hosts/${hostName}.nix")
          disko.nixosModules.default
        ];
    };

  # Layer 2 — matrix (channels × hosts), defined once.
  channels = {
    stable = nixpkgs;
    unstable = nixpkgs-vanilla-unstable;
  };
  hostNames = ["installed" "installer"];

  matrix = lib.listToAttrs (
    lib.concatMap (
      hostName:
        map (channelName: {
          name = "${hostName}-${channelName}";
          value = mkNodeConfig {
            channelPkgs = channels.${channelName};
            inherit hostName;
          };
        }) (lib.attrNames channels)
    )
    hostNames
  );

  # Layer 3 — eval-gate tier applier. Referencing .drvPath forces
  # full module evaluation without realizing the system; an eval
  # error (renamed option / removed package) means this runCommand
  # can't be produced and `nix flake check` fails.
  #
  # Future tiers slot in here additively: a buildGate returning
  # `cfg.config.system.build.toplevel`, a bootGate returning
  # `pkgs.nixosTest {...}`, each mapped over the SAME `matrix`.
  evalGate = name: cfg:
    pkgs.runCommand "config-eval-${name}" {} ''
      echo ${cfg.config.system.build.toplevel.drvPath} > $out
    '';
in
  lib.mapAttrs' (
    name: cfg: lib.nameValuePair "config-${name}" (evalGate name cfg)
  )
  matrix
```

- [ ] **Step 2: Format**

Run: `alejandra tests/config/default.nix tests/config/fixtures/base/hardware-configuration.nix`
Expected: `1 file reformatted, ...` or already-formatted; no errors.

- [ ] **Step 3: Commit**

```bash
git add tests/config/default.nix
git commit -m "$(cat <<'EOF'
test(config): add eval-gate harness for the channel matrix

Three layers: mkNodeConfig builds a node config for a channel +
host, a channels×hosts matrix instantiates it, and an evalGate
forces full module eval via toplevel.drvPath without building.
Module set via relative findModules over templates/modules + the
root flake's disko; host module via an IFD profile merge. Not
wired into the flake yet (next task).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire into the root flake + first eval

**Files:**

- Modify: `flake.nix` (add input, output arg, `checks`)

- [ ] **Step 1: Add the vanilla-unstable input**

In `flake.nix`, inside `inputs = { … }`, after the
`nixpkgs-unstable` block (around line 12):

```nix
    # Vanilla nixos-unstable, used ONLY by the config-channel
    # verification checks (tests/config) to eval the node config
    # against unstable. Distinct from nixpkgs-unstable above (the
    # dart-workspace-member-filter fork, for the TUI build). No
    # follows — it only supplies lib.nixosSystem for the eval.
    nixpkgs-vanilla-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
```

- [ ] **Step 2: Add the output argument**

In `flake.nix`, in the `outputs = { … }:` destructure (around line
25-33), add `nixpkgs-vanilla-unstable,` after `nixpkgs-unstable,`:

```nix
  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    nixpkgs-vanilla-unstable,
    flake-utils,
    nix-filter,
    disko,
    ...
  }:
```

- [ ] **Step 3: Add `lib` to the per-system let-block + wire `checks`**

In the `eachDefaultSystem` let-block (around line 35-37), after
`pkgs = nixpkgs.legacyPackages.${system};`, add:

```nix
        lib = nixpkgs.lib;
```

Then in the returned attrset (the `in { packages = …; apps… }`
block, after `apps.default = { … };` around line 101), add:

```nix
        # Config-channel verification (eval tier). x86_64-linux
        # only — Pi 5 configs are locked to nvmd's nixpkgs by
        # design, so varying their channel is meaningless. See
        # tests/config/default.nix.
        checks = lib.optionalAttrs (system == "x86_64-linux") (
          import ./tests/config {
            inherit self lib nixpkgs nixpkgs-vanilla-unstable disko system;
          }
        );
```

- [ ] **Step 4: Lock the new input**

Run: `nix flake lock`
Expected: adds `nixpkgs-vanilla-unstable` to `flake.lock`; no errors.

- [ ] **Step 5: Evaluate the stable installed check first**

Run: `nix build --no-link .#checks.x86_64-linux.config-installed-stable`
Expected: builds successfully (the eval-gate `runCommand` produces
its `$out`). If it fails, read the error:

- `path '…/config.json' does not exist` → fixture not copied; check
  the `profile` `cp` paths in Task 2.
- `The option `…` does not exist` → a genuine config/module bug
  (or a real stable-channel drift) — fix the offending module.
- `attribute 'nixosSystem' missing` → input wiring wrong; recheck
  Step 2-3.

- [ ] **Step 6: Evaluate the full matrix**

Run:

```bash
nix build --no-link \
  .#checks.x86_64-linux.config-installed-stable \
  .#checks.x86_64-linux.config-installed-unstable \
  .#checks.x86_64-linux.config-installer-stable \
  .#checks.x86_64-linux.config-installer-unstable
```

Expected: all four succeed. A red `-unstable` check that's NOT a
fixture/wiring error is a real finding — the config doesn't eval
against unstable right now; capture the option/package at fault and
decide whether to fix the module or note it.

- [ ] **Step 7: Format + commit**

Run: `just format` (alejandra picks up flake.nix)

```bash
git add flake.nix flake.lock
git commit -m "$(cat <<'EOF'
feat(flake): config-channel verification checks (eval tier)

Adds checks.x86_64-linux.config-{installed,installer}-{stable,
unstable}: four eval-gates that force the base node config to
evaluate against nixpkgs stable (25.11) + vanilla unstable,
catching option renames / removed packages before an operator's
rebuild. New input nixpkgs-vanilla-unstable (eval-only, no
follows). Pi 5 excluded — locked to nvmd's nixpkgs by design.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `just test-config` recipe

**Files:**

- Modify: `justfile` (add recipe near the other gen/test recipes)

- [ ] **Step 1: Add the recipe**

In `justfile`, after the `check-plugin-consistency` recipe (around
line 33), add:

```just
# Verify the base node config evaluates against nixpkgs stable +
# unstable (eval tier — no building). See
# docs/superpowers/specs/2026-05-19-config-channel-verification-design.md
test-config:
  #!/usr/bin/env nu
  nix build --no-link .#checks.x86_64-linux.config-installed-stable .#checks.x86_64-linux.config-installed-unstable .#checks.x86_64-linux.config-installer-stable .#checks.x86_64-linux.config-installer-unstable
  print "config eval matrix (stable + unstable): all green"
```

- [ ] **Step 2: Run it**

Run: `just test-config`
Expected: nix build succeeds, prints `config eval matrix (stable + unstable): all green`.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "$(cat <<'EOF'
feat(just): add test-config recipe for the channel eval matrix

Wraps the four config-* flake checks in one command. Scoped to
the config checks (not `nix flake check`, which would also build
the TUI package + website). Future Forgejo Actions calls the
same recipe.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Prove the gate bites (self-test) + docs

**Files:**

- Temporary edit (reverted): `tests/config/fixtures/base/hardware-configuration.nix`
- Modify: `docs/dev-loop.md` (document `just test-config`)

- [ ] **Step 1: Introduce a deliberate eval break**

Temporarily edit `tests/config/fixtures/base/hardware-configuration.nix` to reference a non-existent option:

```nix
{...}: {
  boot.loader.grub.thisOptionDoesNotExist = true;
}
```

- [ ] **Step 2: Confirm the gate fails**

Run: `just test-config`
Expected: FAILS with `The option `boot.loader.grub.thisOptionDoesNotExist' does not exist`. Both stable and unstable checks fail (channel-independent break) — proving the eval-gate actually evaluates the option tree. (A channel-_specific_ break — an option present in stable but gone in unstable — is the real-world trigger; this break just proves the mechanism.)

- [ ] **Step 3: Revert the break**

```bash
git checkout tests/config/fixtures/base/hardware-configuration.nix
```

Run: `just test-config`
Expected: back to all-green.

- [ ] **Step 4: Document the recipe in dev-loop.md**

In `docs/dev-loop.md`, after the "Tab completion" section (or near
the other `just` test recipes), add:

````markdown
## Config channel verification

`just test-config` evaluates the base x86 node config against
nixpkgs stable (25.11) + vanilla unstable, catching option
renames / removed packages before they reach an operator's
rebuild. Eval-only (no building); seconds-to-minutes.

```bash
just test-config   # → all four config-* checks, stable + unstable
```
````

It's the eval tier of the #26 testing strategy. Build + VM-boot
tiers and the config-combination matrix are designed-for but not
yet implemented — see
docs/superpowers/specs/2026-05-19-config-channel-verification-design.md.
A red `-unstable` check may reflect transient upstream churn
rather than our bug; that's expected signal.

````

- [ ] **Step 5: Commit**

```bash
git add docs/dev-loop.md
git commit -m "$(cat <<'EOF'
docs: document just test-config (config channel verification)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
````

---

## Final verification

- [ ] `just test-config` → all four checks green.
- [ ] `just test` → unchanged (common dart tests + plugin consistency still pass; this change touches no Dart).
- [ ] `just analyze` → unchanged (no Dart touched).
- [ ] `just format` → clean (alejandra over the new `.nix` files + flake.nix).
- [ ] `git status` → clean; the self-test break from Task 5 is reverted.
- [ ] `flake.lock` contains `nixpkgs-vanilla-unstable`; root flake gained no other inputs (no `templates`, no `nixos-raspberrypi`).
