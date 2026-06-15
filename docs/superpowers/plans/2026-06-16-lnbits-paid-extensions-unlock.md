# Paid LNbits extensions — place/lock/pay/unlock — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Nix-placed _paid_ LNbits extension installs **locked** (inactive) until the operator pays the developer's `pay_link` invoice from the LNbits UI, then it unlocks and stays unlocked across rebuilds.

**Architecture:** Fork-native lifecycle reusing LNbits's existing `pay_link`/`meta.payments` model + a plugin sidecar. The plugin writes `.nix-paid.json` into the placed extension; `from_ext_dir` reads it and marks the extension paid+inactive; a new unlock endpoint (exempt from the managed-mode 409) fetches the dev's invoice and, on payment, records it and activates. Honor-system parity (no settlement check); instance-level lock via the `active` flag.

**Tech Stack:** Python 3 / FastAPI / pydantic (pytest via `uv run`); Vue 2 / Quasar (manual/VM verify); Nix.

**Spec:** `docs/superpowers/specs/2026-06-16-lnbits-paid-extensions-unlock-design.md`

**VCS note:** Commits are the user's (jj); the LNbits-fork commits get squashed into the externally-managed-mode branch and **pushed**, then the plugin's `lnbitsRev` is bumped (a follow-up the user does). Do not run `jj commit`/`git commit` yourself — treat each checkpoint as a "suite is green here" marker.

**Test env note:** the fork's pytest env is `uv run pytest` (works in the fork's `nix develop`/uv setup). If `uv` isn't available in your session, implement + `python3 -m py_compile`, and the suite is run by the user.

---

## File Structure

LNbits fork (`examples_redesign/lnbits`):

- `lnbits/core/models/extensions.py` — `is_locked_paid` property + sidecar read in `from_ext_dir`.
- `lnbits/core/views/extension_api.py` — `_refuse_if_locked_paid` gate on activate; `get_unlock_invoice` + `api_unlock_extension` endpoints; `needsUnlock` in `/all`.
- `lnbits/templates/pages/extensions.vue` — Locked badge + Unlock dialog (mirrors pay-from-wallet).
- `tests/unit/test_paid_extensions.py` — new test module (keep separate from `test_external_extensions.py`).

Plugin (`examples_redesign/nixblitz_official_plugins/lnbits`):

- `extension-lib.nix` — `buildLnbitsExtension` writes the sidecar when `payLink` is set.
- `plugin.nix` — pass `payLink` from the resolved manifest entry.
- `README.md` — paid-extensions section.

Fork test command: `uv run pytest tests/unit/test_paid_extensions.py -v` (markers: `@pytest.mark.anyio` for async — this project has no pytest-asyncio).

---

# Part A — Fork backend

### Task A1: `is_locked_paid` property + sidecar read in `from_ext_dir`

**Files:**

- Modify: `lnbits/core/models/extensions.py` (`InstallableExtension`, ~line 341; `from_ext_dir`, ~line 599)
- Test: `tests/unit/test_paid_extensions.py` (new)

- [ ] **Step 1: Write failing tests**

Create `tests/unit/test_paid_extensions.py`:

