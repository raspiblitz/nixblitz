# Forge → GitHub URL Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Point every load-bearing nixblitz + official-plugin URL at `github.com/raspiblitz/*`, preserving the offline installer's A==B guarantee and the existing-node template-refresh cutover.

**Architecture:** Mechanical URL swaps, precision-gated: the templates flake + offline-inputs pair must stay consistent (the generated lock's `original` fields must match the flake's input URLs exactly), the wizard/catalog move to the `github:` plugin scheme the parsers already support, and the plugins repo's own `plugin.json` self-references get a prepared commit in the `examples_redesign` checkout for the user to push. Historical docs keep forge URLs.

**Tech Stack:** Nix flakes, Dart, markdown; `just` recipes for verification.

**Spec:** `docs/superpowers/specs/2026-07-31-forge-to-github-urls-design.md` — binding.

## Global Constraints

- Node flake input form: `git+https://github.com/raspiblitz/nixblitz` (host swap only; `?ref=` machinery untouched).
- One-shot bootstrap form (docs/README/website/justfile/app.dart hint): `nix run github:raspiblitz/nixblitz`.
- Official plugin URL form: `github:raspiblitz/nixblitz_official_plugins/<name>`.
- Deliberate survivors of `rg forge.f44.fyi`: the three pubspec fork pins (nocterm ×3 blocks, jaspr_cli), `nix/website_pkg.nix` comments describing the jaspr fork, historical docs (`docs/superpowers/**`, `docs/testing/*`, `docs/decisions/2026-05-14-*`), and `website/web/casts/*.cast` (recorded terminal session — a record).
- Repo conventions: jj (never git commit), trio before commit, why-focused messages + Co-Authored-By trailer.

---

### Task 1: Node flake + offline mapping + scaffold fixtures (the A==B core)

**Files:**

- Modify: `templates/flake.nix:50`
- Modify: `nix/offline-inputs.nix:221,280` (comments; check for any URL-bearing code lines too)
- Modify: `common/lib/src/services/scaffold_service.dart:267` (doc comment)
- Test: `common/test/services/scaffold_service_test.dart:11,19` (+ any other forge fixtures in that file)

- [ ] **Step 1:** In `templates/flake.nix`, change

  ```nix
      nixblitz = {
        url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
  ```

  to

  ```nix
      nixblitz = {
        url = "git+https://github.com/raspiblitz/nixblitz";
  ```

- [ ] **Step 2:** In `nix/offline-inputs.nix`, update both forge mentions (lines 221, 280 are comments describing the input) to the new URL; `rg -n "nixblitz_ng|forge" nix/offline-inputs.nix` afterwards must return nothing. If any expression (not comment) carries the URL, it must match Step 1's string byte-for-byte.

- [ ] **Step 3:** Update `scaffold_service.dart:267`'s doc-comment example URL, and the test fixtures in `scaffold_service_test.dart` (`url = "git+https://forge.f44.fyi/f44/nixblitz_ng"` → github form, and the assertion string with `?ref=main`). Run: `cd common && dart test test/services/scaffold_service_test.dart` → all pass (the regex is URL-agnostic; this proves it).

- [ ] **Step 4:** Grep gate: `rg -n "nixblitz_ng" templates/ nix/ common/lib common/test` returns nothing.

- [ ] **Step 5:** Trio, then commit (jj): `fix(nix): node flake + offline mapping point at github.com/raspiblitz/nixblitz` — body: host-swap-only rationale (ref machinery untouched), A==B requirement that lock `original` matches the flake input.

### Task 2: Wizard, catalog, and TUI strings to the `github:` plugin scheme

**Files:**

- Modify: `tui/lib/src/ui/views/setup_view.dart:211,212,276`
- Modify: `tui/lib/src/ui/views/configure/plugin_catalog.dart:46,55,64,73,79,87`
- Modify: `tui/lib/src/ui/views/plugin_install_view.dart:299,307`
- Modify: `tui/lib/src/ui/app.dart:818` (recovery-hint text: `nix run github:raspiblitz/nixblitz`)
- Test: existing suites in `common/test/services/` referencing forge plugin URLs (`plugin_service_test.dart`, `update_check_service_test.dart`, `staging_service_test.dart`) — update fixture URLs to `github:raspiblitz/nixblitz_official_plugins/<name>` ONLY where they encode the official catalog; leave fixtures that deliberately exercise the `forgejo:` parser (third-party support stays).

