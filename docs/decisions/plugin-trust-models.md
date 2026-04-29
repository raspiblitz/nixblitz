# Plugin trust models — comparison

> Sibling doc to `plugins.md`, focused on a narrower question:
> what should the consent prompt verify _about who published the
> plugin_, beyond the metadata in `manifest.json`? Two candidate
> mechanisms are compared honestly, with explicit notes on what
> each does and doesn't prevent.

---

## 0. Read this first

This doc is **not** about preventing a malicious plugin from doing
damage. `plugins.md` D14 already says the load-bearing thing
about that:

> Installing a plugin is equivalent to granting root. `plugin.nix`
> runs at `nixos-rebuild` time as root and can declare arbitrary
> systemd services, activation scripts, or external dependencies.
> The consent prompt is consent to run that code, not a sandbox.

That trust model is unchanged by anything in this doc. Both
approaches discussed here are **identity-continuity tools** —
they help the operator notice when the _publisher_ changes. They
do not audit code, they do not score safety, they cannot be
combined into a system that "checked the plugin for you."

If the framing of either section starts to drift toward
"installing this plugin is now safe," stop reading and re-read
this preface. The mistake to avoid is the one #10 (permission
preview) and #17 (regex risk surface) made: a programmatic
signal that _looks_ like verification but isn't.

---

## 1. Context

The current consent prompt (`tui/lib/src/cli/plugin_cli.dart`
`_askConsent`) shows:

- Plugin name + description (from `manifest.json`)
- Source URL + branch + 40-char pinned rev
- Schema version
- A stark warning that installing grants the author root

What it deliberately does **not** show: any field labelled
"permissions" or "verification status." That's intentional — see
D14.

The remaining gap is _identity continuity_. The operator consents
to a 40-char SHA, and that's it. Today's prompt cannot answer:

- "Did the same person who published the rev I trusted last time
  also publish this rev?"
- "Is the publisher of this brand-new plugin known to anyone I
  trust?"

Two mechanisms could close those questions. Neither closes the
underlying "the publisher could be malicious" question.

---

## 2. What each approach actually verifies

| Question                                                 | A: Git+TOFU    | B: Nostr WoT     |
| -------------------------------------------------------- | -------------- | ---------------- |
| "Is this commit signed by the key I trusted last time?"  | Yes            | No               |
| "Is the publisher followed by people I trust?"           | No             | Yes              |
| "Is the publisher's identity widely known?"              | No             | Partial[^1]      |
| "Does this plugin do what it claims to do?"              | No             | No               |
| "Can a compromised publisher push malicious code?"       | Yes (accepted) | Yes (accepted)   |
| "Can a malicious-from-day-one publisher pass the check?" | Yes (TOFU)     | Yes (sybil-able) |
| "Can a malicious forge MITM the install?"                | No (sig fails) | Partial[^2]      |
| "Can a malicious relay MITM the install?"                | n/a            | Partial[^2]      |

[^1]:
    "Widely known" is a synthesis of zaps targeting the
    publisher, NIP-05 verification, follower count, and overlap with
    the operator's own follow list. None of those individually proves
    identity — they cluster.

[^2]:
    Nostr event signatures prove the metadata event was signed
    by the publisher's pubkey. They don't bind the metadata to a
    specific git rev unless the manifest explicitly does so. Zap
    Store solves the analogous problem by embedding the APK SHA-256

- certificate hashes in the metadata event; an equivalent bind
  for NixBlitz would put the git rev (already in the URL) inside
  the Nostr release event.

The most important row in this table is the third-from-bottom:
**both approaches accept a compromised publisher**. They detect
_changes_ in publisher identity, not malice from a stable
identity.

---

## 3. Approach A — git commit signing + TOFU

### 3.1 How it works

1. After the plugin tmpdir is cloned, run `git verify-commit HEAD`
   against it. The exit code reports whether the rev is signed by
   _any_ valid key the operator's git config recognises.