```python
"""Tests for paid externally-managed extensions (place → lock → pay → unlock)."""

import json
from pathlib import Path

import pytest

from lnbits.settings import settings


def _write_ext(tmp, ext_id, *, pay_link=None, sidecar_raw=None):
    """Create extensions/<id>/config.json (+ optional .nix-paid.json) under tmp."""
    ext = Path(tmp, "extensions", ext_id)
    ext.mkdir(parents=True)
    (ext / "config.json").write_text(json.dumps({"name": ext_id, "version": "1.0.0"}))
    (ext / "__init__.py").write_text("")
    if sidecar_raw is not None:
        (ext / ".nix-paid.json").write_text(sidecar_raw)
    elif pay_link is not None:
        (ext / ".nix-paid.json").write_text(json.dumps({"pay_link": pay_link}))
    return ext


def test_from_ext_dir_free_is_active(tmp_path, monkeypatch):
    from lnbits.core.models.extensions import InstallableExtension

    monkeypatch.setattr(settings, "lnbits_extensions_path", str(tmp_path))
    _write_ext(tmp_path, "freeext")

    ext = InstallableExtension.from_ext_dir("freeext")
    assert ext is not None
    assert ext.active is True
    assert ext.meta.installed_release.pay_link is None
    assert ext.is_locked_paid is False


def test_from_ext_dir_paid_is_locked(tmp_path, monkeypatch):
    from lnbits.core.models.extensions import InstallableExtension

    monkeypatch.setattr(settings, "lnbits_extensions_path", str(tmp_path))
    _write_ext(tmp_path, "paidext", pay_link="https://pay.example/invoice/x")

    ext = InstallableExtension.from_ext_dir("paidext")
    assert ext is not None
    assert ext.meta.installed_release.pay_link == "https://pay.example/invoice/x"
    assert ext.active is False  # paid + freshly placed → locked
    assert ext.is_locked_paid is True


def test_from_ext_dir_malformed_sidecar_treated_free(tmp_path, monkeypatch):
    from lnbits.core.models.extensions import InstallableExtension

    monkeypatch.setattr(settings, "lnbits_extensions_path", str(tmp_path))
    _write_ext(tmp_path, "brokenext", sidecar_raw="{not json")

    ext = InstallableExtension.from_ext_dir("brokenext")
    assert ext is not None
    assert ext.active is True  # a bug must not brick the extension
    assert ext.meta.installed_release.pay_link is None


def test_is_locked_paid_false_when_payment_recorded():
    from lnbits.core.models.extensions import (
        ExtensionMeta,
        ExtensionRelease,
        InstallableExtension,
        ReleasePaymentInfo,
    )

    pay_link = "https://pay.example/invoice/x"
    ext = InstallableExtension(
        id="paidext",
        name="paidext",
        version="1.0.0",
        meta=ExtensionMeta(
            installed_release=ExtensionRelease(
                name="paidext", version="1.0.0", archive="x", source_repo="x",
                pay_link=pay_link,
            ),
            payments=[ReleasePaymentInfo(pay_link=pay_link, amount=10, payment_hash="h")],
        ),
    )
    assert ext.is_locked_paid is False
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/unit/test_paid_extensions.py -v`
Expected: FAIL — `AttributeError: 'InstallableExtension' object has no attribute 'is_locked_paid'` (and the paid/locked behavior not yet implemented).

- [ ] **Step 3: Add the `is_locked_paid` property**

In `lnbits/core/models/extensions.py`, in `class InstallableExtension`, add immediately after the existing `requires_payment` property (~line 400):

```python
    @property
    def is_locked_paid(self) -> bool:
        """A paid extension (its installed release carries a `pay_link`) for
        which no matching payment has been recorded yet. Such an extension is
        placed but must be unlocked (paid) before it can be activated."""
        if not self.meta or not self.meta.installed_release:
            return False
        pay_link = self.meta.installed_release.pay_link
        if not pay_link:
            return False
        return self.find_existing_payment(pay_link) is None
```

- [ ] **Step 4: Read the sidecar in `from_ext_dir`**

In `lnbits/core/models/extensions.py`, in `from_ext_dir`, replace the `return InstallableExtension(...)` block (the one inside the `with open(conf_path...)` body, ~lines 605-621) with this version that reads the sidecar and sets `pay_link` + `active`:

```python
                pay_link = None
                paid_path = Path(
                    settings.lnbits_extensions_path,
                    "extensions",
                    ext_id,
                    ".nix-paid.json",
                )
                if paid_path.is_file():
                    try:
                        with open(paid_path) as paid_file:
                            pay_link = json.load(paid_file).get("pay_link")
                    except Exception as paid_exc:
                        logger.warning(
                            f"lnbits-ext {ext_id}: ignoring malformed "
                            f".nix-paid.json: {paid_exc}"
                        )

                return InstallableExtension(
                    id=ext_id,
                    name=config_json.get("name", ext_id),
                    # Paid + freshly placed → locked (inactive) until unlocked.
                    active=pay_link is None,
                    version=version,
                    short_description=config_json.get("short_description"),
                    icon=config_json.get("tile"),
                    meta=ExtensionMeta(
                        installed_release=ExtensionRelease(
                            name=ext_id,
                            version=version,
                            archive=f"{conf_path}",
                            source_repo=f"{conf_path}",
                            min_lnbits_version=config_json.get("min_lnbits_version"),
                            max_lnbits_version=config_json.get("max_lnbits_version"),
                            pay_link=pay_link,
                        )
                    ),
                )
```

(`json`, `Path`, `logger`, `settings`, `ExtensionMeta`, `ExtensionRelease` are already imported/used in this module.)

