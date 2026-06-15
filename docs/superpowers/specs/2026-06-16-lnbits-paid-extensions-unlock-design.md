# Paid LNbits extensions — place, lock, pay the dev, unlock

Date: 2026-06-16
Status: Approved (design)

Backlog item D from `docs/superpowers/2026-06-16-lnbits-extensions-followups.md`.

## Problem

NixBlitz installs LNbits extensions declaratively by fetching the public GitHub
release zip and symlinking it into place. Some extensions are **paid**: their
manifest entry carries a `pay_link` (an lnbits.com paywall invoice URL) so the
developer gets paid. But the zip is public, so the Nix flow installs paid
extensions **without paying — bypassing the developer's monetization**.

We want to keep declarative placement while routing payment through LNbits's
own paywall so the developer is paid: a Nix-placed paid extension is **locked**
until the operator pays the developer's invoice from the LNbits UI, then it
**unlocks** and stays unlocked across rebuilds.

## Decisions (settled in brainstorming)

- **Payment model: `pay_link` → the developer.** Not `pay_to_enable` (which
  pays the operator's own wallet and is per-user).
- **Rigor: honor-system parity.** LNbits itself does not verify settlement for
  this model (the archive is public GitHub; `archive_url`'s `payment_hash`
  query param is ignored by GitHub), and the operator is non-adversarial (they
  _want_ to pay the dev). The unlock fetches and pays a real invoice (sats →
  dev) but records the payment without a cryptographic settlement check. This
  is no weaker than upstream.
- **Lock granularity: instance-level** via the `installed_extensions.active`
  flag (the operator pays once for the node). Not per-user.
- **Architecture: fork-native lifecycle + a plugin sidecar** (Approach 1). The
  fork owns the paid state, reusing its existing payment model; the plugin only
  conveys the `pay_link`.
- **Mirror the existing pay-to-install UI** (amount + wallet-select + "Pay from
  wallet" / "Show QR") so the unlock dialog matches the flow operators already
  know — including paying the dev **directly from the node's own LNbits
  wallet**.
- **TUI "paid" label is out of scope here** — it belongs to backlog item A
  (the catalog). This spec covers the fork + plugin mechanism only.

## How LNbits handles paid extensions today (baseline we hook into)

Pay-**then**-install, instance-level, no "unlock after placement":

- UI (`extensions.vue` RELEASES dialog): a paid+unpaid release hides the
  install button and instead shows the cost, an amount input, a wallet select
  (operator's own wallets), and **Pay from wallet** (`payAndInstall`) / **Show
  QR** (`showInstallQRCode`). After payment it shows `extension_paid_sats`.
- API: `PUT /{ext_id}/invoice/install` (`get_pay_to_install_invoice`) fetches
  the dev's invoice via `fetch_release_payment_info(cost_sats)`, decodes the
  bolt11, validates amount + payment_hash, returns `ReleasePaymentInfo`. Then
  `POST /` (`api_install_extension`) with the `payment_hash` downloads +
  installs + activates. No settlement check.
- Both endpoints are gated by `_refuse_if_manually_managed`, so in
  manually-managed mode the entire current flow is **blocked** — hence the need
  for a separate, exempt unlock endpoint.

Reusable as-is: `ReleasePaymentInfo`, `meta.payments` (JSON in the
`installed_extensions.meta` column), `find_existing_payment(pay_link)`,
`_remember_payment_info()`, `fetch_release_payment_info()`, the invoice
decode/validate logic in `get_pay_to_install_invoice`, and the `active` flag
filtering in `get_valid_extensions`.

## Affected source

Fork (`examples_redesign/lnbits`, rev the plugin pins via `lnbitsRev`):

- `lnbits/core/models/extensions.py` — `from_ext_dir` (sidecar read);
  `is_paid` / `find_existing_payment` / `_remember_payment_info` (reuse).
- `lnbits/app.py` — `build_all_installed_extensions_list` (boot gate when
  creating a paid row).
- `lnbits/core/views/extension_api.py` — new unlock endpoint; 402 gate on
  activate for paid+unpaid; `/all` payload `needsUnlock`.
- `lnbits/core/services/extensions.py` — `activate_extension` /
  `update_installed_extension_state` (reuse).
- `lnbits/templates/pages/extensions.vue` — Locked badge + Unlock dialog.

Plugin (`examples_redesign/nixblitz_official_plugins/lnbits`):

- `extension-lib.nix` — `buildLnbitsExtension` writes the sidecar.
- `plugin.nix` — pass `payLink` from the resolved manifest entry.

## Design

### 1. Plugin → sidecar (fork↔plugin interface)

`buildLnbitsExtension` gains an optional `payLink ? null` arg. When non-null,
the derivation writes **`$out/.nix-paid.json`** = `{"pay_link": "<url>"}`
alongside the extension files, so it travels atomically with the symlinked
store path and survives rebuilds. `plugin.nix` passes
`payLink = r.entry.pay_link or null` (the manifest entry already carries
`pay_link`). `cost_sats` is NOT baked in — it's fetched from the paywall at
unlock time (the cost can change; the paywall is the source of truth).

### 2. Fork → `from_ext_dir` stamps paid

`from_ext_dir` additionally reads `<ext_dir>/.nix-paid.json`. If present and
valid, it sets `meta.installed_release.pay_link` so `is_paid` becomes true. A
missing or malformed sidecar is treated as **free** (logged at warning) — a bug
must never brick an extension.

### 3. Fork → boot gate (lock unless already paid)

When the disk-walk **creates** the `installed_extensions` row for a paid
extension, set `active=false` unless a matching payment already exists
(`find_existing_payment(pay_link)` over `meta.payments`). Because the disk-walk
only creates a row when one doesn't already exist, an already-unlocked
extension keeps its existing row (`active=true`, payment recorded) on later
boots — so **pay once, stays unlocked across rebuilds**. `pay_link` is stable
across an extension's versions, so a manifest-pin version bump stays unlocked.

### 4. Fork → activate gated for paid+unpaid (402)

The activate endpoint, called on a paid extension with no recorded payment,
returns **402 Payment Required** with a message pointing at the unlock flow
(reusing LNbits's existing 402 pattern from `api_enable_extension`). This makes
the lock meaningful instead of trivially toggled on. It stays honor-system: no
settlement check, and a determined operator can still bypass (same as editing
config) — this is a nudge to pay the dev, not DRM.

### 5. Fork → unlock endpoint (exempt from the managed-mode 409)

New admin endpoint, e.g. `PUT /api/v1/extension/{ext_id}/invoice/unlock` +
`POST /api/v1/extension/{ext_id}/unlock`, **not** wrapped by
`_refuse_if_manually_managed` (it touches no files):

- **Get invoice:** read the extension's `pay_link` (from the stored meta) and
  call `fetch_release_payment_info()` **without a caller-supplied cost** — the
  paywall returns the required `amount`. (This differs from
  `get_pay_to_install_invoice`, which requires `data.cost_sats` and validates
  the invoice against it; the sidecar deliberately doesn't carry a cost, so the
  paywall is the source of truth.) Then adapt that endpoint's bolt11
  decode/validate (`amount_msat` matches the returned `amount`, `payment_hash`
  matches the invoice) and return `ReleasePaymentInfo` (bolt11 + hash + amount)
  to the UI.
- **Confirm/unlock:** after the operator pays (from their wallet or via QR),
  append the `ReleasePaymentInfo` to `meta.payments`
  (`_remember_payment_info` style), set `active=true`
  (`update_installed_extension_state`), and `activate_extension`.

No archive download (Nix already placed the files). No settlement verification.

### 6. Fork → UI (`extensions.vue` + `/all` payload)

`/all` adds a computed **`needsUnlock`** = installed ∧ paid ∧ `active=false` ∧
no recorded payment. The extensions UI, for such an extension:

- shows a **Locked** badge (alongside the externally-managed badge);
- offers an **Unlock** button opening a dialog that **mirrors the existing
  pay-to-install UI** — cost, amount input, wallet select (operator's own
  wallets), **Pay from wallet** and **Show QR** — but wired to the unlock
  endpoints (§5) instead of install. On success the extension activates.

Install/uninstall stay hidden in managed mode; **unlock is the one permitted
mutation** for a paid, externally-managed extension.

### 7. Persistence & lifecycle

- **Pay once:** the payment persists in `meta.payments`; survives rebuilds and
  version bumps (stable `pay_link`).
- **Known limitation (v1):** removing the extension from Nix config deletes its
  row via the manually-managed cleanup, including the payment record, so
  re-adding later requires re-paying. Documented; acceptable for v1.
- **Paywall unreachable:** the unlock dialog surfaces an error and the
  extension stays locked; no crash.

## Testing

**Fork (pytest, `tests/unit/`):**

- `from_ext_dir`: valid sidecar → `is_paid` true; missing/malformed sidecar →
  treated as free (not paid), warning logged.
- Boot gate: paid + no payment → row created with `active=false`; paid + a
  matching `meta.payments` entry → `active=true`.
- Activate: paid + unpaid → 402; free or already-paid → succeeds.
- Unlock: get-invoice returns a validated `ReleasePaymentInfo`; confirm appends
  to `meta.payments` and flips `active=true`; unlock endpoints are NOT blocked
  by `_refuse_if_manually_managed` while install/uninstall still are.

**Plugin (nix):**

- `buildLnbitsExtension` writes `.nix-paid.json` iff `payLink` is set (build a
  paid fixture entry, assert the file exists with the right `pay_link`; free
  extension has no sidecar).
- `plugin.nix` passes `pay_link` from a resolved manifest entry through to the
  builder (eval check).

**Integration (VM):**

- Declare a paid extension → boot → it's installed but inactive (locked) and
  the LNbits UI shows Unlock.
- Pay from the node wallet via the unlock dialog → extension activates.
- Rebuild with no config change → stays unlocked (no re-pay).

## Out of scope

- Cryptographic settlement verification (honor-system parity, by decision).
- The TUI "paid" label / catalog surfacing (backlog item A).
- Preserving payment across a remove→re-add cycle (v1 limitation above).
- `paid_features` (the informational in-extension-fee note, e.g. tpos's ATM
  fee) — not an install gate, not handled here.
- Per-user enable fees (`pay_to_enable`) — different model, unchanged.
