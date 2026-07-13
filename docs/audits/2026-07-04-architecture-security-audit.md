# NixBlitz architecture & security audit — 2026-07-04

Status: living document (findings + remediation roadmap)

## Scope & method

A high-level pass over the whole system, split across five areas: the `common`
business-logic package, the `tui` frontend, the `templates/` NixOS modules that
define a running node, the top-level build/ops layer, and the official plugins
repo (`examples_redesign/nixblitz_official_plugins/`, a separate git repo). The
goal was an improvement overview across ease-of-use, security, maintainability,
code simplification, and a possible lockdown mode.

Headline claims below were spot-checked against source; file:line references are
included so each item is independently verifiable.

## What is already good (keep it)

- **Declarative single source of truth.** `~/nixblitz/config.json`, git-tracked,
  every change visible in the Apply diff. No imperative "edit system state".
- **Localhost-first services** with opt-in `open_firewall` flags; Tor on by
  default at the service level.
- **Honest plugin trust model** (D14): install = root grant, stated plainly, no
  heuristic "verification" theater.
- **SudoSession**: password zeroed after use, never persisted or logged; every
  `Process` call uses list-args (no shell-injection surface found).
- **Commit-reviewed Apply transaction** with commit-on-success (rebuild the dirty
  tree first, commit config + lock + SBOM only on success).
- **Commit-SHA plugin pinning**; bitcoin family shares one CI-checked nix-bitcoin
  rev.

## Findings

Severity: **H** high, **M** medium, **L** low. Status: `[ ]` open, `[x]` done,
`[~]` in progress, `[→]` deferred/needs decision.

### Security

- `[→]` **L (was overstated as H) — Default password window.**
  `templates/hosts/installed.nix:86` ships `initialPassword = "nixblitz"` on the
  `admin` account. Corrected understanding: this is only the _account-creation_
  password. The first-run wizard's step 1 (`setup_view.dart:791`) runs
  `sudo chpasswd admin:<new>`, and because `mutableUsers` is left at its default
  `true` and `initialPassword` is create-time-only, that change **persists** —
  later Apply/rebuilds never revert to `nixblitz`. So there is no _persistent_
  shipped default; setup forces the change. Residual risk is narrow: the window
  between install and completing set-password (sshd is up from boot with the
  known password if the fresh node is already networked), plus an operator who
  re-types `nixblitz` (their choice). **Deferred** (2026-07-04): dev-convenience
  default kept intentionally; no gate wanted while pre-release with no real users.
- `[ ]` **L — SSH hardening not explicit.** `installed.nix:93` enables OpenSSH
  with NixOS defaults: password auth on, no explicit `PermitRootLogin`. Fine as a
  default given the above; a natural thing for **lockdown mode** to tighten
  (`PasswordAuthentication = false`, `PermitRootLogin = "no"`).
- `[→]` **H — Cleartext secrets path through config.json.** Plugin manifest
  `type: "secret"` fields are stored cleartext in the git-tracked config.json,
  and any `pluginCfg` value lands readable in `/nix/store`. No official plugin
  uses it today (tailscale/netbird use ephemeral `/run` action inputs), so the
  exposure is latent. Fix candidates: deprecate `type: secret` in favour of
  action inputs + a token-file convention (cachepop already does this), or
  integrate systemd `LoadCredential`/sops-nix. **Minimum fix shipped:** the
  install consent (CLI + TUI) now warns loudly when a manifest declares
  `type: secret` fields (`PluginInstallPreview.secretFieldNames`), naming the
  fields and the cleartext-in-git + world-readable-in-store consequences. The
  structural fix (secret store / LoadCredential) remains open.
- `[ ]` **M — ZMQ binding dance.** bitcoind publishes ZMQ on 0.0.0.0 and each
  consumer overrides to 127.0.0.1 individually; a missed override leaks block/tx
  events to the LAN. Invert: force localhost at the bitcoind plugin, opt out later.
- `[ ]` **M — Uneven systemd hardening.** cachepop is exemplary
  (`ProtectSystem=strict`, `PrivateTmp`, `LockPersonality`); others delegate to
  nix-bitcoin/upstream. A shared hardening mixin for plugin-declared oneshot
  units would raise the floor.

### Official plugins (`examples_redesign/nixblitz_official_plugins/`)

- `[x]` **M — blitz-web opens port 80 by default.** `blitz-web/plugin.nix:12`
  defaults `open_firewall` to `true` — the only official plugin that opens a port
  by default. Changed to `false` to match electrs/lnbits. **Follow-up:** the
  `plugin.json` config_schema still seeded `open_firewall` default `true` (what
  the TUI writes into config.json), so the nix-side change alone wasn't enough —
  the manifest default is now `false` too.
