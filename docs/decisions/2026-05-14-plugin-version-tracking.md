# Plugin version tracking — manifest-driven introducing-commit pinning

> Resolves the design questions raised by issue
> [#25](https://forge.f44.fyi/f44/nixblitz_ng/issues/25)
> ("feat: plugin version tracking — manifest-driven introducing-commit
> pinning"). Companion to `plugin-trust-models.md` on the security
> story.

## 0. Read this first

This doc is **not** about preventing a malicious plugin from doing
damage — `plugins.md` D14 still applies (installing a plugin is
equivalent to granting root). What's resolved here is two narrower
problems we hit in practice:

1. **Mono-repo false positives.** A single repo hosting plugins A,
   B, C in subdirs gets one commit that touches only B; today's
   lightweight check probes the branch HEAD, reports A, B, **and**
   C as "ahead." The operator gets nagged about three updates when
   only one is real.
2. **Version-label drift.** Author publishes `1.2.0` at commit X,
   then pushes Y, Z under the same branch without bumping the
   version. SHA-based comparison would auto-update Z under the
   label `v1.2.0`. The label loses meaning.

Solution: track the **manifest `version` field**; pin to the
**commit that introduced that version**, not branch HEAD.
Subsequent commits without a version bump don't propagate.

## 1. Manifest contract

Plugins declare a `version` field in `manifest.json`:

```json
{
  "id": "lnbits",
  "version": "1.2.3",
  "manifest": { "schema_version": 2, ... },
  ...
}
```

**Parsing**: `package:pub_semver`'s `Version.parse(...)`. Anything
the canonical semver 2.0 parser accepts is accepted. Anything it
rejects (`v1.2.3`, `1.2`, `1.2.3.4`, malformed pre-release
identifiers) → manifest load fails with a clear error.

We deliberately **do not** enforce a custom regex or constrain
pre-release identifier shape. The user-facing channel convention
below is operator-and-author discipline, not a parse-time gate.

### Channel convention (informal)

A plugin author who wants a stable / beta / dev release flow uses
three branches:

| Branch | Version shape                | Operator pin         |
| ------ | ---------------------------- | -------------------- |
| `main` | `1.2.3` (no pre-release)     | `forgejo:.../plugin` |
| `beta` | `1.2.3-beta.N`, `1.2.3-rc.N` | `?ref=beta`          |
| `dev`  | `1.2.3-dev`                  | `?ref=dev`           |

Plugin authors who only ship stable just publish `1.2.3` and
ignore the rest. Nothing enforces this — `main` could publish
`1.2.3-foo-bar` and we'd accept it. The convention is what authors
and operators agree on; the parser only ensures semver validity so
**ordering** stays sane.

Semver ordering handles cross-channel comparison correctly:

```
1.2.3-beta.1 < 1.2.3-beta.2 < ... < 1.2.3-rc.1 < ... < 1.2.3
```

Numeric pre-release identifiers (`-beta.10`) compare numerically
when dot-separated — sidesteps the `beta10 < beta2` lexical
gotcha that bites bare-suffix forms (`-beta10`).

## 2. Introducing-commit walk

The algorithm for the lightweight check, per plugin with a
versioned upstream:

```
1. fetchManifestAt(branchHead) → { version: V_upstream, ... }
2. if V_upstream <= pinnedVersion → done, nothing new
3. if V_upstream < pinnedVersion → DOWNGRADE PATH (soft refuse,
   see §5)
4. listCommitsAffectingPath(<subdir>/manifest.json, until = branchHead)
   → [c_n, c_n-1, ..., c_0] (newest first; cap at 50 to bound HTTP cost)
5. Walk from newest: at each c_i, fetchManifestAt(c_i).version.
   The first c_i where (version at c_i) != (version at c_{i-1})
   is the introducing-commit for V_upstream.
6. Pin candidate = c_i. Report "ahead" with new pinnedRev = c_i,
   new pinnedVersion = V_upstream.
```

**HTTP cost**: O(1) for the "is there an update?" probe (always 1
manifest fetch). When updating, O(N) for the walk where N is the
number of commits that touched `<subdir>/manifest.json` since the
current pin — typically 1-2, capped at 50 to keep pathological
cases bounded.

**Caching**: per-plugin probe result lives in
`update-status.json`'s existing pluginsAhead structure. The walk
runs once per "update available" transition; subsequent light
checks just re-probe HEAD's version and stop at step 2.

## 3. State shape changes

| Field                  | Today                       | After this work                           |
| ---------------------- | --------------------------- | ----------------------------------------- |
| `PluginManifest`       | (no version field)          | `+ String? version` (nullable for compat) |
| `PluginMarker`         | `String rev`                | `+ String? pinnedVersion` (nullable)      |
| `PluginAhead` (status) | `currentRev`, `upstreamRev` | `+ currentVersion`, `+ upstreamVersion`   |

`PluginMarker.rev` stays as the canonical "what commit is
installed." `pinnedVersion` is the **label** for that commit.
Backward-compat: plugins whose manifests don't carry `version`
keep tracking via SHA only, same as today.

## 4. Migration

Existing installs have `pinnedRev` only. On first launch after
the binary upgrade:

- The lightweight check probes each installed plugin's upstream.
  If the upstream HEAD has a `version` field, fetch the manifest
  at the operator's `pinnedRev` too, populate `pinnedVersion` in
  the marker.
- One extra HTTP call per versioned plugin, once. Subsequent runs
  skip the backfill.
- Plugins whose upstream HEAD has no `version` field don't get
  backfilled — they stay on pure-SHA tracking forever (unless the
  author later adds a `version` field, which retriggers backfill).

## 5. Edge cases and policies

### Downgrade (upstream version < pinned)

**Soft refuse**: surface a status row like

```
↑ plugins  1 plugin DOWNGRADED upstream — review manually
```

with the downgrade-specific color (amber, not red). The dashboard
shows it; auto-update does not apply it. The operator can opt in
explicitly via `nixblitz plugin refresh --force <id>` for
intentional rollbacks. Logged at WARN.

### Force-push / pinned-rev disappeared

When the previously-pinned `introducing-commit` is no longer in
the upstream branch (the author force-pushed history):

- Light check logs WARN with the pinned SHA + the upstream
  branch HEAD.
- Surface a non-blocking banner: `Plugin X: history rewritten
upstream — review`. Doesn't refuse updates; the operator's
  primary security signal is the author's sign-key (see
  `plugin-trust-models.md`), not rev reachability.
- Auto-update proceeds normally — if the new upstream version is
  ahead and parses, it's a pin candidate.

### Per-plugin failure isolation

A single plugin's failure (manifest 404, network error, parse
error, subdir rename) doesn't poison the rest. The light check
records the failure on that plugin's row and moves on. Other
plugins in the same monorepo continue to be probed normally.

