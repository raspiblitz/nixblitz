# Forge → GitHub URL Migration — Design

**Date:** 2026-07-31
**Status:** Approved

## Problem

The repo now lives at `github.com/raspiblitz/nixblitz`, but every
load-bearing URL still points at the old forge
(`forge.f44.fyi/f44/nixblitz_ng` and
`forge.f44.fyi/f44/nixblitz_official_plugins`): the templates flake's
`nixblitz` input (what every installed node evaluates and re-locks
against), the offline-installer input mapping, the wizard's three
hardcoded plugin installs, the plugin catalog, and the operator docs'
bootstrap commands. The forge must currently stay alive for every
fresh install and every node update.

## Goals

- All non-historical nixblitz + official-plugin URLs point at GitHub.
- The offline installer's A==B guarantee survives the change (baked
  closure == install-time eval, including lock `original` URLs).
- Existing nodes migrate via the existing template-refresh mechanism —
  no new migration code.
- Third-party `forgejo:`-hosted plugins remain fully supported.

## Non-goals

- Dart fork pins (`nocterm`, `jaspr_cli` git deps in the pubspecs) stay
  on the forge — deferred.
- Historical documents (`docs/superpowers/specs|plans/*`, dated testing
  notes, decision records) keep their forge URLs — they are records.
- No changes to attic/zipline/cachix URLs (f44.fyi infra, not forge).
- No `github:`-scheme conversion of the templates' nixblitz input (see
  URL-form decision).

## Decisions

### URL forms

- **Node flake input** (`templates/flake.nix`):
  `git+https://github.com/raspiblitz/nixblitz` (with `?ref=` appended
  by scaffolding). Host swap only — `substituteNixblitzRef`'s regex,
  `branches.json` resolution, and `custom:` refs containing slashes
  all work unchanged. The lighter `github:` tarball form is rejected
  here because refs with slashes don't round-trip in its path syntax.
- **One-shot bootstrap** (docs, README, website):
  `nix run github:raspiblitz/nixblitz` — tarball fetch, fastest on a
  live ISO, no ref machinery involved.
- **Official plugins**: `github:raspiblitz/nixblitz_official_plugins/<name>`
  — the plugin URL parser (`lockedInputForPlugin`, `subdirFor`) and the
  upstream prober already handle the `github:` scheme end to end
  (verified: `upstream_prober.dart` GitHub API paths exist).

### Existing-node cutover (no new code)

Nodes run one last TUI update against the forge. The new binary's
embedded templates differ from `~/nixblitz/` → the existing
template-drift banner appears → `[r]` refresh rewrites `flake.nix`
with the GitHub URL (preserving the operator's branch pin via the
manifest, as refresh already does) → the next check/apply re-locks
against GitHub. Existing plugin markers keep `forgejo:` URLs and keep
working while the forge is alive; they migrate naturally on plugin
update/reinstall. The forge stays read-alive until the operator's
nodes have crossed.

## Changes

1. **`templates/flake.nix`** — nixblitz input URL → the git+https
   GitHub form.
2. **`nix/offline-inputs.nix`** — every forge reference updated so the
   generated path-locked flake.lock's `original` fields match the new
   templates URL exactly (mismatch ⇒ install-time re-lock ⇒ A==B
   broken; the lock generator's self-assert plus the offline VM
   acceptance run are the gates).
3. **`common/lib/src/services/scaffold_service.dart`** — no logic
   change (the substitution regex is URL-agnostic); doc comments and
   the test fixtures' URLs update to the GitHub form.
4. **Wizard + catalog** — `tui/lib/src/ui/views/setup_view.dart` (3
   hardcoded installs), `tui/lib/src/ui/views/configure/plugin_catalog.dart`,
   `plugin_install_view.dart` example text → `github:` scheme URLs.
5. **Plugins repo itself** (separate repo, prepared in the
   `examples_redesign/nixblitz_official_plugins` checkout for the user
   to push): every `plugin.json` `url:` self-reference →
   `github:raspiblitz/nixblitz_official_plugins/<name>`; README/docs
   inside that repo likewise. Precondition: the user creates + pushes
   `github.com/raspiblitz/nixblitz_official_plugins`.
6. **Docs/website sweep** (current-instruction files only): README,
   justfile comments, `docs/dev-loop.md`, `docs/plugin-authoring.md`,
   `docs/releasing-installer-images.md`, `docs/website-build.md`,
   `docs/getting-started.md`, `website/content/docs/*` (guides'
   appendices, plugins page), `website/lib/*` (home, layout footer,
   changelog page), `docs/decisions/plugins.md` where it states
   current URLs. `nix/website_pkg.nix` if it embeds a forge URL.
7. **Tests** — fixture URLs in `common/test/services/*` that assert on
   the default/official URLs follow the code.

## Verification

- Trio (`just test` / `analyze` / `format`) — includes the scaffold
  substitution tests against the new URL.
- `rg forge.f44.fyi` over non-historical paths returns only the
  deliberate survivors (pubspec fork pins, historical docs).
- `just iso-build` then `just vm-clean && just vm-boot-offline`: full
  offline install must complete with zero network — proves the offline
  lock's `original` URLs match the new templates flake.
- First-boot wizard on that VM installs bitcoind+LND from
  `github:raspiblitz/nixblitz_official_plugins` (network path).
- Update check on the installed VM: "no input movement — system is
  current".
- Existing-node path: on the Pi (or a pre-migration VM), TUI update →
  drift banner → `[r]` → `flake.nix` shows the GitHub URL → check
  stays clean.