- `[x]` **L — LND `alias` unescaped into `extraConfig`.** `lnd/plugin.nix:44`
  writes `alias=${alias}`; a newline injects an arbitrary lnd config line
  (operator-controlled, low severity, but the reference implementation others
  copy). Sanitized by stripping CR/LF.
- `[x]` **L — electrs `${address}` unquoted in `/dev/tcp`** tile probe. Safe in
  practice (bash `/dev/tcp` doesn't expand), but a bad example to copy. Quoted.
- `[x]` **L — Inconsistent `permissions` blocks.** All 10 plugins now declare a
  top-level `permissions` block (previously only electrs/lnbits/tailscale/netbird
  did). The new blocks are honest and terse: bitcoind → `network:outbound`
  (P2P/Tor); lnd/cln → `bitcoin:rpc:read` + `lightning:wallet:read/write` +
  `network:outbound`; blitz-api → `bitcoin:rpc:read` + `lightning:wallet:*`;
  cachepop → `network:outbound` (Attic push); blitz-web → `{}` (static UI, no
  bitcoin/LN/privileged access). Still informational only (D14).
- `[~]` **L — README + LICENSE.** README now lists all 10 plugins (was 4).
  **Per-plugin LICENSE files still missing** — deferred: which license to apply
  is the maintainer's call, not something to invent.
- `[ ]` **L — Boilerplate:** tile-state and app-version scripts repeat across
  plugins; a shared `lib/` would help third-party authors.

### Ease of use

- `[x]` **M — Silent sudo-auth failure.** The password modal used to re-appear on
  a wrong password with only an "attempt N of 3" reason. The retry now leads with
  an explicit "Incorrect password — try again" heading so the operator knows the
  last attempt was rejected. (Final give-up surfacing stays a per-caller concern.)
- `[x]` **M — CLI/TUI consent asymmetry.** **Finding was WRONG** — verified
  against source + history: `plugin_cli.dart`'s `_askConsent` has shown the full
  consent (URL, branch, rev, schema, signature fingerprint, root-grant warning,
  `--yes` bypass) since the Approach-A trust work (`ba5d3d9`). The audit's survey
  agent misreported it; no code change needed. Kept as a record of the
  correction.
- `[ ]` **L — Setup wizard ends without a success screen** (drops to dashboard);
  add a "you're done / here's what's running / next steps" summary.
- `[ ]` **L — Mnemonic screen** shows the seed with no rationale for why it can't
  be copied; one explanatory sentence.

### Maintainability

- `[~]` **M — Architecture-rule violations:** views run `Process`/`File` directly,
  violating "only `common` calls Process". **Done — no `Process` spawn remains in
  the `tui` UI package.** The core flows (`install_view`, `setup_view`,
  `apply_view`) went through `common` first (shared `runCheckedSync`,
  `GitService.initSync`/`commitAllSync`, `ScaffoldService.clearTargetSync`/
  `writeStrippedHardwareConfigSync` with the pure `stripHardwareConfigMounts`,
  `SystemService.currentSystemToplevel`, `StagingService.promoteLockTo`,
  `environment_service`). Then the 5 `debug/` views (systemctl / journalctl /
  bitcoin-cli) moved to an async `runChecked` twin plus `writeExecutableScriptSync`
  for regtest-automine's helper script. **Remaining (File reads only, no process
  spawns):** `app.dart`'s bootstrap `config.json` reads and `apply_view`'s two
  file reads (teardown current-file, update-status) — a small later pass.
- `[x]` **M — No CI.** Added a fast `just ci` gate (test + analyze + template
  freshness + Dart format check) and `.forgejo/workflows/ci.yml` running it on
  push/PR. The workflow needs a self-hosted runner labeled `nix`; until one is
  registered it stays inactive (blocks nothing). Heavy config-eval (`test-config`)
  stays separate.
- `[x]` **M — Embedded-template sync unenforced.** Added `just check-templates`
  (in the `ci` gate): regenerates `embedded_templates.g.dart` and fails on any
  content drift. **On its first run it caught a real, already-shipped bug** —
  `embedded_templates.g.dart` was last regenerated at `1ed14e8`, predating the
  `sbomnix`-into-`base.nix` change (`f837645`/`1d00bb6`), so the embedded
  templates the TUI scaffolds onto nodes had **no `sbomnix`**. The strict
  commit-on-success SBOM step would therefore fail on a real node (sbomnix not on
  PATH). Fixed by regenerating; the guard prevents a recurrence.