2. Capture the signing key fingerprint via
   `git log -1 --format='%GF'` (SSH-signed) or `'%GP'` (GPG).
   These format placeholders return the public key fingerprint in
   a stable form.
3. On first install, the operator sees the fingerprint in the
   consent prompt and decides whether to proceed. The fingerprint
   is stored on the `PluginEntry`.
4. On every subsequent refresh, re-verify and compare against the
   stored fingerprint. Mismatch → escalate to a "publisher key
   has changed" warning that requires re-consent.

### 3.2 NixBlitz integration

Concrete hook points (from a code-trace pass):

- `common/lib/src/services/plugin_service.dart` —
  between `_gitRevParseHead()` (the call after `_gitClone()` in
  install at ~line 76 and refresh at ~line 310) and
  `_readManifest()`. The tmpdir is alive across this window.

  ```dart
  // Pseudo:
  await _gitClone(...);
  final pinnedRev = await _gitRevParseHead(tmpDir.path);
  final sig = await _verifyCommitSignature(tmpDir.path);
  // sig is GitSignature?: null = unsigned, populated = fingerprint+identity
  ```

- `common/lib/src/models/plugin/plugin_entry.dart` — add an
  optional field:

  ```dart
  /// Fingerprint of the SSH or OpenPGP key that signed the
  /// commit at [pinnedRev]. Captured on install when the rev
  /// is signed; null when the operator consented to an
  /// unsigned commit. On refresh, mismatch → re-consent.
  final String? signatureFingerprint;
  ```

  JSON-serializable, default null for backward compat. No
  migration needed — old `config.json` rows just have a missing
  field that decodes to null.

- `tui/lib/src/cli/plugin_cli.dart` `_askConsent` — surface the
  signature line:

  ```
  pinned rev:    ab12cd34…
  signed by:     SSH key SHA256:abc123…   (key id: alice@example.com)
  ```

  or, on refresh-mismatch:

  ```
  WARNING: this rev is signed by a DIFFERENT key than the one
  you pinned at install time.
    pinned key:  SSH key SHA256:abc123…   (alice@example.com)
    new key:     SSH key SHA256:def456…   (eve@example.com)
  Re-consenting will overwrite the pinned key. Read the source
  carefully if you weren't expecting a publisher change.
  ```

  unsigned-commit case:

  ```
  signed by:     (UNSIGNED — no signature on this commit)
  ```

  This is informational, not blocking. Operator can still
  proceed, but they're explicitly told.

### 3.3 Trusted-key storage

Two design choices for "where do trusted keys live":

- **Per-plugin pinning only** (recommended). The fingerprint
  lives on the `PluginEntry`. No separate trust file. Simplest,
  most honest — there's no "globally trusted publisher" concept
  to game.
- **Leverage `~/.ssh/allowed_signers`**. Works if the operator
  has already configured SSH commit-signing locally. Wider
  surface (a single trusted entry covers all plugins from that
  publisher) but creates an implicit trust transitive between
  plugins that the operator may not intend.

The doc recommends the per-plugin path. It maps 1:1 onto the
existing `pinnedRev` mental model: each plugin has one rev, one
fingerprint, one consent.

### 3.4 Test-harness implications

