# True Offline Installer — Design (#46)

**Status:** Approved design, ready for implementation planning.
**Date:** 2026-07-24
**Closes:** #46 (installer not offline), #47 (broken `nix flake update` step — removed by this design).

---

## 1. Purpose

Make the installer ISO's install **genuinely offline**: everything `disko-install`
needs — flake input sources, evaluated derivations, the built system closure —
comes from the ISO medium, never the network.

Why this matters (in priority order):

1. **RAM.** The live ISO's writable store (`/nix/.rw-store`) is tmpfs — RAM.
   Today's install downloads (and, for the TUI, _compiles_) the whole system
   into RAM before copying to disk, which is what OOMs ≤8 GB machines. The
   prebuilt ISO exists precisely to avoid this; a baked closure streams
   squashfs (medium) → target disk with near-zero RAM residency.
2. **Robustness.** One transient GitHub 504 on any of ~15 flake inputs aborts
   the whole install today (observed live, 2026-07-24).
3. **UX.** With the download gone, the store copy is the dominant phase — the
   install progress panel's copy bar (the feature that surfaced this issue)
   becomes meaningful from the start.

### Version semantics (decided)

An offline install produces the **ISO-pinned nixblitz** — whatever source the
ISO was built from. Freshly installed nodes move to newer versions through the
normal (online) update flow. This is the point of a prebuilt installer; the
current "fetch latest main at install time" behavior is removed.

---

## 2. Root causes (verified)

Three independent gaps, all confirmed against the live failure log and the repo:

1. **No `flake.lock` is scaffolded.** The 14 embedded templates
   (`embedded_templates.g.dart`) contain no lock. Every install re-resolves all
   inputs from the network — including querying the forge for `main`'s tip
   (`Added input 'nixblitz': git+https://forge.f44.fyi/…&rev=…` in the log).
2. **The wrong closure is baked.** `nix/installer-system.nix` builds the
   installer toplevel via its own `nixpkgs.lib.nixosSystem` call with
   `specialArgs = { nixblitz = self; }` (closure A). Install-time,
   `disko-install --flake ~/nixblitz#nixblitz-installer` evaluates the
   **scaffolded templates flake**, whose `nixblitz` input is the **remote
   forge** (closure B). A ≠ B, so nothing baked matches; nix substitutes the
   entire system from cache.nixos.org — and because the forge rev is in no
   binary cache, it was preparing to **compile the TUI from source on the
   target** (build deps `gtest`, `gnutar`, `graphite2` visible in the log).
3. **The disk choice (and generated `hardware-configuration.nix`) land in the
   closure** (`disko.devices.disk.main.device`, grub, initrd modules), so one
   pre-baked toplevel cannot byte-identically serve every machine. Mitigation,
   not blocker: closures for different disks/hardware share ~99% of store paths
   by bytes; the deltas are small local derivations (fstab, grub config,
   initrd, toplevel script) that rebuild offline in seconds against a warm
   store.

---

## 3. Prior art: clan-core (studied 2026-07-24)

clan.lol's _production_ installer has the same re-eval gap, but their CI
contains a fully network-isolated `disko-install --flake` self-install —
exactly our scenario. Mechanisms adopted (file references into
`/home/f44/dev/stuff/clan-core`):

- **Path-rewritten offline `flake.lock`** — every lock node's `locked` becomes
  `{ type = "path"; path = "/nix/store/…-source"; narHash = <original>; }`,
  keeping lock integrity while resolving inputs from the local store with zero
  fetching. (`lib/flakes.nix` `mkOfflineFlakeLock`; equivalently
  `nix flake lock --override-input X <store-path>` per input,
  `checks/flash/flake-module.nix:99-125`.)
- **`closureInfo` over the exact set disko-install touches** — built installer
  toplevel + diskoScript + disko itself + **all flake input source trees**
  (`map (i: i.outPath) (attrValues inputs)`) + the `.src` tarballs of
  activation-invoked packages (a gotcha they hit)
  (`checks/flash/flake-module.nix:127-165`).
- **Store-retention via a scanned reference** — referencing a
  `closureInfo`-produced `store-paths` file from `environment.etc.*` pins
  otherwise-unreferenced paths into a system closure
  (`checks/flash/flake-module.nix:187`). We use this for target-side source
  pinning (§4.3).
