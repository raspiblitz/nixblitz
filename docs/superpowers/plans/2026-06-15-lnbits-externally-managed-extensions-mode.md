# LNbits externally-managed extensions mode + orphan cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace LNbits's per-id external-extensions list with a single explicit "manually managed" mode, and clean up orphaned `installed_extensions` rows at startup, so removing a Nix-managed extension leaves LNbits in the same state as a native uninstall (row gone, data preserved).

**Architecture:** Two repos. (A) The LNbits fork at `examples_redesign/lnbits` gains one boolean setting that gates download-skip, API mutation refusal, the UI badge, and a new startup cleanup pass. (B) The NixBlitz plugin at `examples_redesign/nixblitz_official_plugins/lnbits` sets that flag (always-on) instead of the old id-list env, and bumps the pinned fork rev.

**Tech Stack:** Python 3 / FastAPI / pydantic-settings (pytest via `uv run`); Nix (NixOS module, alejandra-formatted).

**Spec:** `docs/superpowers/specs/2026-06-14-lnbits-externally-managed-extensions-mode-design.md`

**VCS note:** Commits are the user's responsibility (jj). The user will **squash all LNbits-fork commits into one** before the PR, so the per-task commit checkpoints below are green-keeping checkpoints, not final history. Do not run `jj commit`/`git commit` yourself unless asked — leave each checkpoint for the user, or treat it as a "suite is green here" marker.

**Migration ordering (keeps the suite green at every task):** Part A _adds_ the new flag first (Task A1), migrates each consumer to it (A2–A4), then _removes_ the old `lnbits_external_extension_ids` list, its helper, and the unused model field last (A5).

---

## File Structure

LNbits fork (`examples_redesign/lnbits`):

- `lnbits/settings.py` — the setting (field in `ExtensionsInstallSettings`, helper on `Settings`).
- `lnbits/app.py` — boot download-skip + new `cleanup_removed_extensions()` + wire-in.
- `lnbits/core/views/extension_api.py` — mutation refusal guard + `/all` payload.
- `lnbits/core/crud/extensions.py` — already has `get_installed_extensions` / `delete_installed_extension` (no change; imported by app.py).
- `lnbits/core/models/extensions.py` — remove the unused `is_external` field.
- `lnbits/templates/pages/extensions.vue` — **no change** (binds to the `isExternal` payload, which A4 repoints at the global flag).
- `tests/unit/test_external_extensions.py` — reworked across tasks.

NixBlitz plugin (`examples_redesign/nixblitz_official_plugins/lnbits`):

- `plugin.nix` — env swap + `lnbitsRev` bump + prune comment.
- `README.md`, `plugin.json` — docs.

Test command (run from `examples_redesign/lnbits`): `uv run pytest tests/unit/test_external_extensions.py -v`

---

# Part A — LNbits fork

### Task A1: Add the `lnbits_extensions_manually_managed` setting

**Files:**

- Modify: `lnbits/settings.py` (field in `ExtensionsInstallSettings`, ~line 96)
- Test: `tests/unit/test_external_extensions.py`

- [ ] **Step 1: Write the failing test**

Add to `tests/unit/test_external_extensions.py`:

```python
def test_manually_managed_defaults_false():
    """Out of the box, extensions are NOT manually managed."""
    from lnbits.settings import ExtensionsInstallSettings

    fresh = ExtensionsInstallSettings()
    assert fresh.lnbits_extensions_manually_managed is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/unit/test_external_extensions.py::test_manually_managed_defaults_false -v`
Expected: FAIL — `AttributeError: 'ExtensionsInstallSettings' object has no attribute 'lnbits_extensions_manually_managed'`

- [ ] **Step 3: Add the field**

In `lnbits/settings.py`, in class `ExtensionsInstallSettings` (the class that currently holds `lnbits_external_extension_ids`), add **above** the existing `lnbits_external_extension_ids` line:

```python
    # When True, ALL extensions on this instance are managed by an
    # external lifecycle owner (e.g. a Nix package manager). LNBits
    # registers + migrates whatever is found on disk under
    # `lnbits_extensions_path/extensions/<id>/`, but never downloads,
    # and refuses install/upgrade/uninstall via the API or admin UI.
    # An installed_extensions row whose files have disappeared is
    # treated as a removed extension and cleaned up at startup.
    # env: LNBITS_EXTENSIONS_MANUALLY_MANAGED
    lnbits_extensions_manually_managed: bool = Field(default=False)
```

(Leave `lnbits_external_extension_ids` in place for now — removed in A5.)

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/unit/test_external_extensions.py::test_manually_managed_defaults_false -v`
Expected: PASS

- [ ] **Step 5: Checkpoint** — suite green; setting added.

---

### Task A2: Boot path skips downloads when manually managed

**Files:**

- Modify: `lnbits/app.py` (`build_all_installed_extensions_list`, the `lnbits_extensions_default_install` loop, ~line 315)
- Test: `tests/unit/test_external_extensions.py`

- [ ] **Step 1: Rework the boot tests to drive the new flag**

In `tests/unit/test_external_extensions.py`, replace the body of `test_boot_skips_release_fetch_for_external_extensions` so it sets the new flag instead of the id list. Change these two lines:

```python
    settings.lnbits_external_extension_ids = ["lnurlp"]
    settings.lnbits_extensions_default_install = ["lnurlp"]
```

to:

```python
    settings.lnbits_extensions_manually_managed = True
    settings.lnbits_extensions_default_install = ["lnurlp"]
```

Also change its fixture from `isolate_external_extension_ids` to a new flag-isolating fixture. Add this fixture near the top of the file:

```python
@pytest.fixture
def isolate_manually_managed():
    original = settings.lnbits_extensions_manually_managed
    yield
    settings.lnbits_extensions_manually_managed = original
```

and update the test signature to use `isolate_manually_managed` in place of `isolate_external_extension_ids`. Leave `test_boot_still_fetches_releases_for_non_external_default_install` as-is except change its line `settings.lnbits_external_extension_ids = []` to `settings.lnbits_extensions_manually_managed = False` and its fixture to `isolate_manually_managed`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/unit/test_external_extensions.py -k boot -v`
Expected: `test_boot_skips_release_fetch_for_external_extensions` FAILS (assert `fetch_calls == []` fails — the guard still keys off the removed-from-test id list, so the fetch runs).

- [ ] **Step 3: Migrate the boot guard to the flag**

In `lnbits/app.py`, inside `build_all_installed_extensions_list`, find the per-id guard in the `lnbits_extensions_default_install` loop:

```python
        if settings.is_external_extension(ext_id):
            # Managed externally — the disk-walk above already
            # registers anything actually present at
            # `lnbits_extensions_path/extensions/<id>/`. Skip the
            # download attempt so an offline rebuild (e.g. Nix-based
            # node) doesn't fail on a network round-trip for files
            # the external owner is responsible for placing.
            continue
```

Replace it with:

```python
        if settings.lnbits_extensions_manually_managed:
            # Manually-managed mode: the external owner (e.g. Nix)
            # places every extension on disk out-of-band. The
            # disk-walk above already registered whatever is present;
            # never reach out to the network for a default-install.
            continue
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/unit/test_external_extensions.py -k boot -v`
Expected: both boot tests PASS.

- [ ] **Step 5: Checkpoint** — suite green; download-skip gated on the flag.

---

### Task A3: Startup cleanup of orphaned extension rows

**Files:**

- Modify: `lnbits/app.py` (add `cleanup_removed_extensions`, import `delete_installed_extension`, call from `check_installed_extensions` ~line 255)
- Test: `tests/unit/test_external_extensions.py`

- [ ] **Step 1: Write the failing tests**

Add to `tests/unit/test_external_extensions.py`:

```python
# ---------------------------------------------------------------------------
# Startup cleanup — in manually-managed mode, an installed_extensions row
# whose files are gone is a *removed* extension; delete the row (matching a
# native uninstall) but preserve the extension's data tables.
# ---------------------------------------------------------------------------


def _fake_ext(ext_id, has_files):
    """A stand-in InstallableExtension with a controllable has_installed_version."""
    from lnbits.core.models.extensions import InstallableExtension

    ext = InstallableExtension(id=ext_id, name=ext_id, version="1.0.0")
    # has_installed_version is a property reading ext_dir on disk; override
    # it on this instance for the test.
    object.__setattr__(ext, "_test_has_files", has_files)
    type(ext).has_installed_version = property(  # type: ignore
        lambda self: getattr(self, "_test_has_files", False)
    )
    return ext


@pytest.mark.asyncio
async def test_cleanup_deletes_folderless_rows_when_managed(
    isolate_manually_managed, monkeypatch
):
    from lnbits import app as lnbits_app

    settings.lnbits_extensions_manually_managed = True

    deleted: list[str] = []

    async def _fake_get_installed_extensions(*a, **k):
        return [_fake_ext("gone", has_files=False), _fake_ext("here", has_files=True)]

    async def _fake_delete(*, ext_id, conn=None):
        deleted.append(ext_id)

    monkeypatch.setattr(lnbits_app, "get_installed_extensions", _fake_get_installed_extensions)
    monkeypatch.setattr(lnbits_app, "delete_installed_extension", _fake_delete)

    await lnbits_app.cleanup_removed_extensions()

    assert deleted == ["gone"], "only the folderless extension row is deleted"


@pytest.mark.asyncio
async def test_cleanup_noop_when_not_managed(isolate_manually_managed, monkeypatch):
    from lnbits import app as lnbits_app

    settings.lnbits_extensions_manually_managed = False

    called = {"get": False, "delete": False}

    async def _fake_get_installed_extensions(*a, **k):
        called["get"] = True
        return [_fake_ext("gone", has_files=False)]

    async def _fake_delete(*, ext_id, conn=None):
        called["delete"] = True

    monkeypatch.setattr(lnbits_app, "get_installed_extensions", _fake_get_installed_extensions)
    monkeypatch.setattr(lnbits_app, "delete_installed_extension", _fake_delete)

    await lnbits_app.cleanup_removed_extensions()

    assert called["delete"] is False, "no deletion when mode is off"


@pytest.mark.asyncio
async def test_cleanup_never_drops_data_tables(isolate_manually_managed, monkeypatch):
    """Cleanup matches native uninstall: row deleted, data preserved."""
    from lnbits import app as lnbits_app

    settings.lnbits_extensions_manually_managed = True

    async def _fake_get_installed_extensions(*a, **k):
        return [_fake_ext("gone", has_files=False)]

    async def _fake_delete(*, ext_id, conn=None):
        pass

    monkeypatch.setattr(lnbits_app, "get_installed_extensions", _fake_get_installed_extensions)
    monkeypatch.setattr(lnbits_app, "delete_installed_extension", _fake_delete)

    # drop_extension_db must NOT be importable-and-called from cleanup.
    assert not hasattr(lnbits_app, "drop_extension_db"), (
        "cleanup must not import drop_extension_db — data tables are preserved"
    )
    await lnbits_app.cleanup_removed_extensions()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/unit/test_external_extensions.py -k cleanup -v`
Expected: FAIL — `AttributeError: module 'lnbits.app' has no attribute 'cleanup_removed_extensions'`.

- [ ] **Step 3: Add the import**

In `lnbits/app.py`, find the import block that pulls CRUD extension functions (it already imports `get_installed_extensions`, `create_installed_extension`, `update_installed_extension_state`). Add `delete_installed_extension` to that import list. For example, change:

```python
from lnbits.core.crud.extensions import (
    create_installed_extension,
    get_installed_extensions,
    update_installed_extension_state,
)
```

to include the new name (preserve whatever other names are already there):