The existing `hermeticGitConfigArgs` in
`common/test/test_helpers/git_isolation.dart` explicitly disables
signing (`commit.gpgsign=false`, `tag.gpgsign=false`). That stays
— production code path needs the _opposite_: explicitly _allow_
signature config to flow through to `git verify-commit`. Two
distinct git-env profiles: one for hermetic tests (no signing),
one for verification (operator's actual GPG / SSH config visible).

### 3.5 Pros

- **Cheap to implement.** ~half a day. Three small additions
  (model field, verify call, consent line) plus tests.
- **Verifies forge-side integrity.** A malicious mirror can't
  swap a rev without breaking the signature — `git verify-commit`
  catches it.
- **TOFU is a well-understood mental model.** SSH host keys,
  package-manager keyrings, etc. The consent prompt's "key
  changed" warning maps onto patterns operators already
  recognise.
- **No new dependencies.** Git already does the work.
- **Composes with the existing `pinnedRev` mechanism.**
  Fingerprint is just one more field on the entry the operator
  already pins.

### 3.6 Cons

- **Only meaningful if plugin authors actually sign commits.**
  None of the in-tree dogfood plugins do today. This becomes a
  social / convention layer that needs adoption before any signal
  is available.
- **TOFU doesn't help against day-one malice.** "First install
  was secure" is an assumption the system can't verify.
- **No identity introduction.** Tells the operator nothing about
  _who_ the publisher is — only that they're the same as last
  time.
- **SSH signing UX on the publisher side is fragile.** The
  `x11-ssh-askpass` issue this session bumped into is exactly
  the friction. Plugin authors may not enable signing because
  the workflow is annoying.

### 3.7 Variant: signed tags instead of signed commits

`git verify-tag` is an option for plugins that ship signed
release tags rather than per-commit signatures. Cleaner publisher
UX (sign once per release, not every commit) but requires plugin
refresh to track tags rather than branch HEADs — orthogonal to
this doc; skip for v1.

---

## 4. Approach B — Nostr web of trust

### 4.1 How it works

Plugin metadata is published as Nostr events under NIP-82 (the
software-publishing draft). Trust signals come from the Nostr
social graph: who follows the publisher, who has zapped (sent
sats to) the publisher, who's claimed which NIP-05 identity, etc.

The Zap Store Android app is the existing reference
implementation; its source is at `examples_redesign/zapstore/`.
The flow it implements end-to-end:

1. **Plugin / app metadata** is published as a NIP-82 software
   event (kind `32267`) authored by the publisher's pubkey,
   pointing at one or more software-asset events (kind `3063`)
   that carry the actual download URL + integrity hashes.

2. **On install**, the consumer:
   - Loads the operator's Nostr identity (via Amber on Android;
     NixBlitz would need its own key story, see §4.3).
   - Fetches the publisher's `kind: 0` profile (name, picture,
     NIP-05).
   - Fetches the operator's `kind: 3` follow list.
   - Fetches `kind: 9734` zap events targeting the plugin / publisher.
   - Issues a **DVM reputation request** (`kind: 5104`-ish; an
     off-chain query against a trusted DVM relay group, e.g.
     `vertex`) of the form "intersect my follows with people who
     follow this publisher."

3. **On the consent screen**, render:
   - Publisher's avatar + display name + NIP-05 verification
     state.
   - Mutual follows (faces of accounts the operator follows that
     also follow this publisher).
   - Zap signal — count + total sats from people the operator
     follows.

4. **TOFU pubkey pin** — operator can check "always trust this
   publisher" to skip future consent prompts (Zap Store stores
   this in a private `kind: 13572` `CustomData` event; NixBlitz
   would just put it on the `PluginEntry`).

### 4.2 NixBlitz integration sketch

**Manifest schema addition** (purely opt-in; existing manifests
without this block continue to work):

```json
"nostr": {
  "publisher_pubkey": "npub1abc…",
  "release_event":    "naddr1def…"
}
```

The `naddr` (NIP-19 encoded address) points at a NIP-82 software
event whose `e` / `a` tags name the git rev being released. That
chain — `nostr_event signed by publisher_pubkey ⟶ git_rev` —
is what binds the social-graph signals to a specific rev. Without
this bind, Nostr signatures only prove "someone with this pubkey
authored this metadata," which is weaker than the rev-pinning the
operator already has.

**PluginEntry extension** — same shape as Approach A:

```dart
final String? publisherPubkey;
```

Pinned at first install; on refresh, the new metadata event must
be authored by the same pubkey or the operator gets a "publisher
changed" warning analogous to A's key-change path.

**Consent screen** — adds a section:

```
publisher:     npub1abc…
               (alice@example.com, NIP-05 verified)
               followed by 1.2k accounts
mutual follows: 3 accounts you follow also follow this publisher
                ─ bob@nostr.example
                ─ carol@…
                ─ dave@…
zaps from your follow list: 2 zaps totalling 3,500 sats
```

