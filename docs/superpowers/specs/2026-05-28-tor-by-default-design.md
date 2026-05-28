# Tor-by-default for the Bitcoin/Lightning stack — design

> Make Tor the default transport for the node's Bitcoin and Lightning
> services. New installs route bitcoind + lnd + clightning over Tor;
> existing nodes flip to Tor on their next rebuild. One node-wide
> operator switch turns it all off.

## Context

Today the bitcoind / lnd / cln plugins configure their nix-bitcoin
services with no Tor wiring, so a fresh node talks to peers over
clearnet and exposes its IP. We want privacy-by-default: the node's
Bitcoin and Lightning traffic should ride Tor unless the operator
opts out.

Only the **bitcoind** plugin imports nix-bitcoin
(`nixosModules.default`) — lnd/cln deliberately do NOT, because that
module is an anonymous inline module the NixOS module system can't
deduplicate across importers (double-import collides on
`nix-bitcoin.useVersionLockedPkgs`). lnd/cln rely on bitcoind's
import to bring `services.lnd` / `services.clightning` into scope and
just _set_ those options. Setting a nix-bitcoin option is fine from
any plugin; only `imports` is restricted. That distinction is what
lets each plugin torify _itself_ without bitcoind reaching into its
siblings.

## Key decisions (locked in brainstorming)

- **Scope: the whole node stack** — bitcoind + lnd + clightning, not
  just bitcoind.
- **Mode: full Tor enforce** — outbound peer traffic through Tor's
  SOCKS proxy (`tor.proxy`), inbound via onion services, clearnet
  blocked for these services (`tor.enforce` firewalls to
  localhost/link-local). Tradeoff accepted: initial block download is
  slower over Tor.
- **Enforce scope: node services only** — the rest of the host (SSH,
  Nix substituters, system updates) stays clearnet. Rebuilds stay
  fast; LAN SSH still works.
- **Existing installs: flip everyone** — the default resolves _on_
  even for configs that predate the flag, so they switch to Tor on
  next rebuild. Strongest privacy; disruption to an existing node's
  channel peers (onion address change) is accepted.
- **Flag home: a node-wide System setting** (`config.system.tor`),
  not a bitcoind plugin field. It's genuinely a node-wide posture,
  and a system-level flag is a reusable primitive any plugin can read
  (see "Future"). Costs a schema bump + migration, accepted for the
  cleaner model.
- **Wiring ownership: each plugin self-torifies.** bitcoind owns its
  own service + the shared `services.tor` daemon enablement; lnd owns
  lnd's Tor; cln owns cln's. No plugin reads or sets a sibling's
  options.
- **Tor applies on every network, regtest included.** Originally
  regtest was exempt (no real peers to anonymize), but the onion is
  valuable beyond P2P privacy: it lets the web UI (and RPC) be reached
  without port-forwarding, which is just as useful on a dev/regtest
  box. So `torEnabled` follows the node-wide flag alone, with no
  network gate. Bonus: lnd/cln no longer need to read
  `config.services.bitcoind.regtest`, so they have zero cross-service
  reads.

## nix-bitcoin Tor model (verified against the pinned rev)

