# Install-Docs Split — Design

**Date:** 2026-07-28
**Status:** Approved

## Problem

The install documentation interleaves two divergent platform paths (x86 and
Pi 5) in one long narrative, twice: `website/content/docs/installation.md`
(~530 lines, operator-facing) and `docs/getting-started.md` (~590 lines, repo
twin with a manual keep-in-sync rule). Readers must extract their platform's
path from a wall of text, and the manual sync has already produced real drift
(the live-image login callout landed in the wrong platform's section; the
stock-ISO `passwd` dance is presented to prebuilt-media users it doesn't
apply to).

## Goals

- Two **fully linear, self-contained** guides — a reader picks their platform
  once and never jumps sections: "Install on Pi 5" and "Install on x86".
- Prebuilt media are the **primary path** in each guide; the network-bootstrap
  route becomes a clearly-marked appendix.
- Kill the cross-repo sync burden: the website becomes canonical;
  `docs/getting-started.md` shrinks to a dev quickstart.
- Platform-specific facts live only in their platform's guide (login callout,
  `passwd` dance, NVMe vs vda, cooling, 16K-page notes).

## Non-goals

- No new content beyond restructuring/curation — every fact is already in the
  two existing files (and was field-verified this week).
- No website framework/layout changes beyond sidebar entries.
- No Pi 4 content.

## Deliverables

### 1. `website/content/docs/install-pi5.md` — "Install on Pi 5"

Linear order: hardware budget (Pi 5 8 GB, NVMe via M.2 HAT, USB stick,
active cooling) → download prebuilt image (zipline link) → flash
(`zstd -dc … | dd`, Raspberry Pi Imager note) → boot → **login callout:
user `nixos`, password `nixblitz`, SSH works immediately, sudo passwordless,
evaporates after install** → install wizard (disk = the NVMe, network,
lightning backend) → offline install expectations (nothing fetched, copy
progress bar, duration) → remove stick + reboot → first-boot setup (admin
password via sudo modal — default `nixblitz`; services build; LND seed-wait
checklist incl. `[o]` journal popup; seed reveal) → verify + access (ssh
admin@, dashboard tour pointer, hotkeys incl. `[o]`/`[v]`) →
**Appendix: build the upstream image yourself** (nvmd cachix + `nix build
…#installerImages.rpi5` + network bootstrap `nix run` — compressed from the
current text).

### 2. `website/content/docs/install-x86.md` — "Install on x86"

Same skeleton: budget (VM table: 4 cores/4 GB/30 GB/UEFI; bare-metal note) →
download prebuilt ISO → attach to VM or `dd` to USB → boot → same login
callout → wizard (disk = vda/sda) → install → reboot → first boot →
verify + access (both duplicated verbatim from the Pi 5 guide) →
**Appendix: stock NixOS ISO + network bootstrap** (≥8 GB guidance, `nix run
git+https://…`, and the `passwd`-before-SSH step — which exists ONLY on this
route and appears ONLY here).

### 3. `website/content/docs/installation.md` → platform chooser (~30 lines)

Experimental warning banner, the platform routing table (kept), two prominent
links to the guides. Old deep links to `/docs/installation` keep resolving.

### 4. Sidebar + hotkey

`website/lib/components/sidebar.dart`: entries become `installation`
(chooser), `install: pi 5`, `install: x86` (flat map, existing style).
`lib/main.server.dart`'s `d` hotkey keeps targeting `/docs/installation`.

### 5. `docs/getting-started.md` → dev quickstart (~100 lines)

Contributor-only content: `just vm-boot` / `vm-ssh-installer` loop, regtest
rationale, debug-menu pointers, link to `dev-loop.md` — plus links to the two
website guides as the canonical install docs. The "keep in sync with
website/…" header rule is deleted.

### 6. Cross-reference sweep

Retarget references to the old monolith: `docs/releasing-installer-images.md`
(upstream-image build instructions "documented in
website/content/docs/installation.md" → install-pi5.md; routing-table
pointers), plus any other `installation.md` / `getting-started.md` mentions
found by grep across docs/ and website/.

## Duplication contract

The wizard / first-boot / verify sections are intentionally duplicated
between the two guides so each reads linearly. Each guide opens with an HTML
comment: `<!-- install-pi5.md and install-x86.md share their wizard /
first-boot / verify sections — edit both. -->` That comment is the entire
remaining sync surface.

## Verification

- `just web-serve`: sidebar shows three entries; both guides render; chooser
  links resolve; in-page anchors work.
- Grep proves no dangling references to removed sections.
- `just format` clean.
- User reads both guides top-to-bottom (the actual acceptance test: does each
  read linearly for its platform without cross-jumps).