- `[ ]` **L — nixpkgs fork is load-bearing** (`dart-workspace-member-filter`);
  needs periodic rebasing. Track an upstreaming attempt / write down the rebase
  procedure.
- `[ ]` **L — Test gaps in common:** `staging_service`, `applied_state_service`,
  `scaffold_service`, `sbom_service` untested.
- `[ ]` **L — Docs drift:** `plugin-authoring.md` documents manifest schema v2;
  official plugins are on v4.

### Code simplification

- `[~]` **M — Split large services:** **`PluginService` done** — split into
  `services/plugin/`: `plugin_url` (parse), `plugin_git_ops` (fetch — clone /
  rev-parse / symlink-reject / manifest-read as free functions), and
  `plugin_refresh_all_result`. Facade re-exports the public types; the class
  dropped ~1195 → ~760 lines, tests pass unchanged. **`UpdateCheckService` done**
  (~1239 → ~650): extracted the pure data types + nix dry-run parser
  (`services/update/update_check_types.dart`), the flake.lock / URL parsers as
  free functions (`services/update/flake_lock_parse.dart`), and the HTTP
  version-probing core into an `UpstreamProber` collaborator
  (`services/update/upstream_prober.dart`) that owns the http client — the
  service constructs one and delegates `queryUpstreamRev` / `fetchManifestAt` /
  `isCommitReachable` / `findIntroducingCommit` to it. The service now holds only
  orchestration + persistence. All re-exported / delegated so `check_runner` and
  the tests are unchanged (bar dropping the `UpdateCheckService.` prefix on the
  moved parsers). Behaviour-preserving; update tests pass at every step.
- `[x]` **M — `runChecked()` process helper** in common: added `runCheckedSync`
  (`process_runner.dart`) — one place that runs a command, logs `exe args → exit`
  uniformly, and optionally throws on failure. The migrated view flows now route
  through it. Remaining raw `Process` sites (debug views, app.dart) can adopt it
  as they're migrated; an async `runChecked` twin can be added when a caller needs it.
- `[x]` **L — Atomic config writes:** `config_service.dart` wrote config.json in
  place; now temp-file → rename so a mid-write crash can't corrupt it. This
  exposed a latent bug in `config_watcher_provider.dart`: an atomic rename
  surfaces as a `FileSystemMoveEvent` whose `path` is the temp file, so the
  watcher missed the write. Fixed to also honour the move `destination` — now
  robust to any atomic-rename writer (editors, CLI tools), not just ours.
- `[ ]` **L — TUI widget dedup:** shared selection-popup/modal base (viewport
  clamp, j/k/Enter/Esc, try/catch wrapper) and a `SelectableListView`.
- `[ ]` **L — `check` subprocess:** the TUI spawns `nixblitz check` as a child
  while the CLI calls `UpdateCheckService` directly; unify on the direct call.

## Lockdown mode (design sketch)

A `system.lockdown` boolean in config.json, gated in the NixOS templates (so the
guarantee holds even for a hand-edited config), visible in the Apply diff like
everything else. It flips convenience → security:

| Convenience today                         | Under lockdown                                        |
| ----------------------------------------- | ----------------------------------------------------- |
| SSH password auth (NixOS default)         | Keys only, `PermitRootLogin no`                       |
| `initialPassword = "nixblitz"`            | Assertion fails build until a real credential is set  |
| `open_firewall` flags honoured            | Assertion rejects any opened port (Tor/VPN-only)      |
| Sudo timestamp cached ~10 min + keepalive | Keepalive off, prompt per privileged action           |
| Plugin add from any HTTPS/`github:` URL   | Operator-editable allowlist; signature required       |
| Unpinned plugins auto-advance on check    | All treated as pinned; advancing needs explicit unpin |
| Debug menu (`[D]`) compiled in            | Hidden/disabled                                       |

Notes: (1) keep the plugin item honest — an allowlist restricts _who_ you trust,
not what plugin code can do; the consent screen must keep saying so. (2) Prefer
NixOS-module assertions over TUI-side checks. (3) Lockdown can't fix the
wheel-group model (any wheel member is root-equivalent) — that's a documented
stance, not a gap. This warrants a proper brainstorm/spec before implementation.

## Suggested sequence

1. SSH / default-password hardening (smallest diff, biggest real-world risk) —
   needs the posture decision.
2. Atomic config write + blitz-web firewall default + LND alias escaping —
   done in this pass.
3. Minimal CI + embedded-template drift check.
4. View→common `Process` migration (+ `runChecked` helper).
5. Lockdown mode as a designed feature.
6. Service splits + TUI dedup as ongoing hygiene.
