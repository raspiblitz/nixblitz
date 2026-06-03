# nixblitz + plugin branches — design

> Let the publisher of nixblitz (and of each plugin) declare a curated
> set of git branches with friendly labels. Replace the hardcoded
> `main / beta / dev` list from #33 with a manifest-driven picker.
> Add a System Configure row that lets the operator pick which branch
> their nixblitz binary tracks — so testing a feature branch on a
> real node doesn't require hand-editing `~/nixblitz/flake.nix`.

## Context

Two pieces of friction motivated this work:

1. The plugin channel-switcher shipped with issue #33 hardcodes the
   picker's offered list as `main / beta / dev / Custom branch`.
   The data layer (`PluginMarker.branch` as a free-form string) is
   already publisher-free, but the UI forces a fixed semantic set
   on every plugin regardless of what its publisher actually
   maintains. None of the in-tree plugins maintain a `dev` branch.
2. The nixblitz binary itself has no in-TUI way to pick what branch
   the operator's flake pulls from. Testing a feature branch (e.g.
   the just-finished `plugins-nostr-wot` work) requires editing
   `~/nixblitz/flake.nix` by hand and rebuilding. Operators who
   want to try a dev-tier fix have to drop to nix knowledge.

Both surfaces want the same thing: let the **publisher** declare what
branches they maintain with friendly labels, and let the **operator**
pick from that declared set (or type a custom ref as the escape
hatch). This spec unifies them under one shared model + picker
widget.

## Key decisions (locked in brainstorming)

- **Vocabulary: "branches", not "channels".** A branch is literally
  what we store on the marker and what the operator picks; "channel"
  was borrowed distro-baggage we don't earn. Rename `PluginSwitch
