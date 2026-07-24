# True Offline Installer Implementation Plan (#46)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the installer ISO's `disko-install` run fully offline — flake eval resolves path-locked inputs from the baked store, the built closure is the one the install-time eval produces, and the installed node pins its input sources for offline rebuilds.

**Architecture:** One nix expression (`nix/offline-inputs.nix`) is the single source of truth mapping the templates flake's lock-node graph → root-flake input store paths. It feeds (a) an offline `flake.lock` generator (clan-core's `--override-input` recipe), (b) a reworked `nix/installer-system.nix` that evaluates **through the templates flake's own `outputs` function**, and (c) the ISO's `storeContents`. A templates module pins input sources into every generation's closure. `ScaffoldService` copies the ISO-delivered lock into the scaffold; `install_view` drops the broken `nix flake update` step.

**Tech Stack:** Nix (flakes, `nix flake lock --override-input`, `closureInfo`, IFD for the fixture dir), Dart (`common` ScaffoldService + `tui` install_view), just/nushell, QEMU.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-24-offline-installer-design.md`. Branch `feat/offline-installer` (stacked on `feat/install-progress-panel`); spec is the branch-base commit — Task 1 does NOT re-commit it. Do NOT merge; the network-off VM install is the acceptance gate.
- jj colocated repo — controller commits via jj after each task review (`jj new` before each implementer); implementers/fixers edit+test+report only, NO commits. Trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Version semantics:** install produces the ISO-pinned nixblitz (`nixblitz` input → baked `self`, dirty trees included). The `nix flake update nixblitz` install step is REMOVED (closes #47).
- **The A==B keystone:** the lock generator and the baked-closure eval MUST consume the same input mapping (`nix/offline-inputs.nix`). Never duplicate the mapping.
- Reference implementation (read, don't copy blindly): clan-core at `/home/f44/dev/stuff/clan-core` — offline lock recipe `checks/flash/flake-module.nix:99-125`, closureInfo rootPaths `:127-165`, retention trick `:187`, hardening `:189-198`, pure lock rewrite `lib/flakes.nix` (`mkOfflineFlakeLock`, note the `lastModified = 0` nixpkgs gotcha).
- Substituters stay configured (network-optional); hardening = `flake-registry = ""` + `connect-timeout` only.
- Flake-input rules from CLAUDE.md apply (no new inputs; `templates/flake.nix`'s deliberate non-follows for `nixos-raspberrypi` is untouched).
- After any `templates/` change: `just gen-templates` and commit the regenerated `embedded_templates.g.dart` (drift guard enforces).
- Expensive builds (full ISO) are NOT run inside tasks — tasks verify via `nix eval …drvPath` (forces full eval, no build) and small `nix build` of the lock derivation only. Full ISO build + offline VM install is the user's manual acceptance run.
- The templates lock-node graph (from the observed install log + `templates/flake.lock`): direct inputs `nixpkgs` (follows `nixos-raspberrypi/nixpkgs`), `disko` (+`disko/nixpkgs` follows), `nixblitz` (+ transitive `nixblitz/{disko, flake-utils, flake-utils/systems, nix-filter, nixos-raspberrypi (+its own tree), nixpkgs (follows), nixpkgs-unstable, nixpkgs-vanilla-unstable}`), `nixos-raspberrypi` (+ `argononed`, `flake-compat`, `nixos-images` (+follows), `nixpkgs`). Every non-follows node needs a path override; the sandboxed (network-less) lock derivation makes a missed override a **visible build failure**, not a silent network fetch.

---

## File Structure

**Create:**

- `nix/offline-inputs.nix` — pure fn: root-flake inputs → `{ templatesInputs, overrideFlags, sourcePaths }`.
- `nix/offline-flake-lock.nix` — runCommand producing the path-locked `flake.lock`.
- `templates/modules/system/pin-flake-sources.nix` — pins input sources into the system closure.

**Modify:**

- `nix/installer-system.nix` — rework to templates-outputs eval (fixture flake dir + fix-point).
- `nix/pi5-installer-system.nix` — same rework, pi5 fixture.
- `nix/iso.nix`, `nix/pi5-image.nix` — bake sources + deliver the lock at `/etc/nixblitz/offline-flake.lock` + nix-settings hardening.
- `flake.nix` — plumb `offline-inputs`/lock into both image outputs.
- `templates/flake.nix` — pass `flakeInputs` via `specialArgs` (all four `nixosSystem` calls).
- `common/lib/src/services/scaffold_service.dart` + test — copy the offline lock when present.
- `common/lib/src/services/embedded_templates.g.dart` — regenerated.
- `tui/lib/src/ui/views/install_view.dart` — remove the `nix flake update nixblitz` block.
- `justfile` — `vm-boot-offline` recipe.
- `docs/releasing-installer-images.md` — short offline section.

---

## Task 1: Offline input mapping + lock generator

**Files:**

- Create: `nix/offline-inputs.nix`, `nix/offline-flake-lock.nix`
- Modify: `flake.nix` (expose a debug output `packages.x86_64-linux.offline-flake-lock` for testing)

**Interfaces (produces):**

```nix
# nix/offline-inputs.nix
{ self, nixos-raspberrypi, disko }: rec {
  # The exact input set the templates flake's outputs fn receives —
  # and that the lock resolves to. ONE definition, used by the lock
  # generator AND installer-system.nix.
  templatesInputs = {
    nixpkgs = nixos-raspberrypi.inputs.nixpkgs;  # templates follows nvmd's nixpkgs
    inherit disko nixos-raspberrypi;
    nixblitz = self;
  };
  # [ { name = "nixblitz"; path = self; } … ] — every non-follows lock node.
  overrides = [
    { name = "nixpkgs";                          path = nixos-raspberrypi.inputs.nixpkgs; }
    { name = "disko";                            path = disko; }
    { name = "nixos-raspberrypi";                path = nixos-raspberrypi; }
    { name = "nixos-raspberrypi/argononed";      path = nixos-raspberrypi.inputs.argononed; }
    { name = "nixos-raspberrypi/flake-compat";   path = nixos-raspberrypi.inputs.flake-compat; }
    { name = "nixos-raspberrypi/nixos-images";   path = nixos-raspberrypi.inputs.nixos-images; }
    { name = "nixos-raspberrypi/nixpkgs";        path = nixos-raspberrypi.inputs.nixpkgs; }
    { name = "nixblitz";                         path = self; }
    { name = "nixblitz/disko";                   path = self.inputs.disko; }
    { name = "nixblitz/flake-utils";             path = self.inputs.flake-utils; }
    { name = "nixblitz/flake-utils/systems";     path = self.inputs.flake-utils.inputs.systems; }
    { name = "nixblitz/nix-filter";              path = self.inputs.nix-filter; }
    { name = "nixblitz/nixos-raspberrypi";       path = self.inputs.nixos-raspberrypi; }
    # + nixblitz/nixos-raspberrypi's transitive nodes (argononed, flake-compat,
    #   nixos-images, nixpkgs) via self.inputs.nixos-raspberrypi.inputs.*
    { name = "nixblitz/nixpkgs-unstable";        path = self.inputs.nixpkgs-unstable; }
    { name = "nixblitz/nixpkgs-vanilla-unstable"; path = self.inputs.nixpkgs-vanilla-unstable; }
  ];
  sourcePaths = lib.unique (map (o: o.path.outPath or o.path) overrides);
}
```

_(Implementer: derive the authoritative override list from `templates/flake.lock`'s node graph + the root flake's `inputs` — verify each `self.inputs.X` name against root `flake.nix`'s outputs args. Follows-edges need no override.)_

```nix
# nix/offline-flake-lock.nix — clan checks/flash/flake-module.nix:99-125 pattern
{ pkgs, offlineInputs }:
pkgs.runCommand "nixblitz-offline-flake.lock" {
  nativeBuildInputs = [ pkgs.nix ];
} ''
  export HOME=$TMPDIR
  mkdir flake && cp ${../templates/flake.nix} flake/flake.nix
  nix flake lock ./flake \
    --extra-experimental-features 'nix-command flakes' \
    --flake-registry "" \
    --store "$TMPDIR/store" \
    ${lib.concatMapStringsSep " \\\n    "
        (o: "--override-input ${o.name} ${o.path}") offlineInputs.overrides}
  cp flake/flake.lock $out