(or a graceful "(no Nostr identity configured — no WoT signal
available)" fallback when the operator hasn't bootstrapped a
Nostr identity).

**Code reuse from Zap Store** (Dart/Flutter, runs on Android but
the non-Android pieces are platform-agnostic):

- `lib/services/catalog_fetcher.dart` — incremental relay
  fetching with batched REQ construction.
- `lib/widgets/relevant_who_follow_container.dart` — DVM request
  - WoT display rendering.
- `lib/services/trusted_signers_service.dart` — TOFU pubkey
  storage pattern.
- Underlying packages (`models`, `purplebase`) are the heavy
  lifters. NixBlitz could pull them as Dart deps directly.

### 4.3 Operator key story (the bootstrap problem)

To get any _personalised_ WoT signal, the operator needs a Nostr
identity with a follow list. Options:

- **Generate at first launch.** NixBlitz creates a node-bound
  pubkey and stashes the privkey alongside the existing config.
  The operator either curates a follow list themselves, or imports
  one via `nostr-import`-style flow.
- **Import an existing identity.** Operator pastes their `nsec`
  / scans a QR code. Daily-driver Nostr identity, full follow
  list available. Privkey ends up on the node — nontrivial security
  consideration for a key the operator likely uses elsewhere.
- **Anonymous mode.** No identity. WoT signals degrade to global
  signals (total follower count, total zap volume, NIP-05
  presence). Less personalised but still better than the URL
  alone.

The doc recommends supporting anonymous mode unconditionally and
treating identity import as an optional power-user path. A
node-bound generated identity has no follow list to start with,
which means it produces no signal — a worse UX than anonymous
mode.

### 4.4 Cost / complexity

- New runtime dependencies: `models` + `purplebase` Dart packages
  (~MB of transitive deps).
- Pre-consent latency: ~1-3s of relay round-trips before the
  prompt appears. Tolerable for an interactive `plugin add` but
  worth caching.
- Identity bootstrap UX (or graceful fallback to anonymous mode).
- Schema bump on `manifest.json` to add the optional `nostr`
  block (additive, no breaking change).
- Total effort estimate: **1-2 weeks** of focused work, vs.
  Approach A's **half day**.

### 4.5 Pros

- **Surfaces qualitative trust signals** the operator can reason
  about. "3 people I follow zapped this plugin" is a meaningfully
  different signal from "0 people I follow zapped this plugin."
- **Maps onto a publish/subscribe ecosystem.** Plugin authors
  push releases to relays; consumers subscribe. No second forge
  required for distribution metadata.
- **Identity introduction works for new plugins / new
  publishers.** TOFU has nothing to compare against on first
  install; WoT can show "the publisher has 800 followers" even
  for a brand-new plugin.
- **TOFU on top is free.** The publisher pubkey pin works the
  same as A's fingerprint pin.
- **Zap Store has done the legwork** on the WoT-display patterns.
  The hard parts (DVM querying, relay diversity, event-cache
  freshness) are already solved upstream.

### 4.6 Cons

- **Bootstrap problem.** A brand-new plugin from a brand-new
  publisher has zero WoT signal regardless of how good the code
  is. Falls back to "show the pubkey + follower count," which is
  barely better than "show the URL."
- **Sybil and paid-follow attacks.** Trust signals can be gamed.
  Buying 10k follows and a few zaps from sock-puppet accounts is
  cheap. The DVM is a trusted black-box that recomputes the
  intersection — Zap Store delegates to a `vertex` relay with no
  local recomputation, so a corrupted DVM relay can lie.
- **Nostr event signature ≠ binary integrity.** A compromised
  publisher pubkey can sign a metadata event pointing at a
  malicious git rev. The bind is only as strong as the chain.
- **Operator key on the node.** Importing a daily-driver `nsec`
  onto a node that runs services and might be compromised is a
  real risk. Mitigation: anonymous mode by default; explicit
  warnings for nsec import.
