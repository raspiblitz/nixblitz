# LNbits externally-managed extensions mode + orphan cleanup

Date: 2026-06-14
Status: Approved (design)

## Problem

NixBlitz installs LNbits extensions declaratively: each declared id is
fetched from LNbits's vetted manifest, built to a Nix store path, and
symlinked into `/var/lib/lnbits/extensions/<id>/`. LNbits discovers
extensions by walking that directory on disk, so placement + a restart
is the whole install mechanism.

The gap is **removal**. When an operator drops an id from the Nix
config, the plugin's prune step deletes the symlink, but LNbits keeps a
row in its `installed_extensions` table. At the next boot LNbits finds
that row with missing files and — because it cannot tell an
intentionally-removed extension from a container that lost its data
dir — tries to **re-download** it, fails (the stored archive path is a
stale local path), and finally **deactivates** it with a warning. The
result is a lingering, deactivated orphan row that the operator cannot
clean up through the UI (externally-managed extensions refuse UI
uninstall by design).

We want removal to leave LNbits in the same clean state a normal UI
uninstall produces: no `installed_extensions` row, data tables
preserved.

## Constraints / principles

- **Fully explicit, binary mode — no in-between.** A node is either
  fully externally managed (Nix owns all extension lifecycle) or it is
  a normal LNbits. No per-extension heuristics, no inference from
  implementation details, no mode that flips based on how many
  extensions are declared.
- **Do not break LNbits's re-download recovery** for normal
  (non-managed) nodes. The "missing files on boot → re-download" path
  (the docker-recreate use case) must remain the default when the mode
  is off.
- **Match LNbits's native uninstall semantics:** cleanup deletes the
  `installed_extensions` row and deactivates, but **preserves the
  extension's own data tables** (LNbits's uninstall only drops data via
  a separate explicit action).
- **The plugin never touches LNbits's database.** DB reconciliation is
  LNbits's responsibility; the plugin only manages files on disk.
  (Doing SQL from a rebuild hook would be racy with the running service
  and backend-specific across SQLite/Postgres.)

## Decisions

1. Replace the existing per-id `lnbits_external_extension_ids` list with
   a single global boolean. The list is removed, not deprecated — two
   "external" concepts would be the in-between we are avoiding.
2. The mode is **always on** whenever the NixBlitz lnbits plugin is
   enabled. Consequence: on a NixBlitz node the LNbits UI can never
   install/uninstall/upgrade extensions, regardless of how many are
   declared (including zero). Extensions are Nix-only.
3. Cleanup runs at **startup**, inside the existing
   `check_installed_extensions` flow.