''
```

_(The build sandbox has no network — a missed override fails the build loudly. If `nix flake lock` inside the sandbox needs adjustments (store flags, `NIX_STATE_DIR`), mirror what makes clan's flash check work; that file is the proven reference.)_

- [ ] **Step 1:** Write both files; wire a debug package output in `flake.nix`:
      `packages.x86_64-linux.offline-flake-lock = import ./nix/offline-flake-lock.nix { pkgs = …; offlineInputs = import ./nix/offline-inputs.nix { inherit self nixos-raspberrypi disko; }; };`
- [ ] **Step 2 (RED→GREEN):** `nix build .#offline-flake-lock` — must succeed **without network** (sandbox enforces). Then assert every node is path-locked:
      `nix build .#offline-flake-lock && python3 -c "import json;d=json.load(open('result'));nodes=d['nodes'];bad=[k for k,v in nodes.items() if k!='root' and isinstance(v.get('locked'),dict) and v['locked'].get('type') not in ('path',)];print('non-path nodes:',bad);exit(1 if bad else 0)"`
      Expected: `non-path nodes: []`.
- [ ] **Step 3:** `nix flake check --no-build` (or `nix eval .#packages.x86_64-linux.offline-flake-lock.drvPath`) still evaluates.
- [ ] **Step 4:** Report + controller commits:
      `feat(nix): offline input mapping + path-locked flake.lock generator (#46)`