- **Substantial implementation effort** vs. A. Pulls in ~MB of
  Dart deps, requires identity-bootstrap UX, requires a relay
  policy.
- **Honest reading of Zap Store's design**: Nostr event
  integrity, not binary integrity, is the trust root. Same
  caveat applies to NixBlitz.

### 4.7 What Zap Store explicitly does not do

(For honest framing — these limitations port over.)

- No reproducible-build verification. Zap Store accepts the
  publisher's hash claim; NixBlitz would do the same.
- No secondary-source cross-check. Doesn't verify the binary
  matches what F-Droid / Play Store ships.
- No relay-diversity enforcement. Operator picks the relays.
- No update-policy enforcement beyond per-session cert pinning.
  An operator can uninstall + reinstall from a different
  publisher and Zap Store accepts it. NixBlitz already has this
  shape via the `plugin remove` / `plugin add` cycle.

---

## 5. Combining A + B

The two approaches address different trust questions and compose
cleanly. Neither subsumes the other:

```
                Git signing                    Nostr WoT
                (identity continuity)          (identity introduction)
                      │                                │
                      ▼                                ▼
      "rev came from the same key      "publisher key is followed/zapped
       as last time"                     by people I trust"
                      │                                │
                      └──────────────┬─────────────────┘
                                     ▼
              "Operator can refuse on key change AND
               can refuse on weak social signal at first install"
```

A covers the post-first-install case ("did the publisher I trusted
last time push this update?"). B covers the first-install case
("should I trust this publisher in the first place?"). Together
they fill both halves of the consent question.

### 5.1 Overlap

The pubkey pin and the SSH/GPG fingerprint pin are doing the same
thing at different layers. A plugin that ships _both_ a Nostr
release event AND signed git commits ends up with two pinned
identities to verify on every refresh. That's redundant but not
contradictory — it's defence-in-depth at the cost of some
ceremony.

For most plugins, picking one or the other will be clearer than
mandating both.

### 5.2 Implementation order

Phasing:

1. **Phase 1 — Approach A.** Half a day. PluginEntry field +
   verify hook + consent line + tests. Ship as a single small
   commit. Immediately useful for any plugin whose author signs.
2. **Phase 2 — Approach B (deferred).** Re-evaluate when (a) more
   than zero in-tree plugins use Nostr publishing, or (b) the
   demand for identity-introduction signals justifies the
   dependency cost. File as a follow-up.

The phasing is asymmetric: A gets shipped, B gets a proposal
filed. That reflects the implementation cost asymmetry (half day
vs. weeks) and the readiness asymmetry (git signing already
works in this very repo; Nostr identity bootstrap is greenfield).

### 5.3 What changes in the consent screen with both

A possible "fully-loaded" consent screen with both A and B in
play:

```
━━━ plugin: Tailscale ━━━
Enable Tailscale on this NixBlitz node…

source:        forgejo:.../tailscale
branch:        main
pinned rev:    ab12cd34…
signed by:     SSH key SHA256:abc123…   (alice@example.com)
schema:        v2

publisher:     npub1abc…
               (alice@example.com, NIP-05 verified)
mutual follows: 3 accounts you follow also follow this publisher
                ─ bob@nostr.example
                ─ carol@…
                ─ dave@…
zaps from your follow list: 2 zaps, 3,500 sats total

WARNING: installing this plugin grants the plugin author root
on this node. plugin.nix runs at nixos-rebuild as root and can
declare any systemd service, activation script, or external
dependency. This prompt is consent to run that code, not a
sandbox. Read plugin.nix at the upstream URL if you don't already
trust the source + commit + signing key + publisher pubkey above.

Proceed? [y/N]:
```

Note the warning text doesn't say _"this plugin has been
verified."_ It says _"if you don't already trust [the signals
above], read the code."_ The signals are inputs to the operator's
decision, not a substitute for it.

### 5.4 Tamper detection — protecting the trust state itself