- [ ] **Step 1:** Replace every `forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/<name>` in the four tui files with `github:raspiblitz/nixblitz_official_plugins/<name>`. `plugin_install_view.dart:307`'s `git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api` example line becomes `git+https://github.com/raspiblitz/nixblitz-plugin-example` (it illustrates the git+https transport, keep the transport, de-forge the host).
- [ ] **Step 2:** Test-fixture pass per the rule above; run `cd common && dart test` + `cd tui && dart test`.
- [ ] **Step 3:** Grep gate: `rg -n "forgejo:forge" tui/ common/lib` returns nothing (fixtures exercising the forgejo parser in common/test may remain — list them in the commit body).
- [ ] **Step 4:** Trio, commit: `feat(tui): official plugins install from github:raspiblitz/nixblitz_official_plugins`.

### Task 3: Docs + website sweep (current instructions only)

**Files:**

- Modify: `README.md`, `justfile:475`, `docs/dev-loop.md`, `docs/plugin-authoring.md`, `docs/releasing-installer-images.md`, `docs/website-build.md`, `docs/getting-started.md`, `docs/decisions/plugins.md` (current-URL statements only)
- Modify: `website/content/docs/install-pi5.md` (appendix bootstrap), `install-x86.md` (appendix bootstrap), `plugins.md`, `website/lib/components/layout.dart`, `website/lib/main.server.dart`, `website/lib/pages/home_page.dart`, `website/lib/pages/changelog_page.dart`
- Leave: `docs/superpowers/**`, `docs/testing/*`, `docs/decisions/2026-05-14-*`, `website/web/casts/*`, pubspecs, `nix/website_pkg.nix` comments

- [ ] **Step 1:** For each modify-file: `git+https://forge.f44.fyi/f44/nixblitz_ng` → `github:raspiblitz/nixblitz` where it is a `nix run` bootstrap command; → `git+https://github.com/raspiblitz/nixblitz` where it is a flake-input example; plain repo links (`https://forge.f44.fyi/f44/nixblitz_ng`) → `https://github.com/raspiblitz/nixblitz`. Plugin URLs → `github:` scheme. `fj release create` in releasing-installer-images.md → `gh release create`.
- [ ] **Step 2:** The x86 guide's bootstrap appendix flag explanation: `--no-write-lock-file --refresh` stays (still correct for `nix run github:`); re-read the paragraph for host-specific claims.
- [ ] **Step 3:** Grep gate: `rg -n "forge.f44.fyi" README.md justfile docs/ website/ --iglob '!docs/superpowers/**' --iglob '!docs/testing/**' --iglob '!docs/decisions/2026-05-14*' --iglob '!*.cast'` returns only `docs/decisions/plugins.md` historical narrative (if any) and nothing else — anything else gets fixed or justified in the commit body.
- [ ] **Step 4:** `just format`; render check via dev server or `jaspr build` (8 routes); commit: `docs: bootstrap + links point at github.com/raspiblitz`.

### Task 4: Plugins repo self-references (separate repo, user pushes)

**Files (in `examples_redesign/nixblitz_official_plugins/` — its own git repo):**

- Modify: the 6 `*/plugin.json` with forge `url:` fields → `github:raspiblitz/nixblitz_official_plugins/<name>`
- Modify: `README.md` / `AGENTS.md` / `cachepop/README.md` forge references (repo links → github)

- [ ] **Step 1:** `grep -rn "forge.f44.fyi" examples_redesign/nixblitz_official_plugins --include="*.json"` — update each `url:` to the `github:` form; verify each plugin's `<name>` segment matches its directory.
- [ ] **Step 2:** Sweep the repo's markdown the same way (cachepop README's `forgejo:` install examples → `github:`).
- [ ] **Step 3:** Commit IN THAT REPO with git (it is not jj-managed): `git -C examples_redesign/nixblitz_official_plugins add -A && git commit -m "chore: self-references point at github.com/raspiblitz/nixblitz_official_plugins"` with the Co-Authored-By trailer. DO NOT push — print the push command for the user (`git -C … push origin main` — check the actual branch/remote first; the remote may still be the forge and need `git remote set-url origin git@github.com:raspiblitz/nixblitz_official_plugins.git`).

---

## Final verification

1. Trio green.
2. Survivor audit: `rg -c "forge.f44.fyi"` full-repo matches ONLY: pubspecs (fork pins ×3 files), `nix/website_pkg.nix` (jaspr-fork comments), `docs/superpowers/**`, `docs/testing/*`, `docs/decisions/*` historical, `website/web/casts/*`, `nix/workspace_pubspec.lock.json` (regenerates with pubspecs — untouched this pass).
3. `just iso-build` → `just vm-clean && just vm-boot-offline`: full offline install completes with zero network (A==B holds with the new URL).
4. First-boot wizard on that VM: bitcoind+LND install from `github:raspiblitz/nixblitz_official_plugins` (requires the user to have pushed Task 4's commit).
5. Update check on the installed VM: "no input movement — system is current".
6. Existing-node cutover check (user, when convenient): Pi updates TUI → drift banner → `[r]` → `flake.nix` shows the GitHub URL.