Confirmed by reading the vendored nix-bitcoin source
(`examples_redesign/nix-bitcoin/`, the rev pinned at
`bitcoind/plugin.nix`'s `nixBitcoinRev = c4891858…`):

- Each service carries a shared `tor` option block
  (`pkgs/lib.nix:66` — `tor.proxy`, `tor.enforce`):
  - `tor.proxy = true` → route outgoing connections through Tor's
    SOCKS proxy. bitcoind gets `proxy=…` in bitcoind.conf
    (`modules/bitcoind.nix:320`); lnd gets `tor.active=true` +
    `tor.socks=…` (`modules/lnd.nix:175`); clightning gets
    `proxy=…` + `always-use-proxy` (`modules/clightning.nix:120`).
  - `tor.enforce = true` → restrict the service to localhost/
    link-local addresses (`nbLib.allowedIPAddresses cfg.tor.enforce`),
    blocking clearnet.
- Inbound onions: `nix-bitcoin.onionServices.<svc>.enable`
  (`modules/onion-services.nix`). The option is a generic
  `attrsOf submodule` (`onion-services.nix:11`) that works for any
  service defining `address` + `port`; it builds a Tor hidden service
  (`services.tor.relay.onionServices.<svc>`) forwarding the onion
  port to the service's local listen port. A service's onion is only
  created when **both** `config.services.<svc>.enable` and
  `onionServices.<svc>.enable` are true (`onion-services.nix:48`), so
  enabling an onion for a service that isn't running is a harmless
  no-op. Setting `public = true` makes the onion address available to
  the service so it announces it to peers (drives `getPublicAddressCmd`,
  `onion-services.nix:99`).
- **All three of our services qualify for the uniform onion path.**
  bitcoind binds its onion directly (`bind=…=onion`,
  `bitcoind.nix:316`) and announces it itself, so it needs
  `onionServices.bitcoind.enable` without `public`. clightning
  (`clightning.nix:138`) and **lnd** both define `address` + `port`
  (`lnd.nix:7,12`) and announce the generic onion via
  `externalip` / `announce-addr` when `public = true`. lnd is absent
  from nix-bitcoin's _preset_ list, but that is a nix-bitcoin policy
  choice, not a technical limit — the generic mechanism applies to it.
  (lnd's own `tor.v3` controller path is the alternative, but it would
  require enabling the Tor control port + cookie access, which this
  rev's lnd module does not wire up; the generic onion is the simpler,
  uniform route. Confirmed inbound in the VM test below.)
- nix-bitcoin's own `presets/enable-tor.nix` does exactly this
  combination for the full service list; we replicate only the subset
  for our three services, per-plugin, gated on the operator flag
  (importing the preset is all-or-nothing and centralizes wiring we
  want distributed).

## Repository layout — this spans two repos

The change lands in **two separate repositories**:

- **nixblitz_ng** (this repo, jj-managed): the `SystemConfig` field +
  schema migration + unit tests, the TUI System-tab toggle, and the
  `nixblitz.system` read-option + `installed.nix` feed.
- **nixblitz_official_plugins** (a _separate_ git repo, vendored at the
  gitignored `examples_redesign/nixblitz_official_plugins/`): the
  per-plugin Tor wiring in `bitcoind/`, `lnd/`, `cln/`. Nodes fetch
  these from `forge.f44.fyi/f44/nixblitz_official_plugins` at rebuild,
  so the plugin edits need their own commit in that repo, a plugin
  `version` bump (behavior change → new version per the manifest
  versioning), and a push before any node picks them up. Treat the
  plugin-repo work as a distinct, releasable unit.

## Architecture

### 1. Config surface — a node-wide System setting

`SystemConfig` (`common/lib/src/models/nixblitz_config.dart`) gains a
`bool tor` field, default `true`:

- Add to the constructor (`this.tor = true`), `SystemConfig.defaults()`,
  `fromJson` (`tor: json['tor'] as bool? ?? true`), `toJson`
  (`'tor': tor`), `copyWith` (`bool? tor`), `==`, and `hashCode`.

Schema bump (`common/lib/src/models/config_migrations.dart`):

- `system.tor` is an **additive** field — `SystemConfig.fromJson`
  defaults an absent `tor` to `true`, and the Nix side reads
  `or true`. That additive default is precisely what delivers "flip
  everyone": an existing config with no `tor` key resolves to Tor-on.
  So **no data-transforming migration is required** (matches the
  v14→v15 `disk_device` and v15→v16 `shell` additive precedents).
- Still bump `currentConfigVersion` 18 → 19 with a no-op
  `18: (json) => json` entry, because the on-disk `.nix` templates
  change (the new `nixblitz.system` option) — the version bump is what
  triggers the TUI's startup template auto-refresh on existing
  installs. Comment the entry with the reason, like the other
  template-refresh bumps.

TUI (`tui/lib/src/ui/views/configure_view.dart`):

- The System tab gains a boolean row labeled "Route node traffic over
  Tor", toggled the same way the existing `shell` field cycles
  (Enter flips the bool, writes `config.system.copyWith(tor: …)`).

### 2. Exposing the flag to Nix

`templates/modules/system/nixblitz-options.nix` declares a second
read-only option mirroring the existing `nixblitz.appConfigs`:

```nix
options.nixblitz.system = lib.mkOption {
  type = lib.types.attrsOf lib.types.unspecified;
  default = {};
  description = ''
    The `system.*` block from `~/nixblitz/config.json`, exposed for
    module-level reads. E.g. plugins read
    `config.nixblitz.system.tor or true`.
  '';
};
```

`templates/hosts/installed.nix` feeds it (one line, beside the
existing `nixblitz.appConfigs = apps;` at line 40):

```nix
nixblitz.system = sys;   # sys = cfg.system, already bound at line 8
```

Any module then reads `config.nixblitz.system.tor or true` — absent
⇒ `true` (covers existing configs that haven't been migrated yet).

### 3. Per-plugin self-torification

Each plugin's `plugin.nix`, in its existing `config = lib.mkIf
enabled { … }` block, adds Tor wiring gated on
`torEnabled = config.nixblitz.system.tor or true`. No plugin touches
another's options.

All three use the same gate — the node-wide flag alone, no network
condition:

```nix
torEnabled = config.nixblitz.system.tor or true;
```

The per-service `tor` block goes INSIDE the existing `services.<svc> =
{ … }` assignment (a sibling `services.<svc>.tor = …` line would
collide with the direct `services.<svc> = { … }` — "attribute already
defined"). The onion + daemon entries are separate paths and sit as
siblings in `config`.

**bitcoind** (`examples_redesign/nixblitz_official_plugins/bitcoind/plugin.nix`):

```nix
# … inside config = lib.mkIf enabled { … }:
services.bitcoind = { /* existing … */ tor = lib.mkIf torEnabled { proxy = true; enforce = true; }; };
services.tor = lib.mkIf torEnabled { enable = true; client.enable = true; };
nix-bitcoin.onionServices.bitcoind.enable = lib.mkIf torEnabled true;
```

**lnd** (`…/lnd/plugin.nix`):

```nix
# … inside config = lib.mkIf enabled { … }:
services.lnd = { /* existing … */ tor = lib.mkIf torEnabled { proxy = true; enforce = true; }; };
nix-bitcoin.onionServices.lnd = lib.mkIf torEnabled { enable = true; public = true; };
```

**cln** (`…/cln/plugin.nix`):

```nix
# … inside config = lib.mkIf enabled { … }:
services.clightning = { /* existing … */ tor = lib.mkIf torEnabled { proxy = true; enforce = true; }; };
nix-bitcoin.onionServices.clightning = lib.mkIf torEnabled { enable = true; public = true; };
```

bitcoind owns the shared `services.tor` daemon enablement (a system
dependency present whenever the family runs) plus its own service;
lnd and cln each own only their own service. `services.tor.enable =
true` is a bool — if more than one plugin sets it, the values merge
without conflict, so the design is robust even if the daemon
enablement is later duplicated.

## Testing

- **Unit (common):**
  - `SystemConfig` JSON round-trip: with `tor` present (both values)
    and absent (defaults to `true`).
  - `migrateConfig` on a v18 config bumps its version to 19 (no-op
    transform). An existing v18 config with no `tor` key reads back as
    `tor == true` (additive default); a config carrying
    `system.tor = false` round-trips `false` (not clobbered).
  - `SystemConfig.defaults().tor == true`.
- **Config eval matrix (#26 harness, `tests/config/default.nix`):**
  the existing base-config matrix continues to pass after the
  `nixblitz.system` option + feed land (it declares + feeds the option
  but no base module reads it — this only confirms the additions don't
  break evaluation). The harness **cannot** verify the plugin Tor
  wiring: it deliberately loads only `templates/modules` + the
  plugin-free base fixture, so resolving bitcoind/lnd/cln would pull
  nix-bitcoin and the plugin repo — exactly the closure the harness
  exists to avoid. No Tor fixture is added there.
- **Plugin eval (nixblitz_official_plugins, optional):** the plugins'
  own `check-plugin-consistency.sh` continues to pass. A full eval of
  a bitcoind+lnd+Tor config requires nix-bitcoin and is heavy; it is
  covered by the VM test rather than a cheap eval gate.
- **Manual (VM / `just vm-boot`):**
  - Install bitcoind + lnd, rebuild. `bitcoin-cli getnetworkinfo`
    shows a local onion address and `"proxy"` set to the Tor SOCKS
    endpoint; `lncli getinfo` shows a `.onion` URI in `uris`.
  - Toggle Tor off on the System tab → Apply → rebuild → clearnet
    restored (no onion, no `proxy=`).
  - Confirm SSH and `nixos-rebuild` (substituter fetches) still use
    clearnet — the host is not torified, only the node services.
- `just test; just analyze; just format` green.

## Out of scope

- **Host-wide Tor** — substituters / SSH over Tor. Rebuilds would
  crawl and SSH would need an onion/LAN exception. Node services only.
- **Per-service granularity** — one switch governs the whole family;
  no "Tor for bitcoind but not lnd".
- **Tor for non-nix-bitcoin plugins now** (blitz-api, etc.) — not
  built in this change (see "Future").
- **Bridges / pluggable transports** — censorship-circumvention
  transport config is a separate concern.
- **Onion-only vs. dual-stack inbound tuning** — we take
  nix-bitcoin's defaults.

## Future: plugin-declared onion services

The `config.nixblitz.system.tor` flag is a reusable, node-wide
primitive, not a Bitcoin-family detail. A future non-nix-bitcoin
plugin that wants to expose itself over Tor reads the same flag and
declares a **stock NixOS** hidden service for its own local port (not
`nix-bitcoin.onionServices`, which is nix-bitcoin-only):

```nix
config = lib.mkIf (enabled && (config.nixblitz.system.tor or true)) {
  services.tor.enable = true;                 # bool merges across plugins
  services.tor.relay.onionServices.myplugin.map = [
    { port = 80; target = { addr = "127.0.0.1"; port = 3000; }; }
  ];
};
```

Contract: gate on the _flag_ (`config.nixblitz.system.tor`), self-
enable the daemon, declare your own onion. Do **not** gate on
`config.services.tor.enable` (the daemon's current state is
order/presence-dependent). This works even on a node with no Bitcoin
family installed.