Both A and B store their pinned trust signals on the
`PluginEntry`, which lives in `~/nixblitz/config.json`. That file
is owned by the `admin` user and read at TUI launch. **A
malicious plugin's `plugin.nix` runs at rebuild time as root** —
which means it can edit `config.json` directly. Specifically, it
can:

- Rewrite its own `signatureFingerprint` to match the new
  attacker key, so A's "key changed" warning never fires.
- Rewrite its own `publisherPubkey` to match the new attacker's
  Nostr identity, so B's "publisher changed" warning never fires.
- Rewrite _another plugin's_ trust signals to set up a future
  compromise of that plugin's update path.
- Tombstone all other plugins to clear out competing watchers.

Without something protecting the on-disk `PluginEntry`, A and B
both regress to "checks that fire at install time but can be
silently disabled afterward."

#### The git affordance

The whole `~/nixblitz/` tree is already a git repo. Every
legitimate state transition (config edit + Apply, plugin add /
remove / refresh) goes through a commit with a recognisable
shape — author / committer set by the TUI, commit message in a
known format ("Apply settings", "Update plugins: X, Y", etc.).
That gives us a reference frame the attacker has to forge
correctly to hide.

Three detection layers, in increasing implementation cost and
decreasing miss rate:

#### Layer 1: working-tree dirty check at TUI launch (cheap)

On TUI start, run `git -C ~/nixblitz status --porcelain`. Any
non-empty output means _something_ modified the tracked tree
between the last Apply and now. Cases:

- Operator was hand-editing `config.json` for a power-user tweak
  → expected; the dashboard's pending-changes banner already
  surfaces this.
- An out-of-band script touched a file → suspicious.
- A malicious plugin `sed`-edited `config.json` after rebuild →
  suspicious in the same way; we can't tell from the diff alone
  which it was.

**Surface as a banner**, not a block. Wording must distinguish
"unexpected" from "bad": `"config.json was modified outside the
TUI's apply / refresh flow — review before the next Apply"`. The
operator decides whether the change is theirs.

A plugin that just edits the file and never commits gets caught
here. Anything more sophisticated has to bypass this layer.

#### Layer 2: commit-authorship audit (medium)

Tag every TUI-authored commit with a recognisable author trailer:

- `git commit ... --author='NixBlitz <admin@nixblitz>'`, or
- A trailer line like `X-NixBlitz-Origin: tui-apply` /
  `tui-refresh` / `tui-templates` set via `--trailer`, which
  survives rebases and is harder to fake without reading our
  source first.

On TUI launch, walk recent commits (`git log -n 50 --format=…`)
and flag any whose authorship doesn't match the expected shape.
A plugin running `git commit` from inside `plugin.nix` can still
forge the author + trailer — but only if it knows what to forge,
which costs the attacker either source-reading or trial-and-error
detection.

This catches medium-effort attacks (a plugin that commits its
mutation to look "clean" without realising authorship is
checked).

#### Layer 3: external attestation (out of scope)

Truly closing the loop would mean storing trust state somewhere
the running plugin's `plugin.nix` can't reach: a TPM-backed
counter, a remote attestation service, an offline-signed
manifest the operator carries on a USB stick. All of these are
big architectural commitments and they move the trust root, not
just add a layer. Skip for now.

#### What tamper detection still doesn't catch

A determined attacker with root, knowing what NixBlitz looks
for, can:

- `git reset --hard <fake-good-state>` to make HEAD look
  legitimate while the working tree contains the malicious
  change.
- Replace `nixblitz-bin` in the next-generation store path so
  the _next_ TUI launch runs attacker code that skips the
  checks entirely.
- Forge author / committer / trailer fields on its own commits
  once it's read our source.
- Modify any sidecar state we use as an "external" reference.

This is the same framing as everything else in this doc and
in `plugins.md` D14: detection raises the bar against
opportunistic / lazy attackers. It does not prevent a
sophisticated attacker who has already gotten root via a
plugin install. The only thing that closes that hole is _not
giving root to plugin authors you don't trust_ — which is the
trust model the consent prompt is enforcing in the first place.