```python
from lnbits.core.crud.extensions import (
    create_installed_extension,
    delete_installed_extension,
    get_installed_extensions,
    update_installed_extension_state,
)
```

- [ ] **Step 4: Add the cleanup function**

In `lnbits/app.py`, add this function immediately **above** `async def check_installed_extensions(app: FastAPI):`:

```python
async def cleanup_removed_extensions() -> None:
    """
    In manually-managed mode the external owner (e.g. Nix) places and
    removes extension files out-of-band. An `installed_extensions` row
    whose files are gone is therefore a *removed* extension — not a
    container that lost its data dir — so we delete the row to leave
    the same state a native uninstall produces.

    Data tables are deliberately preserved: LNBits's own uninstall
    only drops them via a separate explicit action, so we do NOT call
    `drop_extension_db` here. Idempotent; safe to run every boot.
    """
    if not settings.lnbits_extensions_manually_managed:
        return

    for ext in await get_installed_extensions():
        if not ext.has_installed_version:
            await delete_installed_extension(ext_id=ext.id)
            logger.info(
                f"🧹 Removed orphaned externally-managed extension row: {ext.id}"
            )
```

- [ ] **Step 5: Wire it into startup**

In `lnbits/app.py`, at the very top of `async def check_installed_extensions(app: FastAPI):` (before `installed_extensions = await build_all_installed_extensions_list(False)`), add:

```python
    # In manually-managed mode, prune rows for extensions the external
    # owner has removed BEFORE the rebuild/re-download logic runs, so
    # the missing-files branch below never tries to re-fetch them.
    await cleanup_removed_extensions()
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `uv run pytest tests/unit/test_external_extensions.py -k cleanup -v`
Expected: all three cleanup tests PASS.

- [ ] **Step 7: Checkpoint** — suite green; cleanup implemented + wired.

---

### Task A4: API refuses mutations + `/all` badge keyed on the flag

**Files:**

- Modify: `lnbits/core/views/extension_api.py` (`_refuse_if_externally_managed` → `_refuse_if_manually_managed`, 3 call sites ~lines 100/324/391, `isExternal` payload ~line 608)
- Test: `tests/unit/test_external_extensions.py`

- [ ] **Step 1: Rework the API tests**

In `tests/unit/test_external_extensions.py`, replace `test_refuse_if_externally_managed_raises_409` and `test_refuse_if_externally_managed_passes_for_unmanaged` with:

```python
def test_refuse_if_manually_managed_raises_409(isolate_manually_managed):
    from fastapi import HTTPException

    from lnbits.core.views.extension_api import _refuse_if_manually_managed

    settings.lnbits_extensions_manually_managed = True

    with pytest.raises(HTTPException) as exc_info:
        _refuse_if_manually_managed()

    assert exc_info.value.status_code == 409
    assert "manually managed" in exc_info.value.detail.lower()


def test_refuse_if_manually_managed_passes_when_off(isolate_manually_managed):
    from lnbits.core.views.extension_api import _refuse_if_manually_managed

    settings.lnbits_extensions_manually_managed = False
    # Mode off — should return without raising.
    _refuse_if_manually_managed()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/unit/test_external_extensions.py -k manually_managed_raises -v`
Expected: FAIL — `ImportError: cannot import name '_refuse_if_manually_managed'`.

- [ ] **Step 3: Replace the guard function**

In `lnbits/core/views/extension_api.py`, replace the whole `_refuse_if_externally_managed` function with:

```python
def _refuse_if_manually_managed() -> None:
    """
    Reject mutating operations when extensions are manually managed.

    With `lnbits_extensions_manually_managed` set, an external owner
    (e.g. a Nix package) places, upgrades, and removes every
    extension out-of-band. Install / upgrade / uninstall via the API
    are refused so the API cannot blow away externally-placed files.

    Raises 409 Conflict. Read-only endpoints (releases list, details)
    and DB-only endpoints (activate/deactivate) stay open.
    """
    if settings.lnbits_extensions_manually_managed:
        raise HTTPException(
            status_code=HTTPStatus.CONFLICT,
            detail=(
                "Extensions are manually managed on this instance "
                "(lnbits_extensions_manually_managed is set) and "
                "cannot be installed, upgraded, or uninstalled via "
                "the API. Manage them through whatever external "
                "system places them (e.g. your Nix configuration)."
            ),
        )
