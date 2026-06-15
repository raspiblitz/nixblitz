# LNbits declarative extensions — follow-up backlog

Date: 2026-06-16
Status: Backlog (each item becomes its own brainstorm → spec → plan)

Context: the declarative vetted-manifest extension install + manually-managed
mode shipped (spec `2026-06-14-lnbits-externally-managed-extensions-mode-design.md`).
Live testing surfaced four follow-ups. They are mostly independent; suggested
order is at the bottom. Each item is scoped to be picked up on its own.

---

## A. Discoverable extension catalog in the TUI

**Problem.** The operator types extension IDs blind into the `External
extensions` string-list editor (screenshot: the `>` prompt). There's no way
to see what's available or compatible; a wrong/incompatible ID only fails at
rebuild time.

**Current.** `extensions` is a free-form `string_list` config field
(`plugin.json`). Validation happens at Nix eval (unknown/incompatible ID →
assertion). The vetted manifest is fetched only inside Nix eval
(`plugin.nix` → `lnbitsExtensionsManifest`); the Dart TUI has no access to it.

**Desired.** The TUI shows the available extensions — ideally pre-filtered to
those compatible with this node's lnbits version — with name + short
description, and lets the operator pick from the list (instead of free typing).

**Open questions.**

- How does the Dart TUI obtain the manifest? Options:
  (a) fetch `lnbits/lnbits-extensions/extensions.json` from GitHub at runtime
  (TUI runs on the node; needs network + a pin story);
  (b) bake a generated catalog (id/name/desc/min/max) into the build from the
  pinned manifest rev;
  (c) have the plugin expose the pinned manifest store path and read it.
- Does this need a new config-schema field type ("pick from a dynamic
  catalog" vs the current free `string_list`)? How does that interact with
  the existing `StringListField` editor?
- Where does compatibility filtering live (needs the lnbits version, which
  today is the `lnbitsVersion` constant in `plugin.nix`)?

**Scope.** Medium–large (manifest access in Dart + a catalog-picker
affordance). **Priority: high** — biggest UX win.

---

## B. Managed-mode behaviour in the LNbits extensions UI (fork)

**Problem.** In manually-managed mode the LNbits admin UI still shows the full
catalog, and the "manage" dialog opens a RELEASES list with selectable
versions + version constraints and (now inert) install affordances
(screenshot). It's confusing — there's nothing actionable there in managed
mode.

**Current.** Managed mode hides the install/upgrade/uninstall _buttons_ (the
`isExternal` payload drives the Vue template), but the extensions page still
lists the whole catalog and the releases/manage dialog still renders the
version picker.

**Desired.** In managed mode:

- the extensions page lists only **installed** extensions;
- the "manage" dialog shows read-only metadata (the installed version + its
  min/max lnbits constraints), without version selection or install actions.

**Open questions.** Exactly what the manage dialog should show — just the
installed version + constraints, or hide the releases section entirely? Should
this filtering be server-side (`/all` endpoint) or template-side?

**Scope.** Medium (fork Vue template, possibly `/all` payload). **Priority:
medium.** **Dependency:** lands in the lnbits fork → coordinate with the
externally-managed-mode PR (same squashed feature branch).

---

## C. Managed / unmanaged toggle in plugin settings

**Problem.** Managed mode is hard-wired on whenever the plugin is enabled. The
operator can't choose normal (UI-driven) LNbits extension management.

**Current.** `plugin.nix` sets `LNBITS_EXTENSIONS_MANUALLY_MANAGED = "true"`
unconditionally (the fork field defaults `false`). This was a deliberate
"always-on, no in-between" decision in the original design.

**Desired.** A plugin config field (bool) that toggles managed vs unmanaged,
threaded to the env.

**Open questions / tension.**

- This **reverses the earlier "no in-between" decision** — re-confirm we want
  the toggle, and that it's still binary (just operator-selectable now).
- Interaction with the `extensions` list: the list only makes sense in managed
  mode. If unmanaged, do we (a) forbid a non-empty `extensions` list via an
  assertion, or (b) still place the files but let lnbits manage them? Define
  this precisely.
- When switching managed → unmanaged, what happens to the existing Nix-placed
  symlinks, the prune state file, and lnbits's startup cleanup? (Unmanaged
  resumes re-download recovery + UI installs.) Define the transition.

**Scope.** Small–medium (plugin.json field + plugin.nix threading + behaviour
definition). **Priority: medium-low.**

---

## D. Paid extensions — place, lock, pay the dev, unlock

**Problem.** Several manifest extensions are paid (e.g. Streamer Copilot,
boltcards, satsdice, coinflip). Their GitHub `archive` zip is **public**, so
our `fetchurl` flow installs them **without paying — bypassing the developer's
monetization.** We want to keep declarative placement but route payment
through LNbits's existing paywall so the dev still gets paid.