---

## Task 2: installer-system.nix → templates-outputs eval (closure B)

**Files:**

- Modify: `nix/installer-system.nix`
- Modify: `flake.nix` (pass `offlineInputs`; expose `packages.x86_64-linux.installer-toplevel` debug output)

**Interfaces:**

- Consumes: `offlineInputs.templatesInputs` (Task 1).
- Produces: `{ toplevel, diskoScript }` (was: bare toplevel — update `flake.nix`/`nix/iso.nix` call sites accordingly, iso.nix fully in Task 3).

**Design:** Assemble a **fixture flake dir** (full `templates/` tree + fixture `config.json` with `initialized = false`, platform `x86`, empty `disk_device` — reuse today's fixture JSON) as a runCommand, then evaluate the templates flake's own outputs via fix-point (this is IFD — acceptable, forced only when building image outputs):

```nix
{ self, nixos-raspberrypi, disko, system }:
let
  offlineInputs = import ./offline-inputs.nix { inherit self nixos-raspberrypi disko; };
  inherit (offlineInputs.templatesInputs) nixpkgs;
  pkgs = nixpkgs.legacyPackages.${system};
  installerConfig = <today's fixture attrset> // { initialized = false; };
  fixtureDir = pkgs.runCommand "nixblitz-installer-fixture" {} ''
    mkdir -p $out
    cp -r ${../templates}/. $out/
    cp ${pkgs.writeText "config.json" (builtins.toJSON installerConfig)} $out/config.json
  '';
  templatesFlake = import (fixtureDir + "/flake.nix");
  outputs = let
    result = templatesFlake.outputs (offlineInputs.templatesInputs // {
      self = result // { outPath = fixtureDir; };
    });
  in result;
  installerSystem = outputs.nixosConfigurations.nixblitz-installer;
in {
  toplevel   = installerSystem.config.system.build.toplevel;
  diskoScript = installerSystem.config.system.build.diskoScript;
}
```

_(Keep today's fixture semantics: same config.json fields, `initialized = false`. Delete the now-dead duplicated `findModules`/profile assembly. If `nixosConfigurations` selection needs the hostname alias skipped, use the canonical attr directly as shown. If `hardware-configuration.nix` is referenced by `installer.nix`, include today's empty fixture file in `fixtureDir`.)_

- [ ] **Step 1:** Rework the file per above; update `flake.nix`'s `installer-iso` wiring minimally so eval still works (`installerClosure = (import ./nix/installer-system.nix { … }).toplevel;` for now).
- [ ] **Step 2 (verify):** `nix eval .#packages.x86_64-linux.installer-toplevel.drvPath` succeeds (full eval through the templates outputs fn, no build). `nix eval .#packages.x86_64-linux.installer-iso.drvPath` still evaluates.
- [ ] **Step 3:** Report + controller commits:
      `refactor(nix): bake the closure the install-time eval produces (#46)`

---

## Task 3: Source pinning in templates + regen

**Files:**

- Create: `templates/modules/system/pin-flake-sources.nix`
- Modify: `templates/flake.nix` (all four `nixosSystem` calls gain `flakeInputs` in `specialArgs`)
- Regenerate: `common/lib/src/services/embedded_templates.g.dart` (`just gen-templates`)

```nix
# templates/modules/system/pin-flake-sources.nix
# Pin the flake input SOURCE trees into the system closure so the
# path-locked flake.lock written by the offline installer keeps
# resolving forever: disko-install copies these to the target, each
# generation pins the sources it was built from, GC frees old ones
# with old generations. ~250-300 MB. See the offline-installer spec §4.3.
{ lib, flakeInputs ? null, ... }: {
  config = lib.mkIf (flakeInputs != null) {
    environment.etc."nixblitz/flake-inputs".text =
      lib.concatMapStrings (p: "${p}\n") (lib.attrValues flakeInputs);
  };
}
```

In `templates/flake.nix`, next to each `specialArgs = {inherit nixblitz;…}`:

```nix
specialArgs = {
  inherit nixblitz;
  flakeInputs = {
    inherit nixpkgs disko nixos-raspberrypi nixblitz;
    # forced transitively by base.nix's nixblitz.packages access:
    nixblitz-nixpkgs-unstable = nixblitz.inputs.nixpkgs-unstable;
  };
};
```

_(`flakeInputs ? null` default keeps the module inert for any eval path that doesn't pass it. pi5 calls keep their existing `nixos-raspberrypi` specialArg too.)_

- [ ] **Step 1:** Add module + specialArgs; `just gen-templates`.
- [ ] **Step 2 (verify):** `nix eval .#packages.x86_64-linux.installer-toplevel.drvPath` re-evaluates (now includes the pin). `just test` green (drift guard passes with the regen).
- [ ] **Step 3:** Report + controller commits:
      `feat(templates): pin flake input sources into every generation (#46)`

---

## Task 4: ISO wiring — lock delivery, baked sources, hardening

**Files:**

- Modify: `nix/iso.nix`, `flake.nix`

In `nix/iso.nix` (new args `offlineLock`, `offlineSourcePaths`, `installerDiskoScript`):

```nix
environment.etc."nixblitz/offline-flake.lock".source = offlineLock;
isoImage.storeContents = [ installerClosure installerDiskoScript ] ++ offlineSourcePaths;
nix.settings = {
  flake-registry = "";
  connect-timeout = 3;
  # substituters deliberately NOT cleared — network stays a fallback.
};
```

`flake.nix` threads `offlineInputs`/lock/`diskoScript` through (single `let` computing `offlineInputs` once, shared by lock + installer-system + iso args).

- [ ] **Step 1:** Wire it.
- [ ] **Step 2 (verify):** `nix eval .#packages.x86_64-linux.installer-iso.drvPath` — full eval green. Grep the eval'd iso module args to confirm the etc path (`nix eval` of the iso config's `environment.etc."nixblitz/offline-flake.lock".source` matches the lock drv).
- [ ] **Step 3:** Report + controller commits:
      `feat(nix): deliver offline lock + bake input sources into the ISO (#46)`

---

## Task 5: Dart — scaffold lock copy + install_view cleanup

**Files:**

- Modify: `common/lib/src/services/scaffold_service.dart`
- Test: `common/test/services/scaffold_service_test.dart` (extend; create if absent)
- Modify: `tui/lib/src/ui/views/install_view.dart`

**Scaffold seam:** after the templates are written, copy the ISO-delivered lock when present:

```dart
/// Default on-disk location of the installer ISO's offline flake.lock.
static const kOfflineLockPath = '/etc/nixblitz/offline-flake.lock';

/// After scaffolding, copy the offline lock (present only on installer
/// media) so the first eval resolves path-locked inputs offline.
/// [offlineLockPath] is injectable for tests. Missing file → no-op.
void copyOfflineLockIfPresent(String baseDir,
    {String offlineLockPath = kOfflineLockPath}) {
  try {
    final src = File(offlineLockPath);
    if (!src.existsSync()) return;
    src.copySync('$baseDir/flake.lock');
    LogService.info('scaffold: offline flake.lock copied from $offlineLockPath');
  } catch (e, st) {
    LogService.error('scaffold: offline lock copy failed (continuing)', e, st);
  }
}
```

Call it from the scaffold/refresh path that `install_view`'s save-config uses (read `scaffold_service.dart` and hook the same method that writes the 14 templates). TDD: test with a temp source file → lock lands in baseDir; absent → no file, no throw.

**install_view:** delete the `nix flake update nixblitz` block (the `_appendInstallLog('> nix flake update …')`, the `runCheckedSync('nix', ['flake','update','nixblitz'] …)` call, and the `updateOutput` log lines — keep the surrounding disko-install echo). Closes #47.

- [ ] **Step 1 (TDD):** failing scaffold test → seam → green.
- [ ] **Step 2:** Remove the install_view block. `just test` + `just analyze` + `just format` (only the 6 pre-existing tui infos).
- [ ] **Step 3:** Report + controller commits:
      `feat(common): scaffold the ISO's offline flake.lock; drop broken flake-update step (#46, #47)`

---

## Task 6: Pi 5 mirror

**Files:**

- Modify: `nix/pi5-installer-system.nix` (templates-outputs eval, pi5 fixture: `platform = "pi5"`, `nixosConfigurations.nixblitz-pi5-installer`), `nix/pi5-image.nix` (same three additions as iso.nix, via `sdImage.storePaths` + `environment.etc`), `flake.nix` (aarch64 wiring shares the same `offlineInputs`).

- [ ] **Step 1:** Mirror Tasks 2+4 for pi5. No new mapping — same `offline-inputs.nix`.
- [ ] **Step 2 (verify):** `nix eval .#packages.aarch64-linux.pi5-installer-image.drvPath` on x86 — expected to progress to the known aarch64 IFD "platform mismatch" boundary (same limitation as when the pi5 image was first added; reaching it = eval wiring correct). Note it explicitly in the report.
- [ ] **Step 3:** Report + controller commits:
      `feat(nix): offline install wiring for the Pi 5 image (#46)`

---

## Task 7: Offline VM recipe + docs

**Files:**

- Modify: `justfile` (add `vm-boot-offline` next to `vm-boot`: identical qemu invocation but network replaced with `-nic none`; same disk-image creation), `docs/releasing-installer-images.md` (short "Offline behavior" section: what's baked, the `-nic none` acceptance test, ISO size note ~+400-500 MB for sources).

- [ ] **Step 1:** Add recipe + docs. `just --list` shows it; `just format` clean.
- [ ] **Step 2:** Report + controller commits:
      `feat(just): vm-boot-offline acceptance recipe + offline docs (#46)`

---

## Manual acceptance (user, after all tasks)

1. `just iso-build` (expect ~+400-500 MB from baked sources; first build re-evaluates a lot — subsequent cheap).
2. `just vm-clean && just vm-boot-offline` → wizard → install a blank disk **with zero network**: must complete; progress bar rises through the real copy phase; log shows NO `copying path … from https://…` and NO `Added input` fetches.
3. Boot installed VM offline: `nix flake metadata ~/nixblitz` resolves (path-locked, pinned sources).
4. Reconnect network (`just vm-run`) → first-boot service build downloads only service packages; normal update flow still re-locks from the forge.
5. Online `just vm-boot` still installs (regression).
6. RAM: observe install on the 8 GB VM stays comfortable (no zram pressure).

## Self-Review

**Spec coverage:** §4.1 lock → T1 + T4 (delivery) + T5 (scaffold copy). §4.2 closure B → T2 (+ pi5 T6). §4.3 pinning → T3. §4.4 hardening + #47 removal → T4 + T5. §4.5 pi5 → T6. §7 verification → per-task evals + T7 recipe + Manual acceptance. §6 degradation → T5 no-op seam, substituters kept (T4).
**Placeholder scan:** the two "implementer derives/verifies" notes (override list from `templates/flake.lock`; clan file as proven reference for nix-in-sandbox flags) are concrete instructions with named sources, not TBDs. Fixture attrset marked `<today's fixture attrset>` intentionally — it's copied verbatim from the current `installer-system.nix`, which Task 2's implementer has open.
**Type consistency:** `offlineInputs.{templatesInputs, overrides, sourcePaths}` used identically in T1/T2/T4/T6; `{toplevel, diskoScript}` return shape consumed by T4; `copyOfflineLockIfPresent(baseDir, {offlineLockPath})` matches the T5 test.