```

- [ ] **Step 4: Update the three call sites**

In the same file, change each call (the argument is dropped):

- in `api_install_extension`: `_refuse_if_externally_managed(data.ext_id)` → `_refuse_if_manually_managed()`
- in `api_uninstall_extension`: `_refuse_if_externally_managed(ext_id)` → `_refuse_if_manually_managed()`
- in `get_pay_to_install_invoice`: `_refuse_if_externally_managed(ext_id)` → `_refuse_if_manually_managed()`

- [ ] **Step 5: Repoint the `/all` payload**

In the same file, in the `extensions` endpoint payload dict (~line 608), change:

```python
            "isExternal": settings.is_external_extension(ext.id),
```

to:

```python
            "isExternal": settings.lnbits_extensions_manually_managed,
```

(The Vue template binds to this `isExternal` value, so in manually-managed mode every extension now shows the badge and hides its install/uninstall buttons — no template change needed.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `uv run pytest tests/unit/test_external_extensions.py -k manually_managed -v`
Expected: PASS.

- [ ] **Step 7: Checkpoint** — suite green; API + payload migrated.

---

### Task A5: Remove the old list, helper, and unused model field

**Files:**

- Modify: `lnbits/settings.py` (remove `lnbits_external_extension_ids` field + `is_external_extension` helper)
- Modify: `lnbits/core/models/extensions.py` (remove unused `is_external` field ~line 350)
- Test: `tests/unit/test_external_extensions.py` (delete obsolete tests)

- [ ] **Step 1: Delete the obsolete tests**

In `tests/unit/test_external_extensions.py`, delete these now-obsolete tests and the fixture they used:

- `test_default_is_empty`
- `test_is_external_extension_predicate`
- `test_is_external_extension_with_empty_list`
- `test_installable_extension_has_is_external_field_default_false`
- `test_installable_extension_is_external_round_trips_through_dict`
- the `isolate_external_extension_ids` fixture

- [ ] **Step 2: Run the suite to confirm nothing else references the removed names yet**

Run: `uv run pytest tests/unit/test_external_extensions.py -v`
Expected: PASS (the remaining tests use only the new flag).

- [ ] **Step 3: Remove the settings field + helper**

In `lnbits/settings.py`:

- Delete the `lnbits_external_extension_ids: list[str] = Field(default=[])` line and its comment block (in `ExtensionsInstallSettings`).
- Delete the `is_external_extension` method (in class `Settings`), including its docstring.

- [ ] **Step 4: Remove the unused model field**

In `lnbits/core/models/extensions.py`, in `class InstallableExtension`, delete the `is_external: bool = False` field and its comment block (it is no longer read anywhere — the `/all` payload now derives `isExternal` from settings).

- [ ] **Step 5: Verify no dangling references**

Run: `grep -rn "lnbits_external_extension_ids\|is_external_extension\|is_external\|_refuse_if_externally_managed" lnbits/`
Expected: no matches in `lnbits/` (templates bind to `isExternal`, which is fine — different name).

- [ ] **Step 6: Run the full unit suite**

Run: `uv run pytest tests/unit/test_external_extensions.py -v`
Expected: PASS.

- [ ] **Step 7: Checkpoint** — Part A complete; the fork now has exactly one binary mode. (User: this is where the squashed fork commit is taken; note its SHA for Task B1.)

---

# Part B — NixBlitz plugin

### Task B1: Swap the env flag and bump the fork rev in `plugin.nix`

**Files:**

- Modify: `examples_redesign/nixblitz_official_plugins/lnbits/plugin.nix`

- [ ] **Step 1: Swap the env**

In `plugin.nix`, replace the `externalExtensionsEnv` binding:

```nix
  externalExtensionsEnv = lib.optionalAttrs (builtExtensions != []) {
    LNBITS_EXTERNAL_EXTENSION_IDS =
      lib.concatStringsSep "," extensionIds;
    LNBITS_EXTENSIONS_DIGEST = extensionsDigest;
  };