### Subdir rename / plugin deleted upstream

`<subdir>/manifest.json` returns 404 from the upstream API:
surface as `Plugin X: moved or deleted upstream — check
manually` row. The plugin stays installed (we don't pull on
operator behalf); the operator decides whether to re-install
from the new path or remove the plugin entirely.

### Version replay (same version re-introduced)

Author tags `1.2.3`, reverts, re-tags `1.2.3` from a different
commit. Two introducing-commits exist for the same version
string. **Policy**: pick the **oldest** by commit date.
Reasoning: if the operator already pinned the first one, they're
already up to date by version label and we shouldn't move their
pin to the second commit. If they didn't pin yet (fresh install),
they get the oldest valid expression of "version 1.2.3."

### Malformed version field

Strict `pub_semver` parse. Manifest load fails. Plugin install
refuses with the parse error inline; existing installs whose
`version` was added in a bad shape after install surface as `↑
plugins  1 plugin has invalid version upstream — review`.

## 6. UI surfacing

| Surface                     | Today                 | After this work                                   |
| --------------------------- | --------------------- | ------------------------------------------------- |
| Dashboard `↑ plugins` count | "N plugins ahead"     | unchanged                                         |
| Configure → Plugins row     | per-plugin `↑` mark   | `+ pinnedVersion → upstreamVersion` next to ↑     |
| System → Check status panel | "3 updates available" | `+ "lnbits 1.2.3 → 1.2.4"` per affected plugin    |
| Heavy check `nvd diff`      | by store path         | unchanged (introducing-commit pin doesn't affect) |

## 7. Out of scope (defer to follow-ups)

- **Channel-switching UX** (`Configure → Plugins → <id> → Channel:
stable / beta / dev`) — operator currently edits `?ref=` by
  hand. Worth a follow-up issue when the version-tracking
  groundwork is in.
- **Signature-continuity enforcement** — paired concern, lives in
  `plugin-trust-models.md`. Version pinning gives us a stable
  artifact to require a signature on; the enforcement itself is
  separate work.
- **TUI's own version-string adoption** — `flake.nix`'s `version =
"0.1.0";` constant should also adopt pub_semver parsing once
  the plugin track lands, but ship plugin work first; TUI branch-
  cut from a separate commit.
- **Plugin registry** — would solve the immutability question via
  the npm / cargo path. Substantial infra commitment, not on the
  near roadmap.

## 8. Touched code (implementation roadmap)

When this lands as code (separate diff):

- `common/lib/src/models/plugin/plugin_manifest.dart` — `+ String?
version` field, pub_semver parse in `fromJson`.
- `common/lib/src/services/plugin/plugin_marker.dart` — `+ String?
pinnedVersion` field, JSON round-trip.
- `common/lib/src/models/update_status.dart` — `PluginAhead` gains
  `+ currentVersion`, `+ upstreamVersion`.
- `common/lib/src/services/update_check_service.dart` —
  `runLightweight`'s per-plugin walk: fetch upstream manifest,
  compare versions, walk introducing-commit when ahead, handle
  downgrade / force-push / 404 cases.
- `common/lib/src/services/plugin_service.dart` — install /
  refresh paths capture `pinnedVersion` from the manifest at
  `pinnedRev`.
- `pubspec.yaml` — add `pub_semver` as a `common` dependency.
- Tests covering: stable + pre-release ordering, introducing-
  commit walk, downgrade refusal, force-push warning, 404
  isolation, migration backfill, version-replay oldest-wins.

## 9. Resolved questions

| Q                                   | Resolution                                                |
| ----------------------------------- | --------------------------------------------------------- |
| Semver parser?                      | `pub_semver`, accept everything it accepts                |
| Custom regex for pre-release shape? | No — convention, not enforcement                          |
| Downgrade behaviour?                | Soft refuse + amber banner; `--force` opt-in              |
| Migration of existing installs?     | Lazy first-launch backfill, one HTTP per versioned plugin |
| Failure isolation across plugins?   | Per-plugin; one failure doesn't affect others             |
| Force-push handling?                | Warn (log + banner); don't refuse updates                 |
| Channel-as-regex?                   | Dropped — operators pick branches, authors pick labels    |
| TUI own version in same change?     | No — plugin first, TUI version as a follow-up             |