#### Recommendation

Ship Layer 1 alongside Approach A. It's ~10 lines of code in
the TUI launch path and gives the operator a real signal for
"something happened to my tracked tree that I didn't authorise."
Layer 2 is worth doing once Layer 1 is in place and we've seen
how often the dirty-tree warning fires legitimately — if it's
mostly noise, layer 2's authorship audit gives a sharper
signal. Layer 3 is doc-only for now.

---

## 6. What neither approach fixes

Restated for emphasis, because this is the failure mode that
would kill the value of either implementation:

- **A compromised key signs malicious code.** Both approaches
  accept the signature as valid. The operator's only signal is
  "the publisher hasn't visibly changed" — which is exactly the
  case when the publisher's account has been silently taken over.
- **A malicious publisher from day one.** TOFU pins on first
  install regardless of whether the publisher is honest. WoT can
  be sybil-bought.
- **Manifest description vs. plugin.nix mismatch.** A plugin can
  claim X in its description and do Y in `plugin.nix`. Neither
  approach reads code.
- **Forge / relay diversity.** Operator picks where to install
  from. Neither approach enforces multi-source verification.
- **`plugin.nix` runs as root.** The defining property of D14.
  No identity-continuity tool changes this.
- **The trust state itself sits on disk where root can rewrite
  it.** §5.4's tamper detection raises the bar against lazy
  attacks but a sophisticated attacker can `git reset` history,
  replace the TUI binary in the next system generation, or forge
  whatever audit trailers we check. Same "raises the bar, doesn't
  close the gap" framing.

The recently-recorded `feedback_no_security_theater.md` rule
applies in full: this doc must not present these approaches as
"the plugin is now safe." They are identity-continuity tools, full
stop. The consent prompt's job remains "make the trust decision
explicit" — these mechanisms add inputs to that decision, not a
verdict.

---

## 7. Recommendation

- **Adopt Approach A first**, plus §5.4 Layer 1 (working-tree
  dirty banner) in the same commit. Ship as a single small
  change: `PluginEntry.signatureFingerprint` field, verify hook
  between clone and manifest read, consent-prompt line, dirty-
  tree banner on TUI launch, tests for the key-change path and
  the unexpected-modification path. Immediately surfaces an
  unsigned-commit warning, a key-mismatch warning on refresh,
  and a "tracked tree was modified outside Apply" warning at
  startup.
- **Treat Approach B as a deferred experiment.** Open a tracking
  issue with the implementation sketch from §4.2. Revisit when
  ecosystem signals (plugin authors using Nostr, operator demand)
  justify the dependency + UX cost.
- **Update D14 in `plugins.md`** once A lands to note that
  identity continuity is now part of the consent surface, while
  the underlying trust model (install = root grant) is unchanged.
  Cross-link this doc.
- **Do not introduce intermediate "trust score" mechanisms.** The
  feedback rule from #10 / #17 stands: don't surface a number
  that _looks_ like verification but isn't. The consent prompt
  shows raw signals (fingerprint, mutual-follow count, zap
  count); the operator interprets them.

---

## 8. Out of scope (for follow-up work)

- **Reproducible-build verification.** A separate trust-axis: not
  about who signed the metadata, but about whether the binaries
  in the store match what the source produces. Different problem
  domain (attestation, build determinism, signed store paths)
  worth its own future doc.
- **Operator-side audit-log integration.** A doc on what
  consent decisions / refresh diffs / key-change events should be
  recorded for forensics. Adjacent to this doc but not part of it.
- **Multi-publisher plugins.** What if a plugin is co-maintained
  by multiple keys with rotating signers? Out of scope; v1 of
  Approach A pins one key per plugin.
- **Publisher key revocation / rotation.** Both approaches need
  a graceful "publisher rolled their key, here's the proof"
  path. Worth designing once the underlying mechanism is real.