- [ ] **Step 5: Run to verify they pass**

Run: `uv run pytest tests/unit/test_paid_extensions.py -v`
Expected: PASS (4 tests).

- [ ] **Step 6: Checkpoint** — suite green; paid detection + lock-on-placement done.

---

### Task A2: gate `activate` for locked paid extensions (402)

**Files:**

- Modify: `lnbits/core/views/extension_api.py` (add `_refuse_if_locked_paid`; call it in `api_activate_extension`, ~line 283)
- Test: `tests/unit/test_paid_extensions.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/unit/test_paid_extensions.py`:

```python
def _locked_paid_ext():
    from lnbits.core.models.extensions import (
        ExtensionMeta, ExtensionRelease, InstallableExtension,
    )
    return InstallableExtension(
        id="paidext", name="paidext", version="1.0.0", active=False,
        meta=ExtensionMeta(installed_release=ExtensionRelease(
            name="paidext", version="1.0.0", archive="x", source_repo="x",
            pay_link="https://pay.example/invoice/x",
        )),
    )


@pytest.mark.anyio
async def test_refuse_if_locked_paid_raises_402(monkeypatch):
    from fastapi import HTTPException
    from lnbits.core.views import extension_api

    async def _fake_get(ext_id, conn=None):
        return _locked_paid_ext()

    monkeypatch.setattr(extension_api, "get_installed_extension", _fake_get)

    with pytest.raises(HTTPException) as exc:
        await extension_api._refuse_if_locked_paid("paidext")
    assert exc.value.status_code == 402


@pytest.mark.anyio
async def test_refuse_if_locked_paid_passes_for_free(monkeypatch):
    from lnbits.core.views import extension_api

    async def _fake_get(ext_id, conn=None):
        return None  # not installed / not paid

    monkeypatch.setattr(extension_api, "get_installed_extension", _fake_get)
    # Should not raise.
    await extension_api._refuse_if_locked_paid("freeext")
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/unit/test_paid_extensions.py -k locked_paid -v`
Expected: FAIL — `AttributeError: module 'lnbits.core.views.extension_api' has no attribute '_refuse_if_locked_paid'`.

- [ ] **Step 3: Add the gate helper**

In `lnbits/core/views/extension_api.py`, add directly below the existing `_refuse_if_manually_managed` function:

```python
async def _refuse_if_locked_paid(ext_id: str) -> None:
    """
    Block activation of a paid extension that hasn't been paid for yet.

    A Nix-placed paid extension is installed but locked (active=false). It must
    be unlocked through the pay flow (PUT/POST .../unlock) so the developer is
    paid; only then may it be activated. Returns 402 Payment Required otherwise.
    """
    installed = await get_installed_extension(ext_id)
    if installed and installed.is_locked_paid:
        raise HTTPException(
            status_code=HTTPStatus.PAYMENT_REQUIRED,
            detail=(
                f"Extension '{ext_id}' is paid and locked. Pay the developer "
                "via the Unlock action before activating it."
            ),
        )
```

- [ ] **Step 4: Call it in `api_activate_extension`**

In `lnbits/core/views/extension_api.py`, in `api_activate_extension`, add the gate as the first statement inside the `try:` block, before `logger.info(f"Activating extension...`:

```python
        await _refuse_if_locked_paid(ext_id)
```

- [ ] **Step 5: Run to verify they pass**

Run: `uv run pytest tests/unit/test_paid_extensions.py -k locked_paid -v`
Expected: PASS.

- [ ] **Step 6: Checkpoint** — suite green; activate is gated.

---

### Task A3: unlock endpoints (get invoice + confirm/activate)

**Files:**

- Modify: `lnbits/core/views/extension_api.py` (two new endpoints; reuse `bolt11_decode`, `update_installed_extension`, `update_installed_extension_state`, `activate_extension`, `Extension`)
- Test: `tests/unit/test_paid_extensions.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/unit/test_paid_extensions.py`:

```python
class _FakeInvoice:
    amount_msat = 10_000
    payment_hash = "h123"


@pytest.mark.anyio
async def test_get_unlock_invoice_returns_payment_info(monkeypatch):
    from lnbits.core.models.extensions import ReleasePaymentInfo
    from lnbits.core.views import extension_api

    ext = _locked_paid_ext()

    async def _fake_get(ext_id, conn=None):
        return ext

    async def _fake_fetch(self, amount=None):
        return ReleasePaymentInfo(
            amount=10, pay_link=self.pay_link,
            payment_hash="h123", payment_request="lnbc...",
        )

    monkeypatch.setattr(extension_api, "get_installed_extension", _fake_get)
    monkeypatch.setattr(
        "lnbits.core.models.extensions.ExtensionRelease.fetch_release_payment_info",
        _fake_fetch,
    )
    monkeypatch.setattr(extension_api, "bolt11_decode", lambda pr: _FakeInvoice())

    info = await extension_api.get_unlock_invoice("paidext")
    assert info.payment_hash == "h123"
    assert info.amount == 10


@pytest.mark.anyio
async def test_unlock_records_payment_and_activates(monkeypatch):
    from lnbits.core.models.extensions import ReleasePaymentInfo
    from lnbits.core.views import extension_api

    ext = _locked_paid_ext()
    state = {"active": None, "updated": False, "activated": False}

    async def _fake_get(ext_id, conn=None):
        return ext

    async def _fake_update(e, conn=None):
        state["updated"] = True

    async def _fake_state(*, ext_id, active, conn=None):
        state["active"] = active

    async def _fake_activate(e):
        state["activated"] = True

    monkeypatch.setattr(extension_api, "get_installed_extension", _fake_get)
    monkeypatch.setattr(extension_api, "update_installed_extension", _fake_update)
    monkeypatch.setattr(extension_api, "update_installed_extension_state", _fake_state)
    monkeypatch.setattr(extension_api, "activate_extension", _fake_activate)

    data = ReleasePaymentInfo(
        amount=10, pay_link="https://pay.example/invoice/x", payment_hash="h123",
    )
    result = await extension_api.api_unlock_extension("paidext", data)

    assert result.success is True
    assert state["active"] is True
    assert state["activated"] is True
    # payment recorded against the installed extension
    assert any(p.pay_link == "https://pay.example/invoice/x" for p in ext.meta.payments)


@pytest.mark.anyio
async def test_unlock_invoice_not_blocked_by_managed_mode(monkeypatch):
    """Unlock must work in manually-managed mode (install/uninstall are 409'd)."""
    from lnbits.core.models.extensions import ReleasePaymentInfo
    from lnbits.core.views import extension_api

    settings.lnbits_extensions_manually_managed = True
    ext = _locked_paid_ext()

    async def _fake_get(ext_id, conn=None):
        return ext

    async def _fake_fetch(self, amount=None):
        return ReleasePaymentInfo(
            amount=10, pay_link=self.pay_link, payment_hash="h123",
            payment_request="lnbc...",
        )

    monkeypatch.setattr(extension_api, "get_installed_extension", _fake_get)
    monkeypatch.setattr(
        "lnbits.core.models.extensions.ExtensionRelease.fetch_release_payment_info",
        _fake_fetch,
    )
    monkeypatch.setattr(extension_api, "bolt11_decode", lambda pr: _FakeInvoice())

    # Should NOT raise 409 (manually-managed) — unlock is exempt.
    info = await extension_api.get_unlock_invoice("paidext")
    assert info.payment_hash == "h123"
    settings.lnbits_extensions_manually_managed = False
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/unit/test_paid_extensions.py -k unlock -v`
Expected: FAIL — `AttributeError: ... has no attribute 'get_unlock_invoice'`.

- [ ] **Step 3: Add the two endpoints**

In `lnbits/core/views/extension_api.py`, add these two endpoints (place them next to the other extension routes, e.g. after `get_pay_to_install_invoice`). Note: **no** `_refuse_if_manually_managed()` call — unlock is exempt:

