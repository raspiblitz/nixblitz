# Install-Docs Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the interleaved x86+Pi5 install monolith into two fully linear platform guides plus a chooser, and shrink the repo twin to a dev quickstart.

**Architecture:** Pure content curation — every fact already exists in `website/content/docs/installation.md` and `docs/getting-started.md` and was field-verified this week. Two new website pages duplicate their shared wizard/first-boot/verify sections deliberately (linear reading beats DRY here); an HTML edit-both comment is the entire sync mechanism. The website becomes canonical; the repo doc stops mirroring it.

**Tech Stack:** Markdown (jaspr_content), one Dart sidebar map, `just format` (dprint) as the formatter.

**Spec:** `docs/superpowers/specs/2026-07-28-install-docs-split-design.md` — binding for section order and placement decisions.

## Global Constraints

- **Fully linear guides**: within the main body of each guide, zero "see the other section / platform" jumps. The network-bootstrap route is an appendix at the END of each guide, after verify.
- **Prebuilt media first**: the primary path in both guides is download-prebuilt → flash → boot.
- **Platform facts stay in their platform's guide only**: the `nixos`/`nixblitz` live login callout appears in BOTH guides at the boot/SSH step (both prebuilt media bake it); the stock-ISO `passwd`-before-SSH dance appears ONLY in the x86 appendix (it applies nowhere else).
- Verified facts that must survive verbatim (all field-tested this week — do not re-derive or "improve"):
  - Live login: user `nixos`, password `nixblitz`, sudo passwordless, evaporates after install+reboot.
  - Default admin password on the installed system (first sudo modal): `nixblitz`.
  - Download links: `https://zipline.f44.fyi/u/nixblitz-x86-installer-1.iso` and `https://zipline.f44.fyi/u/nixblitz-pi5-installer-1.img.zst`.
  - Pi flash: `zstd -dc nixblitz-pi5-installer.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`; Raspberry Pi Imager handles `.img.zst` natively. x86 flash: `sudo dd if=nixblitz-installer.iso of=/dev/sdX bs=4M conv=fsync status=progress`.
  - Install is fully offline on prebuilt media; a quiet multi-minute "Evaluating system configuration" phase on the Pi 5 is normal.
  - Wizard: 3 decisions (disk / mainnet-or-regtest / LND-CLN-None); disk is `nvme0n1` on Pi 5, `vda`/`sda` in VMs.
  - Experimental warning block (verbatim from current docs) at the top of the chooser AND both guides.
- Each new guide opens with: `<!-- install-pi5.md and install-x86.md share their wizard / first-boot / verify sections — edit both. -->`
- Duplicated sections (wizard, first-boot, verify+access) must be byte-identical between the two guides except for platform-specific disk names / device examples explicitly called out below.
- Repo conventions: jj (never git commit), `just format` before commit, commit messages explain WHY with the Co-Authored-By trailer.

---

### Task 1: `install-pi5.md` — the Pi 5 guide

**Files:**

- Create: `website/content/docs/install-pi5.md`
- Read (sources): `website/content/docs/installation.md`, `docs/getting-started.md`, `docs/releasing-installer-images.md` (routing/flash reference only)

**Interfaces:**

- Produces: the canonical wording of the SHARED sections (Wizard, First boot, Verify + access) that Task 2 copies verbatim; frontmatter `title: Install on Pi 5 - NixBlitz`.