```

with (note: the managed-mode flag is unconditional — extensions on a NixBlitz node are always Nix-owned; the digest stays gated on having built extensions):

```nix
  # Extensions on a NixBlitz node are always Nix-managed: flip lnbits
  # into manually-managed mode unconditionally so its UI can't
  # install/uninstall extensions and it cleans up rows for ones we've
  # removed. The digest changes on any manifest-pin bump so the unit
  # restarts and reloads the new module code.
  externalExtensionsEnv =
    {
      LNBITS_EXTENSIONS_MANUALLY_MANAGED = "true";
    }
    // lib.optionalAttrs (builtExtensions != []) {
      LNBITS_EXTENSIONS_DIGEST = extensionsDigest;
    };
```

- [ ] **Step 2: Annotate the prune step as the filesystem counterpart**

In `plugin.nix`, in the comment block above `pruneExtensionsScript`, append a sentence after the existing text:

```nix
  #   Note: LNbits itself now deletes the orphaned installed_extensions
  #   DB row at startup (manually-managed mode); this prune is its
  #   filesystem counterpart, removing the stale symlink.
```

- [ ] **Step 3: Bump the pinned fork rev**

In `plugin.nix`, set `lnbitsRev` to the SHA of the squashed Part-A commit (from Task A5, Step 7). Update the `lnbitsVersion` constant too if the fork's `pyproject.toml` version changed. Example:

```nix
  lnbitsRev = "<SHA-of-squashed-fork-commit>"; # f44/lnbits @ externally-defined-plugins
```

- [ ] **Step 4: Format**

Run: `nix run nixpkgs#alejandra -- examples_redesign/nixblitz_official_plugins/lnbits/plugin.nix`
Expected: reformats/confirms style clean.

- [ ] **Step 5: Verify the module eval**

Run from the repo root:

```bash
nix eval --impure --json --expr '
  let
    pkgs = import <nixpkgs> {};
    lib = pkgs.lib;
    dir = ./examples_redesign/nixblitz_official_plugins/lnbits;
    mk = cfg: (import (dir + "/plugin.nix") { pluginCfg = cfg; }) { config = {}; inherit lib pkgs; };
    envOf = m: lib.foldl (a: b: a // b) {} m.services.lnbits.env.contents;
    known = mk { enabled = true; backend = "none"; extensions = ["lnurlp"]; };
    empty = mk { enabled = true; backend = "none"; extensions = []; };
  in {
    knownManaged = (envOf known).LNBITS_EXTENSIONS_MANUALLY_MANAGED or "MISSING";
    emptyManaged = (envOf empty).LNBITS_EXTENSIONS_MANUALLY_MANAGED or "MISSING";
    knownHasDigest = (envOf known) ? LNBITS_EXTENSIONS_DIGEST;
    emptyHasDigest = (envOf empty) ? LNBITS_EXTENSIONS_DIGEST;
    noOldEnv = !((envOf known) ? LNBITS_EXTERNAL_EXTENSION_IDS);
  }'
```

Expected JSON: `knownManaged":"true"`, `"emptyManaged":"true"`, `"knownHasDigest":true`, `"emptyHasDigest":false`, `"noOldEnv":true`.

- [ ] **Step 6: Checkpoint** — plugin sets the new flag; old env gone.

---

### Task B2: Update plugin docs

**Files:**

- Modify: `examples_redesign/nixblitz_official_plugins/lnbits/README.md`
- Modify: `examples_redesign/nixblitz_official_plugins/lnbits/plugin.json`

- [ ] **Step 1: Rewrite the "Removing an extension" README section**

