# SBOM package-version tracking + look-ahead — design

Date: 2026-06-28
Status: approved (design)

## Goal

Keep a git-committed record of every package + version in a node's system
closure (a CycloneDX SBOM), refreshed on each Apply so the file's **git diff is
the package-version changelog**. Use the same mechanism to **look ahead**:
during a Check, preview which package versions an update would change.

Uses the standard `sbomnix --cdx` → strip-volatile-fields → commit pattern (so
the file diffs only on real package changes), applied to nixblitz's **on-node,
per-node** model. **No CVE/grype** scanning (a possible later layer the SBOM
enables).

## Why on-node / per-node

The pattern this borrows from builds every closure centrally and scans in CI.
nixblitz nodes are autonomous — each runs its own TUI over its own `~/nixblitz`
flake and its own
closure (config + plugins differ per node). So the SBOM is generated **on the
node** and committed to the node's `~/nixblitz` git, where Apply already commits
config. There is no central scan; the value is the per-node committed history +
the on-node look-ahead.

## Components

### 1. `SbomService` (`common`)

`common` is the only package that runs `Process`. The service:

- **`generate({required String closure, required String outPath})`** — runs
  `nix run nixpkgs#sbomnix -- <closure> --cdx <tmp> --csv /dev/null --spdx
/dev/null --impure`, then strips volatile fields with
  `jq 'del(.serialNumber) | del(.metadata.timestamp)'` and writes `outPath`.
  `closure` is a realized store path (`/run/current-system`) or a staged
  candidate toplevel path. `--impure` lets sbomnix read nixpkgs metadata for
  real versions/purls (verify during impl whether a store-path run needs it;
  fall back to the flakeref form if version metadata is thin). Returns success /
  a non-fatal error.
- **`readComponents(String path) → Map<String,String>`** — parse a CycloneDX
  file's `components[]` into `name → version` (pure-ish: file read + JSON).
  Missing/empty file → empty map.
- **`diffComponents(Map before, Map after) → List<SbomChange>`** — pure,
  unit-testable. Emits `added` / `removed` / `changed` entries (sorted by name).

`class SbomChange { String name; String? from; String? to; SbomChangeKind kind; }`
with `enum SbomChangeKind { added, removed, changed }` and JSON round-trip (it
rides in `CheckResult`).

### 2. Commit on Apply (the base requirement)

In `apply_view._continueApply`, **after a successful rebuild** (`nixos-rebuild
switch` exit 0): generate the SBOM from `/run/current-system` (realized → a
closure walk, no eval) into `~/nixblitz/sbom.cdx.json`, then `git`-commit just
that file with message `Update SBOM`. A small second auto-commit per Apply; its
diff is exactly the package-version delta this Apply produced. **Best-effort**:
sbomnix/commit failure logs + emits a line, never fails the (already-completed)
Apply. Streams `> updating SBOM…` into the Apply log.

(The existing Apply commit happens _before_ the rebuild, so this is necessarily
a separate post-rebuild commit — which is also what makes it accurate: it
reflects the system that actually built.)

### 3. Look-ahead on Check (`common` check service)

In `UpdateCheckService.runCheck`, on the **substitute-only path** (where the
candidate toplevel is already realized and the nvd diff is produced — the same
gate; the compile-needed path bails before realizing and produces neither nvd
nor SBOM look-ahead): generate a candidate SBOM into a tmp file, diff its
components against the committed `~/nixblitz/sbom.cdx.json`
(`diffComponents(committed, candidate)`), and store the result on `CheckResult`.

`CheckResult` gains `final List<SbomChange> sbomChanges;` (default empty), with
JSON round-trip in `toJson`/`fromJson` and the staging file. Populated only on
the substitute-only path; empty otherwise.

### 4. "What's changing…" gains a Package-versions section (`tui`)

`cached_package_diff.dart` renders a new **"Package versions (N)"** section from
`result.sbomChanges` — `foo 1.2 → 1.3` (changed), `+ bar 0.9` (added), `- baz`
(removed). Sits above the existing "Package changes" (nvd) section. For now both
render; the SBOM section is the durable/committed view, nvd the tool-native one
— SBOM may supersede nvd later. Section renders only when `sbomChanges` is
non-empty.

(The Updates panel's "What's changing…" gate already keys off
`detailsAvailable`; `sbomChanges` non-empty also makes details available.)

## Data flow

```
[Apply, after a successful rebuild]
  sbomnix /run/current-system --cdx  ──▶ strip volatile  ──▶ ~/nixblitz/sbom.cdx.json
     └─ git commit "Update SBOM"   (its diff = this Apply's package-version delta)

[Check, substitute-only candidate]
  sbomnix <candidate toplevel> --cdx ──▶ components(candidate)
  readComponents(~/nixblitz/sbom.cdx.json) ──▶ components(committed)
  diffComponents(committed, candidate) ──▶ CheckResult.sbomChanges
     └─ shown in "What's changing…" → Package versions (preview; commits at next Apply)
```

## Feasibility / cost (validate during implementation)

- `sbomnix` 1.8.0 is in the pinned nixpkgs. ✓
- **Measure sbomnix on the target Pi 5** (a ~1000-component closure walk). Apply
  post-rebuild generation is one-shot and the rebuild already took minutes, so a
  30s–2min SBOM is acceptable there. The Check look-ahead adds another run to an
  already 1–10 min check. **Fallback if it's too slow on a Pi:** keep the
  Apply-time committed SBOM (the firm requirement) and drop the per-check
  candidate look-ahead (or gate it behind a setting). The look-ahead is the
  cuttable half; the committed history is not.
- First Apply on a node with no `sbom.cdx.json` yet → generate + commit the
  initial baseline; `diffComponents` against an empty/absent committed file
  treats everything as `added` (so the first look-ahead is noisy — acceptable,
  or suppress the all-added first diff).

## Testing

- **common unit** — `diffComponents`: changed version, added, removed, no-change
  → empty, sorting; `readComponents` parses a small CycloneDX fixture (and
  empty/missing → empty map); `SbomChange` JSON round-trip; `CheckResult` round-
  trips `sbomChanges`.
- **Manual (on a node/VM)** — Apply → `~/nixblitz/sbom.cdx.json` appears and is
  committed with `Update SBOM`; a subsequent Apply that bumps a package shows
  that delta in the file's git diff. A Check with a substitutable update lists
  the version changes under "What's changing… → Package versions". Confirm the
  volatile-field strip means re-generating with no package change yields no git
  diff.

## Not changing

- The Updates screen layout (the two-row panel), the check probe, dry-run /
  compile-bail, staging mechanics, and the Apply rebuild itself — this adds the
  SBOM steps + one details section, it doesn't restructure them.
- Plugin/infra update detection.

## Out of scope

- **CVE / grype scanning** and any alerting (the SBOM enables it later; explicitly
  deferred).
- Any **central / CI** scan (parallels the deferred Pi-CI work; nodes are
  autonomous).
- SBOM signing/attestation, dependency-track upload, SPDX output.
- Making the SBOM diff _replace_ the nvd diff (kept additive for now).