```python
@extension_router.put("/{ext_id}/invoice/unlock", dependencies=[Depends(check_admin)])
async def get_unlock_invoice(ext_id: str) -> ReleasePaymentInfo:
    installed = await get_installed_extension(ext_id)
    if not installed or not installed.meta or not installed.meta.installed_release:
        raise HTTPException(HTTPStatus.NOT_FOUND, f"Extension '{ext_id}' not found.")
    release = installed.meta.installed_release
    if not release.pay_link:
        raise HTTPException(
            HTTPStatus.BAD_REQUEST, f"Extension '{ext_id}' is not a paid extension."
        )

    payment_info = await release.fetch_release_payment_info()
    if not (payment_info and payment_info.payment_request):
        raise HTTPException(
            HTTPStatus.BAD_GATEWAY,
            "Could not reach the developer's paywall. Try again later.",
        )
    invoice = bolt11_decode(payment_info.payment_request)
    if invoice.amount_msat is None:
        raise HTTPException(HTTPStatus.BAD_GATEWAY, "Invoice amount is missing.")
    if payment_info.payment_hash != invoice.payment_hash:
        raise HTTPException(HTTPStatus.BAD_GATEWAY, "Wrong invoice payment hash.")
    if payment_info.amount is None:
        payment_info.amount = int(invoice.amount_msat / 1000)
    return payment_info


@extension_router.post("/{ext_id}/unlock", dependencies=[Depends(check_admin)])
async def api_unlock_extension(
    ext_id: str, data: ReleasePaymentInfo
) -> SimpleStatus:
    installed = await get_installed_extension(ext_id)
    if not installed or not installed.meta or not installed.meta.installed_release:
        raise HTTPException(HTTPStatus.NOT_FOUND, f"Extension '{ext_id}' not found.")
    release = installed.meta.installed_release
    if not release.pay_link:
        raise HTTPException(
            HTTPStatus.BAD_REQUEST, f"Extension '{ext_id}' is not a paid extension."
        )

    # Record the payment against the installed release, then persist it into
    # the extension's payments history (honor-system: we do not verify
    # settlement; the operator paid the developer's invoice).
    release.payment_hash = data.payment_hash
    release.cost_sats = data.amount
    installed._remember_payment_info()
    await update_installed_extension(installed)
    await update_installed_extension_state(ext_id=ext_id, active=True)
    await activate_extension(Extension.from_installable_ext(installed))

    return SimpleStatus(success=True, message=f"Extension '{ext_id}' unlocked.")
```

- [ ] **Step 4: Ensure imports**

In `lnbits/core/views/extension_api.py`, confirm these names are imported (most already are — add any missing to their existing import groups): `bolt11_decode` (from `bolt11`), `update_installed_extension` and `update_installed_extension_state` (from `lnbits.core.crud.extensions`), `activate_extension` (from `lnbits.core.services.extensions`), `Extension` and `ReleasePaymentInfo` (from `lnbits.core.models.extensions`). Run `grep -n "bolt11_decode\|update_installed_extension_state\|from_installable_ext" lnbits/core/views/extension_api.py` to see which are present; add the missing ones.

- [ ] **Step 5: Run to verify they pass**