ChannelView` → `PluginSwitchBranchView` and `PluginService.switch
Channel` → `switchBranch` as part of this work. The marker's
  existing `branch` field stays correctly named.
- **Publisher-controlled naming.** No fixed semantic tiers
  (`stable`/`beta`/`dev`) — each publisher picks their own labels.
  Cross-publisher consistency is sacrificed for honest mapping to
  what the publisher actually maintains.
- **Declaration shape: named map.** Keys are operator-facing labels;
  values carry `ref`, `description?`, `default?`. Exactly one entry
  per manifest may have `default: true` (parser rejects multiple).
  Format:

  ```json
  "branches": {
    "stable":    { "ref": "main", "description": "Production releases", "default": true },
    "next":      { "ref": "next", "description": "Pre-release queue" }
  }
  ```

- **Declaration location for nixblitz-self: `branches.json` at the
  project root,** embedded into the binary via the existing
  `EmbeddedTemplates` mechanism. Same code-gen pattern as
  `templates/`. The TUI reads the embedded snapshot; on rebuild,
  the new binary brings its own snapshot.
- **Operator flake plumbing: scaffold-time URL substitution.**
  `ScaffoldService` rewrites `~/nixblitz/flake.nix`'s `nixblitz.url`
  line with `?ref=<chosen-ref>` based on `SystemConfig.nixblitzBranch`
  - embedded `branches.json`. On-disk flake stays hand-editable.
    `custom` lets the operator pick any ref string but keeps the
    canonical URL — fork-of-the-project use cases stay hand-edit
    territory (intentional — different threat model).
- **Plugin fallback (no `branches` block in manifest): free-form
  branch input only.** Migrate all in-tree plugins as part of this
  work — each gets at least
  `"branches": { "stable": { "ref": "main", "default": true } }`.
  External / future plugins that omit the block get the free-form
  fallback (no hidden default list).
- **Schema bump → plugin manifest v5.** Adds optional `branches`
  field. Backward-compatible: v4 manifests without it still parse.

## Architecture

The feature unifies two surfaces under one shared concept:

```
                  branches.json (project root)              plugin.json (per-plugin)
                  ──────────────────────────                ────────────────────────
                          │                                          │
                          │ embedded via EmbeddedTemplates           │
                          │ at build time                            │
                          ▼                                          ▼
                  ┌──────────────────────────────────────────────────────┐
                  │  BranchManifest (shared model)                       │
                  │  Map<String, DeclaredBranch> with .ref, .description,│
                  │  .default; parser shared by both surfaces            │
                  └──────────────────────────────────────────────────────┘
                          │                                          │
                          ▼                                          ▼
                  ┌──────────────────────┐                ┌─────────────────────────┐
                  │ Configure → System → │                │ Configure → Plugins →   │
                  │ "Branch" row         │                │ <plugin> → Switch branch│
                  │ (nixblitz-self)      │                │ (replaces #33 hardcode) │
                  └──────────────────────┘                └─────────────────────────┘
                          │                                          │
                          └──────────────┬───────────────────────────┘
                                         ▼
                          ┌────────────────────────────────┐
                          │  BranchPicker (shared widget)  │
                          │  Renders declared branches +   │
                          │  "Custom branch…" escape hatch │
                          └────────────────────────────────┘
                                         │
                       ┌─────────────────┴──────────────────┐
                       ▼                                    ▼
              writes SystemConfig                  PluginService.switchBranch
              .nixblitzBranch                      (renamed from switchChannel)
                       │                                    │
                       ▼                                    ▼
              ScaffoldService rewrites              clone at chosen ref,
              ~/nixblitz/flake.nix's                update marker.branch
              nixblitz.url with ?ref=…
                       │                                    │
                       ▼                                    ▼
              `nixos-rebuild switch`                refresh / install flow
              picks up new binary                   already shaped for this
```

**Key properties:**

- **Shared model + picker.** Both surfaces consume the same
  `BranchManifest` shape and render via the same `BranchPicker`
  widget. No duplication.
- **Scaffold-time URL substitution.** When the operator picks a
  branch in System → Branch, the scaffold service rewrites
  `~/nixblitz/flake.nix`'s `nixblitz.url` to include
  `?ref=<chosen-branch's-ref>`. The on-disk flake stays
  hand-editable for power users; the TUI just owns "the common
  case."
- **Free-form fallback.** Plugins (and nixblitz-self if
  `branches.json` were ever missing) without a declared branch set
  get a `Custom branch…` input only — operator types the git ref
  they want.
- **Rename pass.** `PluginSwitchChannelView` →
  `PluginSwitchBranchView`, `switchChannel` → `switchBranch`.
  The CLI subcommand `nixblitz plugin switch-channel` →
  `switch-branch`. The marker's existing `branch` field is already
  correctly named; no data migration.

## Component layout

```
common/lib/src/
├── models/branch/                       NEW directory
│   ├── declared_branch.dart             NEW  { ref, description?, isDefault } immutable data class
│   ├── branch_manifest.dart             NEW  Map<String,DeclaredBranch> + fromJson/validation
│   └── nixblitz_branch_manifest.dart    NEW  loads embedded branches.json once at startup
├── models/plugin/
│   └── plugin_manifest.dart             MOD  + optional `branches` field of type BranchManifest, schema_version → 5
├── models/nixblitz_config.dart          MOD  SystemConfig.nixblitzBranch (default null → resolved at scaffold time to manifest's `default:true` entry)
└── services/
    ├── scaffold_service.dart            MOD  URL substitution: read SystemConfig.nixblitzBranch + branches.json, write `?ref=<ref>` into flake.nix
    ├── embedded_templates.dart          MOD  + nixblitz_branches.json constant (generated)
    └── plugin_service.dart              MOD  switchChannel → switchBranch rename; refresh uses marker.branch (already correct)

branches.json                            NEW  at project root — nixblitz's own branch declaration
                                              { "stable": { "ref": "main", "description": "...", "default": true } }

tui/lib/src/
├── ui/widgets/
│   └── branch_picker.dart               NEW  shared widget — takes BranchManifest? + current ref, returns chosen ref string
└── ui/views/
    ├── configure_view.dart              MOD  System section: new "Branch" row using BranchPicker
    ├── plugin_install_view.dart         MOD  install-time branch pick reads from manifest.branches if present
    ├── plugin_switch_channel_view.dart  RENAMED → plugin_switch_branch_view.dart; picker reads from manifest
    └── apply_view.dart                  MOD (maybe)  shows "switching to branch X requires rebuild" hint

scripts/                                 MOD  embedded_templates code-gen script picks up branches.json

dev/plugins/*/plugin.json                MOD  add `branches` block to each in-tree plugin manifest (bitcoind, lnd,
                                              cln, clightning, electrs, blitz-api, blitz-web, lnbits, tailscale)
                                              minimum: { "stable": { "ref": "main", "default": true } }
```

**Design notes on the units:**

- **`branch/` subdirectory under `models/`.** Both surfaces share
  these models; not putting them under `models/plugin/` because the
  nixblitz-self surface uses them too.
- **Schema bump → v5.** Plugin manifest gains an optional `branches`
  field; backward-compatible (v4 manifests without it still parse).
- **`SystemConfig.nixblitzBranch` defaults to null.** The scaffold
  service resolves null at write-time by reading `branches.json` and
  picking the entry with `default: true`. This way: (a) existing
  operator configs without the field auto-pick the default branch
  on next scaffold, (b) the publisher controls what "default" means
  by editing branches.json.
- **`switchChannel` → `switchBranch` rename.** Touches the service,
  the CLI subcommand (`nixblitz plugin switch-channel` →
  `switch-branch`), and the view filename. The marker's `branch`
  field is already correctly named so no data layer touched.
- **In-tree plugin migration is part of the spec scope.** Each of
  the 9 in-tree plugins gets a `branches` block in its `plugin.json`.
  Small per-plugin diff (5 lines each) but it makes the new
  behaviour consistent across the dogfood set.

## Data flow

### Branch resolution at scaffold time

```
operator opens TUI
       │
       ▼
ConfigService.load() reads ~/nixblitz/config.json
       │
       ▼
SystemConfig.nixblitzBranch is null or set to a key like "stable" / "next" / "custom:<ref>"
       │
       ▼
On Apply / install path: ScaffoldService.writeFiles()
       │
       ├── if nixblitzBranch == null:
       │     read embedded branches.json → find entry with default:true → use its .ref
       │
       ├── if nixblitzBranch in declared keys (e.g. "stable"):
       │     read embedded branches.json → look up entry → use its .ref
       │
       ├── if nixblitzBranch starts with "custom:":
       │     strip prefix → that's the ref string the operator typed
       │
       └── if nixblitzBranch is a declared key that no longer exists in current
           branches.json (e.g. operator on "next" but next branch was retired):
             log warning, fall back to default:true entry, leave config field
             unchanged so the operator can re-pick deliberately
       │
       ▼
String-substitute `?ref=<resolved-ref>` into the `nixblitz.url` line of flake.nix
       │
       ▼
Write ~/nixblitz/flake.nix
       │
       ▼
Operator runs Apply → `nixos-rebuild switch --flake .#<host>`
       │
       ▼
nix flake update fetches new ref's tip
       │
       ▼
new nixblitz binary built + activated; brings its own snapshot of branches.json
```

### Plugin install / switch-branch flow

```
plugin add <url> [--branch <ref>]                     OR              operator opens Switch Branch action
       │                                                                       │
       ▼                                                                       ▼
git clone (default branch if --branch not given)                       PluginService.switchBranch reads
       │                                                              existing marker for the plugin
       ▼                                                                       │
read plugin.json                                                              ▼
       │                                                              if marker.branch resolves to a
       ├── manifest.branches != null:                                  declared key in cached manifest:
       │     if --branch given: use as ref                             show current selection highlighted
       │     elif manifest.branches has default:true: use its .ref
       │     else: error — manifest declares branches but no default
       │                                                                      ▼
       ├── manifest.branches == null:                                  BranchPicker overlay opens with:
       │     if --branch given: use as ref                             - rows for each declared branch
       │     else: use whatever default the git remote serves                + descriptions
       │                                                               - `Custom branch…` row at bottom
       ▼                                                                      │
proceed with install: confirm prompt, sig + Nostr checks,                     ▼
write marker with branch = <ref string>                                operator picks → switchBranch(id, ref)
                                                                              │
                                                                              ▼
                                                                       re-clone at new ref, validate manifest,
                                                                       update marker.branch
```

**Two specific behaviours worth pinning:**

1. **The picker shows the operator's chosen _key_ highlighted, not
   the ref.** If a publisher renames their `next` ref's underlying
   branch from `next` to `develop` (changes the `ref` in
   branches.json), the operator's choice of "next" carries over —
   they're tracking the publisher's semantic intent, not the
   literal branch.

2. **A `Custom branch…` pick stores the literal ref string with a
   `custom:` prefix in the config field.** Scaffold-time
   substitution strips the prefix. This makes the config schema
   unambiguous (we can tell whether the operator picked a declared
   key or typed a custom ref).

### Error handling

- **branches.json missing from embedded templates** (shouldn't
  happen — code-gen would fail) → throw at scaffold time with a
  clear error pointing at the codegen step.
- **branches.json declares zero entries** → reject at parse time;
  spec requires at least one entry, and exactly one must have
  `default: true`.
- **operator's chosen key disappears in a newer branches.json** →
  fall back to default, log warning, surface in the System pane as
  `Branch: stable (was "experimental" — no longer declared)`.

## Devenv & testing

### Unit-test coverage

- `BranchManifest.fromJson` — happy path, missing `default`,
  multiple `default:true` (reject), empty map (reject), invalid ref
  characters (reject — keep refs to git's `check-ref-format` rules:
  no whitespace, no control chars, no `..`).
- `DeclaredBranch.fromJson` — required `ref`, optional `description`,
  optional `default` (defaults to false).
- `nixblitzBranchManifest` provider returns parsed manifest from
  embedded source; same provider re-evaluates after scaffold (no
  caching that pins to the old binary's snapshot).
- `ScaffoldService` substitution — given a fixture `flake.nix`
  template + fixture `branches.json` + a `SystemConfig.nixblitzBranch`
  value, asserts the output `flake.nix` contains the right
  `?ref=…` and no other change.
- `PluginManifest.fromJson` schema v5 — `branches` block parses
  correctly; v4 manifests without it still parse (backward compat).

### Integration-test coverage

- `PluginService.switchBranch` (renamed from switchChannel) — happy
  path for plugin with declared branches; happy path for plugin
  without; rejection for pinned plugin (existing
  `PluginPinnedException` keeps working); custom-ref input flows
  through.
- `PluginService.install` — when `--branch` is given, it uses that;
  when not, it uses `default:true` from manifest if present, else
  the remote's default.

### TUI widget tests

- `BranchPicker` widget — renders declared branches with
  descriptions; renders `Custom branch…` row at bottom;
  current-selection highlighting matches the operator's stored key;
  custom-ref input phase appears on selecting `Custom branch…`.

### Manual / VM verification (the actually load-bearing test)

1. `just vm-boot` → install nixblitz on a fresh VM, accept the
   default branch.
2. SSH in, open Configure → System → Branch row shows
   `stable (ref=main)`.
3. Switch to `custom`, type `plugins-nostr-wot`, Apply → rebuild
   succeeds, the new TUI is the Nostr-WoT branch's binary.
4. `nixblitz --version` (or wherever the build hash surfaces)
   reflects the new ref.
5. Plugin side: open Configure → Plugins → bitcoind → Switch Branch
   → see the in-tree plugin's declared branches in the picker (not
   the old hardcoded list).

This last step is the win condition that motivated the whole
feature — the operator can test this exact branch on their actual
node without hand-editing `flake.nix`.

### Migration test

- Boot a VM with an existing `config.json` from before this work
  (no `nixblitzBranch` field) → confirm scaffold service writes
  `?ref=main` (resolved via `default:true`), no error, no broken
  state.
- Plugin marker with `branch: "main"` from before this work +
  plugin manifest with no `branches` block → switch-branch UI
  offers free-form input.

## Out of scope (each gets a follow-up issue)

- **"Your branch is N revs behind upstream" indicator.** The
  existing `UpdateCheckService` already does this per-plugin via
  the introducing-commit walk; applying the same pattern to the
  nixblitz-self branch is feasible but not in v1.
- **Pinning the nixblitz branch to a specific commit.** Plugins
  have `autoUpdate: false` / pin semantics; nixblitz-self pinning
  would need the same shape but it's a separate concern from "let
  me pick a branch." Lock-file management already gives effective
  pinning via `flake.lock`.
- **Reading branches.json from the live remote on TUI launch.**
  Today the operator's TUI binary ships with the snapshot from its
  own branch; switching branches gets the new snapshot via rebuild.
  A live-fetch model adds network deps and a freshness model.
- **Branch declaration validation against the remote.** We don't
  verify the ref actually exists on the forge before scaffolding.
  If it doesn't, `nixos-rebuild` fails clearly enough.
- **"Suggested upgrade path" UI** (e.g. "you're on `experimental` —
  here's how to move to `stable`"). Branches are flat in this
  design; no hierarchy or upgrade arrows. Operator picks what they
  want.
- **Custom URL override (fork support) via UI.** `custom` only
  overrides the ref, not the URL. Fork-of-the-project use cases
  stay hand-edit territory by design — different threat model.

## Risks the implementation should call out

- **In-tree plugin migration breakage.** Adding `branches` blocks
  to nine plugin manifests is mechanical but each manifest has to
  be valid v5 schema. A test in the plugin-consistency invariant
  should fail if any in-tree manifest's `branches` block is
  malformed.
- **Lock-file ordering with `?ref=...`.** Nix flakes resolve inputs
  eagerly. Changing the URL doesn't auto-update `flake.lock` —
  operators may need `nix flake update nixblitz` after a branch
  switch. The Apply view should run this implicitly: thread an
  explicit `nix flake lock --update-input nixblitz` before
  `nixos-rebuild switch`. Worth a dedicated impl-time check.
- **Branch retired upstream.** Operator picks `next`, then a year
  later the publisher drops the `next` branch from branches.json.
  Per the data flow: scaffold falls back to default, warns,
  surfaces in the System pane. Worth a unit test against a fixture
  that exercises this drift.
- **Scaffold-time substitution string match.** The substitution
  regex / parser for the `nixblitz.url = "…";` line in
  `templates/flake.nix` has to handle quote style, whitespace, and
  `inputs.nixpkgs.follows = "nixpkgs";` siblings without mangling
  them. Recommend a regex anchored on the exact attribute and a
  round-trip test that confirms the modified flake.nix still
  `nix flake check`s.

## Cross-references

- `docs/superpowers/specs/2026-05-30-plugin-nostr-wot-devenv-design.md`
  — Approach B work that motivated this. The dev-only escape hatch
  (env-var override of the flake URL) we'd discussed is retired in
  favour of this proper feature.
- Forge issue #33 — channel switching origin. This spec supersedes
  the hardcoded `main / beta / dev` list from that work; the
  rename + manifest-driven picker is the canonical shape.
- `docs/decisions/plugins.md` D14 — trust model. This work doesn't
  change it: an operator pinning to a custom branch is still a
  sudo grant in the same shape.