4. The fork changes (this spec's Part A) reworks the three prior
   `externally-defined-plugins` commits; they will be **squashed into a
   single commit / PR** before submission upstream.

## Affected source (pinned fork rev `159600a`, version `1.5.5-rc2`)

The working LNbits repo is `examples_redesign/lnbits` (at the same rev
the plugin pins via `lnbitsRev`). Relevant locations:

- `lnbits/settings.py:96` — `lnbits_external_extension_ids` field;
  `:1233` — `is_external_extension(id)` helper.
- `lnbits/app.py:255` — `check_installed_extensions`; `:286` —
  `build_all_installed_extensions_list` (disk walk + default-install
  download loop); `:358` — `check_installed_extension_files` (the
  download-on-missing path).
- `lnbits/core/views/extension_api.py:70` —
  `_refuse_if_externally_managed`; call sites at install/uninstall/
  pay-to-install.
- `lnbits/core/crud/extensions.py:34` — `delete_installed_extension`;
  `:45` — `drop_extension_db` (data drop — NOT used by cleanup).
- `lnbits/core/models/extensions.py:599` — `from_ext_dir` (creates the
  disk-walk row); `:390` — `has_installed_version`.
- UI: the extensions admin template/components that render the
  externally-managed badge and gate install/uninstall buttons.

## Part A — LNbits fork

### A1. Setting

Remove `lnbits_external_extension_ids` and `is_external_extension`. Add:

```python
lnbits_extensions_manually_managed: bool = Field(default=False)
# env: LNBITS_EXTENSIONS_MANUALLY_MANAGED
```

A small accessor (e.g. `settings.lnbits_extensions_manually_managed`)
is read at every former per-id call site.

### A2. Boot path (`app.py`)

When the mode is **on**:

- `build_all_installed_extensions_list`: skip the
  `lnbits_extensions_default_install` download loop entirely — nothing
  is ever fetched over the network. The on-disk walk that registers
  whatever files are present is unchanged.
- `check_installed_extensions`: for each installed row whose files are
  missing (`not has_installed_version`), call the cleanup (A3) to
  **delete the row** instead of `restore_installed_extension` /
  re-download.

When the mode is **off**, both behaviors are exactly as today
(re-download recovery preserved).

### A3. Cleanup function

New function (e.g. `cleanup_removed_extensions`) invoked from the
startup path:

- For each `installed_extensions` row whose files are missing on disk:
  - stop background work / deactivate routing (no-ops when the module
    was never loaded this boot, but kept for symmetry with uninstall),
  - `delete_installed_extension(ext_id)` to remove the row,
  - **do not** call `drop_extension_db` — data tables are preserved.
- Idempotent; logs each removed id at info level.

### A4. API refusal (`extension_api.py`)

`_refuse_if_externally_managed(ext_id)` becomes
`_refuse_if_manually_managed()`: returns HTTP 409 for install / upgrade
/ uninstall / pay-to-install when the mode is on, with no per-id check.
Activate/deactivate endpoints stay open (toggling routing for an
on-disk extension is still allowed).

### A5. UI

The extensions admin view shows the "externally managed" badge and
hides install/uninstall/upgrade controls for **all** extensions when
the mode is on (replacing the per-id conditional). A short note points
the operator at their external manager (Nix config).

## Part B — NixBlitz plugin (`nixblitz_official_plugins/lnbits`)

### B1. `plugin.nix`

- Replace the `LNBITS_EXTERNAL_EXTENSION_IDS` env with
  `LNBITS_EXTENSIONS_MANUALLY_MANAGED = "true"`, set whenever the
  plugin is enabled (always-on).
- Keep `LNBITS_EXTENSIONS_DIGEST` (restart on manifest-pin bump),
  the `L+` tmpfiles symlinks, the `system.extraDependencies` GC pin,
  and the prune `ExecStartPre`.
  - The prune removes stale **filesystem symlinks**; LNbits's new
    cleanup removes stale **DB rows**. They are complementary, not
    redundant.
- Bump `lnbitsRev` (and the `lnbitsVersion` constant if the fork
  version changes) to the new fork commit once Part A lands.

### B2. README + `plugin.json`

- Rewrite the "Removing an extension" README section: removal is now
  fully clean — no lingering `installed_extensions` row — while the
  extension's data tables are still preserved. Drop the "manual UI
  uninstall to purge the orphan row" workaround.
- Note that the LNbits admin UI cannot install/uninstall extensions on
  a NixBlitz node; extensions are managed entirely through the
  `extensions` config field.
- Minor `plugin.json` description tweak if wording references the old
  per-id env.

## Testing

### Fork (pytest)

- `cleanup_removed_extensions`:
  - folderless row → row deleted, extension data table still present.
  - present extension (files on disk) → row untouched.
  - mode **off** → no deletion; the existing re-download path is still
    taken for a folderless row.
- API: install/uninstall/upgrade return 409 when mode on; activate/
  deactivate still succeed.
- Boot: a node with the mode on and a folderless row starts cleanly,
  logs the cleanup, and does not attempt a network download.

### Plugin (nix)

- `nix eval` of the module: env now carries
  `LNBITS_EXTENSIONS_MANUALLY_MANAGED = "true"` (and the digest), and
  no longer carries `LNBITS_EXTERNAL_EXTENSION_IDS`.
- `nix build` of a manifest-resolved extension still succeeds.

### Integration (VM)

- Add an extension, boot, confirm the row exists and the extension
  loads. Remove it from config, rebuild, confirm: the symlink is gone
  (prune), the `installed_extensions` row is gone (LNbits cleanup), and
  the service is healthy.

## Out of scope

- Dropping extension **data tables** on removal (LNbits keeps these on
  a normal uninstall; an operator can still drop them via the admin UI
  "delete data" action).
- The `extra_extensions` escape hatch for out-of-manifest extensions
  (separate planned follow-up).
- Surfacing "installed-but-missing" extensions in the dashboard tile.