**Target flow (operator's idea).**

1. Operator adds a paid extension via Nix (the TUI shows a "paid" label).
2. LNbits restarts; the extension is placed but **locked**.
3. In the LNbits extensions UI the operator sees an **Unlock / Pay** button.
4. Operator pays the developer's paywall invoice.
5. Payment is recorded; the extension unlocks and stays unlocked across
   rebuilds.

**Two payment models in LNbits (don't conflate):**

- **`pay_link` (marketplace pay-to-install → developer).** A release is "paid"
  iff its manifest entry has a `pay_link` (an `lnbits.com` paywall URL).
  `is_paid` ⇔ `pay_link` set. Normally gates the _archive download_
  (`archive_url?payment_hash=…` — the download itself is the verification).
  Payment is persisted in `installed_extensions.meta.payments`
  (`ReleasePaymentInfo`: pay_link/amount/payment_hash), with
  `find_existing_payment()` + `_remember_payment_info()` already implemented.
  **This is the model we want — money goes to the dev.**
- **`pay_to_enable` (per-user enable fee → operator's own wallet).** Has a
  complete install→invoice→pay→unlock(`active`) flow already
  (`get_pay_to_enable_invoice` → `api_enable_extension`), but pays the
  operator, not the dev. **Wrong recipient** for this use case.
- `paid_features` is a _separate informational_ note (e.g. tpos's 0.5% ATM
  fee), not an install gate. Ignore for gating.

**Load-bearing finding.** Disk-placed (externally-managed) extensions are
**not gated on payment anywhere** — once the files are on disk they load and
run fully (`app.py` disk-walk → `check_and_register_extensions` →
`get_valid_extensions`, no payment check; `InstalledExtensionMiddleware` only
checks deactivation). That non-gate _is_ the bypass.

**Reusable (already exists):** `ReleasePaymentInfo`, `meta.payments` (JSON in
the `installed_extensions.meta` column), `find_existing_payment(pay_link)`,
`_remember_payment_info()`, `fetch_release_payment_info()` (fetches the dev's
invoice from `pay_link`), and the `active` flag + `get_valid_extensions`
already filtering on it.

**Missing (new fork + plugin work):**

1. **Convey `pay_link`+cost to LNbits for a disk-placed ext.** The manifest
   isn't available at runtime in managed mode. Recommended: the plugin writes
   a sidecar (e.g. `.nix-paid.json` with `{pay_link, cost_sats}`) into the
   placed extension dir; `from_ext_dir` reads it and stamps the meta.
2. **Boot gate.** Paid + no recorded matching payment → register but
   `active=False` ("locked"). (Today boot always sets `active=True`.)
3. **Unlock endpoint**, exempt from the manually-managed 409 (it touches no
   files — only fetches an invoice + flips `active`): calls
   `fetch_release_payment_info` and returns the bolt11 to the UI.
4. **Settlement verification** (the hard part — we bypass the download gate
   that normally verifies). After payment, probe the paid
   `archive_url?payment_hash=…`; if the paywall serves it, payment settled →
   `_remember_payment_info()` → flip `active=True`. We discard the bytes (we
   already have the files); it's purely a paid/not-paid probe. (Alternative: a
   paywall status endpoint, if one exists — needs checking.)
5. **Persistence across rebuilds.** On boot, if `meta.payments` has a matching
   `pay_link`, treat as paid → `active=True`. Pay once, not per rebuild.
6. **TUI:** "paid" label on paid catalog entries (overlaps item A).

**Open decisions.**

- Confirm the `pay_link` (pay-the-dev) model over `pay_to_enable`.
- How LNbits learns the `pay_link` (sidecar file — recommended — vs settings
  map vs letting LNbits fetch the manifest).
- Settlement-verification method (probe the paid `archive_url` — recommended —
  vs a paywall status endpoint).
- Lock granularity: instance-level (operator buys once → global `active`) vs
  per-user. The `pay_link` model is instance-level; recommend global.

**Scope.** Medium–large — this is now a **fork feature** (boot gate + unlock
endpoint + verification + persistence) plus a plugin sidecar + a TUI label.
Consider phasing: **Phase 1** — an interim guard so we don't _silently_ ship a
bypass (refuse paid, or place-but-lock-with-no-unlock-yet + clear notice);
**Phase 2** — the full place→lock→pay→unlock flow above. **Priority: medium**
— land at least the Phase-1 guard **before** item A makes paid extensions
one-click discoverable.

---

## Suggested sequencing

1. **D (paid-extensions policy)** — small, and it gates how we present the
   catalog. Don't ship one-click discovery of a paywall bypass.
2. **A (TUI catalog)** — biggest UX win; depends on D's decision for how paid
   entries appear (refused / warned / hidden).
3. **B (fork UI: installed-only + read-only manage dialog)** — coordinate with
   the fork PR; independent of A/C.
4. **C (managed/unmanaged toggle)** — lowest priority; revisits a settled
   design decision, so confirm intent first.

Items B and D touch the **lnbits fork**; A and C touch the **plugin + Dart
TUI**. Each should go through its own brainstorm → spec → plan before
implementation.