Run: `uv run pytest tests/unit/test_paid_extensions.py -k unlock -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Checkpoint** — suite green; unlock flow implemented + exempt from managed-mode 409.

---

### Task A4: expose `needsUnlock` in the `/all` payload

**Files:**

- Modify: `lnbits/core/views/extension_api.py` (the `extensions` endpoint payload, ~line 560-625)
- Test: covered by integration (the property logic is unit-tested in A1); add a focused payload-field test.

- [ ] **Step 1: Add an `installed_by_id` map + the field**

In `lnbits/core/views/extension_api.py`, in the `extensions` (`/all`) endpoint, just before the `extension_data = [` list comprehension, add:

```python
    installed_by_id = {e.id: e for e in installed_exts}
```

Then inside the payload dict (next to `"isExternal": settings.lnbits_extensions_manually_managed,`), add:

```python
            "needsUnlock": bool(
                installed_by_id.get(ext.id)
                and installed_by_id[ext.id].is_locked_paid
            ),
```

(Compute from the **installed** extension, not the merged catalog entry `ext` — the merge does not copy `meta.payments`.)

- [ ] **Step 2: Syntax-check**

Run: `python3 -m py_compile lnbits/core/views/extension_api.py`
Expected: no output. (Full `/all` behavior is verified in the VM integration step; the `is_locked_paid` logic it depends on is unit-tested in A1.)

- [ ] **Step 3: Checkpoint** — suite green; UI has a `needsUnlock` signal.

---

# Part B — Fork frontend (manual / VM verify)

### Task B1: Locked badge + Unlock dialog in `extensions.vue`

**Files:**

- Modify: `lnbits/templates/pages/extensions.vue`

No JS unit-test harness here — verify in the VM. **First read the existing pay-to-install methods to mirror them:** `grep -n "payAndInstall\|showInstallQRCode\|installExtension\b" lnbits/templates/pages/extensions.vue`, and read those method bodies in the `<script>` section. The new methods are the same shape with different endpoints.

- [ ] **Step 1: Add a Locked badge on the installed-extension card**

In `lnbits/templates/pages/extensions.vue`, next to the existing `externally managed` badge (the `<q-badge v-if="extension.isExternal" ...>` around line 144), add a sibling badge:

```html
<q-badge
  v-if="extension.needsUnlock"
  class="float-right q-ml-xs"
  color="orange"
  text-color="white"
>
  locked · paid
  <q-tooltip>
    This is a paid extension placed by Nix. Pay the developer to unlock it.
  </q-tooltip>
</q-badge>
```

- [ ] **Step 2: Add an Unlock button + dialog**

On the installed-extension card / manage area, add an Unlock button shown when `extension.needsUnlock`, opening a dialog that mirrors the existing pay-to-install block (cost text + amount input + wallet `q-select` from `g.user.walletOptions` + "Pay from wallet" + "Show QR"). Model the markup on the existing block at lines ~585-660 (`release.requiresPayment && !release.paid_sats`), but bind to the unlock methods from Step 3 and to a `selectedExtension`/`unlock` view-model.

- [ ] **Step 3: Add the JS methods (mirror the install ones)**

In the `<script>` `methods:` block, add three methods modeled on `payAndInstall` / `showInstallQRCode`:

- `getUnlockInvoice(extension)` → `PUT /api/v1/extension/${extension.id}/invoice/unlock` → store the returned `{amount, pay_link, payment_hash, payment_request}` on the view-model.
- `payAndUnlock(extension)` → pay `payment_request` from the selected wallet (reuse whatever `payAndInstall` uses to pay a bolt11 from a wallet), then `POST /api/v1/extension/${extension.id}/unlock` with the payment info, then refresh the extensions list.
- `showUnlockQRCode(extension)` → show the `payment_request` as a QR (reuse `showInstallQRCode`'s dialog), with a confirm that calls the same `POST .../unlock`.

- [ ] **Step 4: Manual verify (deferred to VM integration)** — see Part D.

- [ ] **Step 5: Checkpoint** — UI wired; behavior confirmed in the VM step.

---

# Part C — Plugin

### Task C1: write the `.nix-paid.json` sidecar

**Files:**

- Modify: `examples_redesign/nixblitz_official_plugins/lnbits/extension-lib.nix`
- Modify: `examples_redesign/nixblitz_official_plugins/lnbits/plugin.nix`

- [ ] **Step 1: Add the `payLink` arg + sidecar write**

In `extension-lib.nix`, add `payLink ? null` to the `buildLnbitsExtension` argument set (alongside `meta ? {}`), and in `installPhase`, after `cp -r . "$out/"` and before `runHook postInstall`, insert:

```nix
        ${lib.optionalString (payLink != null) ''
          printf '%s' ${
          lib.escapeShellArg (builtins.toJSON {pay_link = payLink;})
        } > "$out/.nix-paid.json"
        ''}
```

(Uses `builtins.toJSON` for correct JSON escaping and `lib.escapeShellArg` for the shell — both available; `extension-lib.nix` already receives `lib`.)

- [ ] **Step 2: Pass `payLink` from the manifest entry**

In `plugin.nix`, in the `builtExtensions` map (the `extensionLib.buildLnbitsExtension { ... }` call, ~line 138), add:

```nix
        payLink = r.entry.pay_link or null;
```

- [ ] **Step 3: Format**

Run: `nix run nixpkgs#alejandra -- examples_redesign/nixblitz_official_plugins/lnbits/extension-lib.nix examples_redesign/nixblitz_official_plugins/lnbits/plugin.nix`
Expected: style clean.

- [ ] **Step 4: Build-verify the sidecar (paid vs free)**

Run from the repo root (uses lnurlp's public archive as a fixture; payLink is arbitrary for the test):

```bash
PAID=$(nix build --impure --no-link --print-out-paths --expr '
  let pkgs = import <nixpkgs> {};
      extLib = import ./examples_redesign/nixblitz_official_plugins/lnbits/extension-lib.nix {
        inherit (pkgs) stdenv fetchurl unzip lib; };
  in extLib.buildLnbitsExtension {
    id = "lnurlp";
    archive = "https://github.com/lnbits/lnurlp/archive/refs/tags/v1.3.0.zip";
    hash = "71701b5756628fec6d7418192158c647e840e1fbf9a65e6fd2372bc73f626562";
    version = "1.3.0";
    payLink = "https://pay.example/invoice/abc";
  }')
echo "--- paid sidecar ---"; cat "$PAID/.nix-paid.json"; echo

FREE=$(nix build --impure --no-link --print-out-paths --expr '
  let pkgs = import <nixpkgs> {};
      extLib = import ./examples_redesign/nixblitz_official_plugins/lnbits/extension-lib.nix {
        inherit (pkgs) stdenv fetchurl unzip lib; };
  in extLib.buildLnbitsExtension {
    id = "lnurlp";
    archive = "https://github.com/lnbits/lnurlp/archive/refs/tags/v1.3.0.zip";
    hash = "71701b5756628fec6d7418192158c647e840e1fbf9a65e6fd2372bc73f626562";
    version = "1.3.0";
  }')
echo "--- free sidecar present? ---"; test -f "$FREE/.nix-paid.json" && echo "PRESENT (bad)" || echo "absent (good)"
```

Expected: paid prints `{"pay_link":"https://pay.example/invoice/abc"}`; free prints `absent (good)`.

- [ ] **Step 5: Checkpoint** — plugin writes the sidecar only for paid extensions.

---

# Part D — Docs + integration

### Task D1: README paid-extensions section

**Files:**

- Modify: `examples_redesign/nixblitz_official_plugins/lnbits/README.md`

- [ ] **Step 1: Add the section**

After the "### Removing an extension" section, add:

```markdown
### Paid extensions

Some vetted extensions are paid (their manifest entry has a `pay_link` — an
lnbits.com paywall that pays the developer). The source zip is public, so to
keep the developer paid we don't bypass it: a Nix-placed paid extension is
installed but **locked** (inactive) until you pay.

After rebuild, open the LNbits extensions UI: a locked paid extension shows a
**Locked · paid** badge and an **Unlock** button. Unlock fetches the
developer's invoice and lets you pay it straight from one of your LNbits
wallets (or via QR); once paid, the extension activates. The payment is
remembered, so it stays unlocked across rebuilds.

> Removing the extension from the config later deletes its install record
> (including the payment); re-adding it will require unlocking again.
```

- [ ] **Step 2: Format**

Run: `nix run nixpkgs#prettier -- --write examples_redesign/nixblitz_official_plugins/lnbits/README.md`

- [ ] **Step 3: Checkpoint** — docs updated.

### Task D2: VM integration verification

- [ ] Build the fork with the paid feature, point the plugin's `lnbitsRev` at it, declare a paid extension (e.g. `copilot`, whose 1.5.5-compatible release has a `pay_link`).
- [ ] Boot the VM. Verify: the extension dir + `.nix-paid.json` are present; `installed_extensions` has the row with `active=0`; the LNbits UI shows Locked + Unlock.
- [ ] Trigger Unlock, pay from the node wallet (regtest), confirm the extension activates and `meta.payments` (in the `installed_extensions.meta` JSON) records the payment.
- [ ] Rebuild with no change → the extension stays active (no re-pay).
- [ ] Activate via the generic toggle on a _fresh_ locked paid extension → returns 402.

---

## Self-review notes (author)

- **Spec coverage:** §1 sidecar = C1; §2 from_ext_dir = A1; §3 boot lock = A1 (`active=pay_link is None` on placement; persistence via the disk-walk skipping existing rows); §4 activate 402 = A2; §5 unlock endpoints = A3; §6 UI/`needsUnlock` = A4 (payload) + B1 (Vue); §7 persistence/limitation = covered (disk-walk skip) + documented in D1; testing §ack across A/C/D2.
- **Decisions honored:** `pay_link`→dev (A3 uses `fetch_release_payment_info` on the release's pay_link); honor-system (A3 records without settlement check); instance-level (the `active` flag, not per-user `pay_to_enable`); mirror pay-from-wallet UI (B1).
- **Type/name consistency:** `is_locked_paid`, `_refuse_if_locked_paid`, `get_unlock_invoice`, `api_unlock_extension`, `needsUnlock`, `.nix-paid.json`, `payLink`, `pay_link` used consistently across tasks.
- **Known gaps acknowledged:** B1 (Vue) is manual/VM-verified (no JS test harness); A4's full-endpoint behavior is integration-verified (the unit-testable `is_locked_paid` logic is covered in A1).