- [ ] **Step 1: Write the guide** with exactly this section order (source material: the current installation.md Pi 5 sections + first-boot/wizard prose; getting-started.md's first-boot and TUI-tour text where it is the richer variant):
  1. Frontmatter + H1 `Install on Raspberry Pi 5` + the verbatim experimental-warning blockquote + 2-sentence promise (flash → wizard → reboot → node).
  2. `## What you need` — Pi 5 8 GB (4 GB boots but tight), NVMe via official M.2 HAT, USB stick ≥4 GB for the live image, active cooling (keep the current sync-pegs-CPU rationale).
  3. `## 1. Download the image` — prebuilt link; one sentence: TUI + full offline install closure baked in, nothing fetched during install.
  4. `## 2. Flash it` — `zstd | dd` command + Pi Imager note + wrong-device warning.
  5. `## 3. Boot` — insert stick, boot; TUI auto-launches on the console. Then the **login callout** (blockquote): `nixos`/`nixblitz`, `ssh nixos@<ip>` works immediately, sudo passwordless, evaporates after install; find the IP with `ip -4 addr`.
  6. `## 4. The install wizard` — SHARED section. 3 decisions; disk example: the NVMe (`nvme0n1`), size+model shown; regtest-vs-mainnet guidance (keep current text); LND recommendation. Confirm → disko-install: partitions, builds minimal system, copies store to disk, bootloader. Note the quiet "Evaluating system configuration" phase (minutes on a Pi 5 — normal), then the copy progress bar. Fully offline.
  7. `## 5. Reboot` — remove the stick (the Pi boots the stick in preference to NVMe if left in), reboot into `nixblitz-pi5`.
  8. `## 6. First-boot setup` — SHARED. Admin password (default `nixblitz` at the first sudo modal → set a new one), services build (~duration note), LND seed-wait checklist (sudo prompt appears only after "LND service started"; `[o]` opens the LND journal), seed reveal + write-it-down guidance.
  9. `## 7. Verify + access` — SHARED. `ssh admin@<ip>`, dashboard tour condensed (tiles, `[c]/[a]/[D]/[?]` hotkeys, `[o]`/`[v]` in System→Check), updates row note.
  10. `## Appendix: build the live image yourself` — compressed from current text: nvmd has no downloadable image; cachix use + `nix build github:nvmd/nixos-raspberrypi/v1.20260707.1#installerImages.rpi5`; then the `nix run git+https://forge.f44.fyi/f44/nixblitz_ng` bootstrap (needs network; ≥8 GB fine on all Pi 5s). Link `docs/releasing-installer-images.md` for building the NixBlitz image itself.

  Length target: 250–330 lines. The edit-both HTML comment is line 1 after frontmatter.

- [ ] **Step 2: Render check** — `cd website && timeout 240 jaspr build --dart-define=BUILD_VERSION=0.1.0 --dart-define=BUILD_GIT_HASH=test` (the page renders; jaspr_content picks up files by path, no registration needed for rendering — sidebar comes in Task 3).

- [ ] **Step 3: `just format`** (repo root) — dprint reflows markdown; rerun until clean.

- [ ] **Step 4: Commit** — `jj describe -m "docs(website): Install on Pi 5 — linear platform guide\n\n<why: split per spec>\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>"` then `jj new`.

### Task 2: `install-x86.md` — the x86 guide

**Files:**

- Create: `website/content/docs/install-x86.md`
- Read: `website/content/docs/install-pi5.md` (Task 1's output — the shared sections are copied from it verbatim), `website/content/docs/installation.md`, `docs/getting-started.md`

**Interfaces:**

- Consumes: Task 1's exact Wizard / First-boot / Verify section text.

- [ ] **Step 1: Write the guide**, same skeleton:
  1. Frontmatter `title: Install on x86 - NixBlitz` + H1 `Install on x86` + warning + promise.
  2. `## What you need` — the VM table (4 cores/4 GB/30 GB/UEFI/ISO-first/bridged-or-NAT) + bare-metal note (same minimums).
  3. `## 1. Download the ISO` — prebuilt link, offline-closure sentence.
  4. `## 2. Attach or flash` — attach to VM as ISO, or `dd` for bare metal.
  5. `## 3. Boot` — TUI auto-launches; same login callout (verbatim from Task 1's, it is platform-neutral).
  6. `## 4. The install wizard` — copied verbatim from install-pi5.md **except** the disk example sentence: `vda`/`sda` in a VM, and drop the Pi-specific eval-duration aside down to "a quiet evaluation phase before output starts is normal".
  7. `## 5. Reboot` — detach ISO / boot order, reboot into the installed system.
  8. `## 6. First-boot setup` — verbatim copy.
  9. `## 7. Verify + access` — verbatim copy.
  10. `## Appendix: stock NixOS ISO + network bootstrap` — from current text: nixos.org 25.11 minimal ISO, ≥8 GB guidance, the `passwd`-then-SSH step (ONLY here), the `nix run git+https://forge.f44.fyi/f44/nixblitz_ng --experimental-features "nix-command flakes" --no-write-lock-file --refresh` bootstrap with its flag explanations.

- [ ] **Step 2: Diff-check the shared sections** — extract sections 4/6/7 from both files and diff; only the explicitly-allowed platform lines may differ. Note the diff result in the report.

- [ ] **Step 3: Render check + `just format`** (as Task 1).

- [ ] **Step 4: Commit** (jj, why-focused message, trailer).

### Task 3: Chooser page + sidebar

**Files:**

- Modify: `website/content/docs/installation.md` (rewrite to ~30 lines)
- Modify: `website/lib/components/sidebar.dart` (entries map at lines 13–16)

- [ ] **Step 1: Rewrite installation.md** as the chooser: frontmatter (keep `title: Installation - NixBlitz`), warning blockquote, one-paragraph framing, the platform routing table (kept from the current page, with the two live download links), then two prominent links: `[**Install on Raspberry Pi 5 →**](/docs/install-pi5)` and `[**Install on x86 →**](/docs/install-x86)`. Nothing else — every other section is now covered by the guides.

- [ ] **Step 2: Sidebar** — extend the map (existing style, order matters for display):

  ```dart
  '/docs/installation': 'installation',
  '/docs/install-pi5': 'install: pi 5',
  '/docs/install-x86': 'install: x86',
  '/docs/updates': 'updates',
  ```

  Leave `lib/main.server.dart`'s `d` hotkey at `/docs/installation` (now the chooser) — verify with grep, change nothing.

- [ ] **Step 3: Render check** — `jaspr build` generates all routes incl. the two new ones (route count goes 6 → 8); `just format`.

- [ ] **Step 4: Commit** (jj).

### Task 4: Repo-doc shrink + cross-reference sweep

**Files:**

- Modify: `docs/getting-started.md` (rewrite to ~100 lines)
- Modify: `docs/releasing-installer-images.md` (retarget references)
- Check (grep only): `docs/*.md`, `website/content/docs/*.md`, `README.md` for links to the old monolith sections

- [ ] **Step 1: Rewrite getting-started.md** as the dev quickstart: header note becomes "Operator install docs live on the website (install-pi5 / install-x86); this file is the contributor quickstart." Keep ONLY: experimental warning; the `just vm-boot` / `just vm-ssh-installer` dev loop (from the current "Cloning the repo for development" + SSH-forward notes); regtest rationale for dev; the debug-menu / test-LND pointers; links to `dev-loop.md`, the two website guides, and `releasing-installer-images.md`. Delete everything the website guides now own (wizard walkthrough, first-boot, hotkey tour, Pi 5 sections).

- [ ] **Step 2: Sweep references** — `rg -n "getting-started|installation.md" docs/ website/ README.md`: retarget `releasing-installer-images.md`'s "documented in website/content/docs/installation.md" (upstream Pi 5 image build) to `install-pi5.md`'s appendix; fix any other pointer that meant "the install guide" rather than the chooser. List every hit + action taken in the report.

- [ ] **Step 3: `just format`**; render check once more (`jaspr build`) since installation.md shrank.

- [ ] **Step 4: Commit** (jj).

---

## Final verification

- `jaspr build` emits 8 routes; no dangling links (grep for `/docs/installation#` anchors — the old deep-section anchors are gone, confirm nothing references them).
- Shared-section diff between the two guides shows only the allowed platform lines.
- `docs/getting-started.md` contains no wizard/first-boot content and no sync-required rule.
- User runs `just web-serve` and reads both guides top-to-bottom (the real acceptance test).