- **Anti-network hardening** — `flake-registry = ""` (bare flake refs hit the
  registry even with no substituters) and a low `connect-timeout` so surprise
  fetches fail fast (`checks/flash/flake-module.nix:189-198`).

Key divergence: clan's production paths never eval on the target (an online
operator machine pushes closures over SSH). Our ISO _is_ the operator, so we
productize their CI recipe instead.

---

## 4. Design

### 4.1 Offline flake lock (fixes root cause 1)

At ISO build time, generate a `flake.lock` for the scaffolded templates flake
with every input path-locked:

- `nixblitz` → the **baked `self` source** (`self.outPath`). This works for
  dirty/unpushed trees identically to release revs — no forge round-trip. It
  also dissolves the dev-vs-release ISO distinction: every ISO is fully
  offline.
- `nixpkgs`, `disko`, `nixos-raspberrypi` (and transitive inputs) → the root
  flake's already-fetched input store paths, matching the follows-graph the
  templates flake declares.

Generation runs inside a derivation (`nix flake lock --override-input …`
against a copy of `templates/flake.nix`, clan's recipe) or via a pure
`mkOfflineFlakeLock`-style lock rewrite — implementation plan picks; the
observable contract is: **a `flake.lock` whose every node is
`type = "path"` with the original `narHash`, referencing paths present in the
ISO store.**

Delivery to the scaffold: the ISO places the generated lock at
`/etc/nixblitz/offline-flake.lock`. `ScaffoldService` (Dart), after writing
the 14 templates, copies that file to `~/nixblitz/flake.lock` **iff it
exists**. On installed systems the file doesn't exist → no behavior change.
The lock is _not_ embedded in the Dart binary (it contains ISO-build-time
store paths).

### 4.2 Bake the closure the install actually evaluates (fixes root cause 2)

`nix/installer-system.nix` stops constructing a parallel eval. Instead it
imports the templates flake's own outputs function:

```nix
templatesFlake = import ../templates/flake.nix;
outputs = templatesFlake.outputs {
  self = …stub…;
  nixpkgs = <root nixpkgs>;
  nixblitz = self;
  disko = <root disko>;
  nixos-raspberrypi = <root nixos-raspberrypi>;
};
# → outputs.nixosConfigurations.nixblitz-installer.…
```

with the same fixture profile as today (installer host + `initialized = false`
config.json). Because the on-ISO eval resolves its inputs — via the offline
lock — to the **same store paths** passed here, the derivation trees coincide:
baked == evaluated (for the fixture's disk/hardware).

`isoImage.storeContents` bakes:

- the installer toplevel + its `closureInfo`,
- the **diskoScript** for the fixture disk,
- **all flake input source trees** (the offline lock's targets),
- disko's package (the `disko-install` script's own dependencies are already
  on the ISO), and the `.src` set from clan's flash check if VM verification
  shows activation fetching sources.

Per-machine deltas (wizard-generated `hardware-configuration.nix`, non-default
disk device) re-evaluate and rebuild **locally and offline** — small text/
initrd derivations against a fully-warm store. This is stated honestly: the
guarantee is "no network, no RAM blowup, seconds of local building," not
"zero building."

### 4.3 Pin sources into the target's closure (decided)

A small module in `templates/` (e.g. `modules/system/pin-flake-sources.nix`)
writes the flake input source paths into a scanned location:

```nix
environment.etc."nixblitz/flake-inputs".text =
  lib.concatMapStrings (p: "${p}\n") (lib.attrValues flakeInputs);
```

(with `flakeInputs` passed from the templates flake's `outputs` via
`specialArgs`, `self` excluded). Consequences:

- The sources enter the **target system's closure** → `disko-install` copies
  them to the target disk automatically (~250–300 MB on a ≥30 GB disk).
- The installed node's `path:`-locked flake evaluates **offline, forever** —
  first-boot `buildServices` rebuild only downloads the new service packages;
  rollbacks and rebuilds survive forge/GitHub outages.
- Self-maintaining per generation: each generation pins the sources _it_ was
  built from; old sources are GC'd with old generations.
- **Updates are unaffected.** `flake.nix` still declares the forge URL; the
  update flow's re-lock fetches the new rev and rewrites the lock to a normal
  forge entry. Moving forward needs the network (inherently); staying put
  never does.

### 4.4 Anti-network hardening + install_view cleanup

- ISO nix settings: `flake-registry = ""`, `connect-timeout = 3`.
  **Substituters stay configured** — with everything baked they're never
  consulted on the happy path, but they remain a harmless fallback rather than
  a hard failure mode (network-optional, not network-forbidden).
- **Remove the `nix flake update nixblitz` step** from
  `install_view._startInstall` (closes #47): it contradicts ISO-pinned
  semantics, and it has never worked (missing experimental-features flags).
- The zram/tmpfs safety net (`ensureSwapForInstall`) **stays** — it's now
  rarely exercised but remains cheap insurance for the local rebuild deltas.

### 4.5 Pi 5

Same mechanism, same code shape: `nix/pi5-installer-system.nix` switches to
the templates-outputs eval with the pi5 fixture (`platform = "pi5"`),
`nix/pi5-image.nix` bakes the same artifact set via `sdImage.storePaths`, and
the pi5 image carries the same `/etc/nixblitz/offline-flake.lock`. The
`nixos-raspberrypi` input source is included in both images' source sets (the
templates flake locks it regardless of platform). x86 is VM-verified; Pi 5 is
manual-hardware verification, later.

---

## 5. Data flow (install, network cable unplugged)

```
ISO boot (squashfs store: toplevel closure + diskoScript + input sources)
  → wizard: scaffold templates + config.json + hardware-config
  → ScaffoldService copies /etc/nixblitz/offline-flake.lock → ~/nixblitz/flake.lock
  → disko-install --flake ~/nixblitz#nixblitz-installer
      eval: lock resolves all inputs to baked store paths   (no fetch)
      build: heavy paths hit the baked store; per-machine
             deltas (fstab/grub/initrd/toplevel) build locally (no fetch)
      disko: partition + mount
      copy:  xargs cp  medium → target disk                  (the bar's phase)
      nixos-install: bootloader
  → copyConfigToTarget (unchanged)
  → reboot → first-boot buildServices: eval offline (pinned sources),
             downloads only the new service packages (online step, as today)
```

---

## 6. Error handling / degradation

- Offline lock missing on the ISO (mis-built image) → ScaffoldService logs and
  proceeds lock-less: today's network behavior as fallback, not a new failure.
- A lock `path:` target missing from the store (bake bug) → nix fails eval
  with a clear "path does not exist" — surfaced by the build-time consistency
  check (§7) before any ISO ships.
- Network genuinely needed (dev experimentation, deliberately changed inputs
  post-scaffold) → substituters/fetching still work; hardening only prevents
  hangs (fast connect-timeout) and registry surprises.
- Nothing in this design changes `install_view`'s failure/retry routing.

---

## 7. Verification

1. **Build-time consistency check** (CI-able, cheap): every `path:` entry in
   the generated offline lock exists in the ISO's baked store set; the baked
   toplevel is the one produced by the templates-outputs eval (true by
   construction — asserted by comparing drv paths in the image derivation).
2. **The acceptance gate — network-off VM install:** `just vm-boot` with QEMU
   networking disabled (e.g. a `vm-boot-offline` recipe using `-nic none`) →
   wizard → install completes fully; progress bar rises through the copy
   phase; no `copying path … from https://…` lines appear in the log.
3. **First-boot offline eval:** boot the installed VM (still `-nic none`),
   run `nix flake metadata` / a dry rebuild eval in `~/nixblitz` → resolves
   offline. (The actual service build is then run online, as designed.)
4. **RAM observation:** on the 8 GB VM, install completes without zram
   pressure (the log's remount/zram lines become no-ops in practice).
5. **Regression:** an online install still works identically (substituter
   fallback intact).

---

## 8. Out of scope

- Pi 5 hardware verification (mechanism shipped, validation manual/later).
- Changing update semantics, the update flow, or branch switching.
- Progress-panel changes (already built; this design is what makes its bar
  meaningful).
- disko-install upstream changes; `nixos-anywhere`-style push installs.
- Shrinking the ~250–300 MB source pin (accepted cost, decided).