Replace the current "### Removing an extension" section body with:

```markdown
### Removing an extension

Drop the ID from the `extensions` list and rebuild. Two things happen:
the prune step removes the symlink, and LNBits — running in
manually-managed mode — deletes the now-orphaned `installed_extensions`
row at its next startup. The end state matches a native LNBits
uninstall: the row is gone, and the extension's own data tables are
**preserved** (LNBits only drops those on a separate explicit action,
which you can still trigger from the admin UI's "delete data" button).

On a NixBlitz node the LNBits admin UI cannot install, upgrade, or
uninstall extensions at all (HTTP 409) — extensions are managed
entirely through the `extensions` config field here. Activate/deactivate
stay available for toggling routing.
```

- [ ] **Step 2: Drop the now-stale DB-surgery caveat blockquote**

In the same README, delete the blockquote that begins `> The plugin does **not** touch LNBits's database itself.` — LNbits now handles the row cleanup itself, so the caveat no longer applies. (Keep the migration rollback caveat under "Updating the catalog".)

- [ ] **Step 3: Tweak `plugin.json` description if needed**

In `plugin.json`, confirm the `extensions` field `description` doesn't reference the old per-id env. It currently describes manifest resolution and `LNBITS_EXTERNAL_EXTENSION_IDS`. Change the trailing clause:

```
... and the ID is threaded into LNBITS_EXTERNAL_EXTENSION_IDS so install/upgrade/uninstall via the LNBits admin UI is refused.
```

to:

```
... and LNBits runs in manually-managed mode so install/upgrade/uninstall via the admin UI is refused for all extensions.
```

- [ ] **Step 4: Format the markdown/json**

Run: `nix run nixpkgs#prettier -- --write examples_redesign/nixblitz_official_plugins/lnbits/README.md examples_redesign/nixblitz_official_plugins/lnbits/plugin.json`
Expected: files reformatted/clean.

- [ ] **Step 5: Checkpoint** — docs match the new behavior.

---

## Final verification

- [ ] **Fork:** `cd examples_redesign/lnbits && uv run pytest tests/unit/test_external_extensions.py -v` — all PASS.
- [ ] **Fork grep:** `grep -rn "lnbits_external_extension_ids\|is_external_extension\|_refuse_if_externally_managed" lnbits/` — no matches.
- [ ] **Plugin:** the Task B1 Step 5 eval returns the expected JSON; `nix build` of a manifest-resolved extension still succeeds.
- [ ] **Integration (VM, optional but recommended):** add an extension → boot → row present + extension loads; remove from config → rebuild → symlink gone (prune) AND `installed_extensions` row gone (LNbits cleanup), service healthy. Verify with `sqlite3 /var/lib/lnbits/data/database.sqlite3 'select id from installed_extensions'`.

---

## Self-review notes (author)

- **Spec coverage:** A1 = setting (spec A1); A2 = boot download-skip (A2); A3 = cleanup (A3); A4 = API refusal + UI payload (A4/A5 — the `.vue` needs no edit because it binds to the repointed `isExternal`); A5 = consolidation/removal (Decision 1); B1 = plugin env + rev (B1); B2 = docs (B2). Testing section covered by per-task tests + Final verification.
- **Always-on (Decision 2):** B1 sets the flag unconditionally. ✓
- **Data preserved (constraint):** A3 explicitly avoids `drop_extension_db`, asserted by `test_cleanup_never_drops_data_tables`. ✓
- **Re-download recovery for non-managed nodes (constraint):** the boot guard (A2) and cleanup (A3) are both gated on the flag; `test_boot_still_fetches_releases_for_non_external_default_install` and `test_cleanup_noop_when_not_managed` lock this in. ✓
- **Type consistency:** new names used consistently — `lnbits_extensions_manually_managed`, `LNBITS_EXTENSIONS_MANUALLY_MANAGED`, `cleanup_removed_extensions`, `_refuse_if_manually_managed`, `delete_installed_extension`.
