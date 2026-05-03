# How the website builds

> Operator-facing version of this doc lives nowhere; the website is for
> operators but this doc is for whoever has to debug the pipeline when
> a CSS rule mysteriously vanishes or `nix build .#website` cooks for
> 30s and produces a stale result.

The website (`./website/`) is a [Jaspr](https://jaspr.site) static-rendering
Dart project. Source markdown + Dart components → tree of HTML / CSS /
assets that drops behind nginx / caddy / GitHub Pages. Two ways to
build it:

| Path             | Command                                    | When to use                                                               |
| ---------------- | ------------------------------------------ | ------------------------------------------------------------------------- |
| **Local**        | `just web-build-local`                     | Fast iteration. Reuses on-disk pub cache. Output: `website/build/jaspr/`. |
| **Reproducible** | `just web-build` (= `nix build .#website`) | CI, hosting, "is this what we ship?" Output: `./result/`.                 |

## Pipeline at a glance

```
website/lib/        ─┐
website/content/    ─┤
website/web/        ─┼─►  jaspr build  ─► build/jaspr/index.html
website/pubspec.yaml ┘    + Tailwind 4       /docs/<slug>/index.html
                          + build_runner     /changelog/index.html
                                             /screenshots/*.png
                                             /styles.css
```

The static-render server in jaspr boots `lib/main.server.dart`, crawls
every declared route by hitting itself over HTTP, dumps each response
to disk under `build/jaspr/`. Same code path drives `jaspr serve`
(dev mode) and `jaspr build` (write-and-exit mode).

## The Nix build (`nix build .#website`)

Files:

- `flake.nix` — declares `packages.<system>.website` via
  `pkgsUnstable.callPackage ./nix/website_pkg.nix`. Uses the
  workspace-member-filter nixpkgs fork because the patched
  `buildDartApplication` is what makes the offline build feasible.
- `nix/website_pkg.nix` — the actual derivation.

What the derivation does, in order:

1. **Source filter (nix-filter).** Includes `website/`, `pubspec.yaml`,
   `pubspec.lock`, `analysis_options.yaml`. Excludes `common/`, `tui/`,
   `templates/`, `scripts/` — they're not needed and dragging them in
   only forces `build_runner` to walk their git-deps.
2. **dartConfigHook** (from buildDartApplication) writes
   `.dart_tool/package_config.json` from the workspace lock and fetches
   every Dart package as a separate FOD into `/nix/store/pub-X-Y/`.
   `workspaceMember = "website"` + `workspaceIncludeDevDependencies = true`
   scopes the fetch to website-only deps + their dev deps.
3. **postPatch** rewrites `/build/source/pubspec.yaml` to a
   single-member workspace (`workspace: [- website]`). Without this
   `build_runner` walks `tui` and `common` looking for their pubspecs
   and crashes on the missing `nocterm` git source.
4. **buildPhase** (custom; default `dart compile exe` flow is skipped):
   - Synthesize `website/.dart_tool/package_config.json` by stripping
     `nixblitz_workspace` from the workspace-root config and rebasing
     relative `rootUri` paths with `../`. `build_runner` searches
     upward from CWD for a `package_config` and refuses to start when
     two members share the same `rootUri`.
   - Symlink `pubspec.lock` into `website/`. `build_runner` reads it
     to populate its "fixed packages" list.
   - `cd website`.
   - Run `tailwindcss -i web/input.css -o web/styles.css` to compile
     Tailwind. Done explicitly because no `*.tw.css` file exists for
     the `jaspr_tailwind` builder to pick up automatically, and
     reusing a stale on-disk `web/styles.css` from a prior local
     run was the source of "lightbox CSS missing" debugging time.
   - Run `packageRun jaspr_cli -e jaspr build -O4`. `packageRun` is
     a shell function provided by dartConfigHook; it runs the dart
     entrypoint with `--packages=<package_config>` so subprocesses
     don't fall back to `pub get`.
5. **installPhase** copies `build/jaspr/` to `$out/`, dropping
   `packages/` (build_web_compilers debug tree) and `.build.manifest`.

## The patched jaspr_cli

[`forge.f44.fyi/f44/jaspr`](https://forge.f44.fyi/f44/jaspr) at branch
`cli_build_daemon_bypass`. One-line patch in
`packages/jaspr_cli/lib/src/dev/util.dart`:

- **Stock**: `dart run build_runner daemon` — the `dart run` form
  re-validates `pubspec.lock` against `.dart_tool/package_config.json`
  on every launch and triggers `pub get` on any mismatch. In our
  setup the `package_config` is intentionally a website-scoped subset
  of the workspace lock, so there _is_ a mismatch — and `pub get`
  fails offline.
- **Fork**: `dart --packages=<package_config> <build_runner-bin> daemon`.
  Bypasses pub's resolver, uses the `package_config` verbatim. Falls
  back to the stock form when no `package_config` exists, so global
  `dart pub global activate jaspr_cli` is unaffected.

The patch is upstreamable; once it lands at
[schultek/jaspr](https://github.com/schultek/jaspr), drop the
`git:` indirection and pin `jaspr_cli` from pub.dev. Until then:

- **Bumping the fork**: rebase the patch onto a newer Jaspr tag in the
  fork repo, push to the same branch. Then update `gitHashes.jaspr_cli`
  in `nix/website_pkg.nix` (set to `""`, run nix build, copy the
  reported `got: sha256-...` hash). `dart pub get` from the workspace
  root resolves the new commit automatically because `ref:` is the
  branch.

## Tailwind quirks worth knowing

- `web/input.css` is the source. `web/styles.css` is the build
  output, **gitignored**. Don't manually edit `styles.css`.
- The Nix-bundled `tailwindcss_4` was 4.1.18 at the time of writing
  (some bug-prone scanner behaviour around top-level CSS rules vs
  `@layer components`). Local toolchain is whatever your shell has
  (typically newer 4.2.x).
- **Custom classes go inside `@layer components`** in `input.css`,
  not at top level. Tailwind 4.1.x silently dropped top-level
  `.lightbox` rules during purging despite their being referenced
  from `home_page.dart`; the same rules in `@layer components`
  survived. (4.2.x doesn't show this bug; bumping nixpkgs would
  fix it.)
- Class detection scans whatever `@source "../lib/**/*.dart"`
  resolves to, relative to `input.css`'s directory.

## Common breakages and quick checks

| Symptom                                                                    | Quick check                                                                                                                                                                                                                                                     |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New CSS class not visible after rebuild                                    | `grep <class> result/styles.css` — if missing, move the rule into `@layer components`.                                                                                                                                                                          |
| `nix build .#website` outputs a stale-looking site                         | `result/` is a symlink to `/nix/store/<hash>-...` — if your changes don't change the derivation hash, the symlink can point at an older identical build. Check `readlink result` and re-build. Verify `md5sum result/styles.css` changes when you expect it to. |
| `Got socket error trying to find package <X> at https://pub.dev` mid-build | The patched `jaspr_cli` isn't being used. Verify `website/pubspec.yaml` references the f44/jaspr fork via `git: { url, ref, path }` and `nix/workspace_pubspec.lock.json` reflects that. Re-run `just gen-locks`.                                               |
| Build fails on `nocterm` not present                                       | The workspace-pubspec slim in `postPatch` isn't taking effect. Confirm `pubspec.yaml` in the sandbox lists only `website` under `workspace:`.                                                                                                                   |
| `which dart` not found                                                     | jaspr_cli locates Dart via `which dart`; add `pkgs.which` to `nativeBuildInputs` in `nix/website_pkg.nix` (already there).                                                                                                                                      |
| Build hangs at "Connecting to the build daemon"                            | Port 5567 (jaspr's render proxy) is occupied. `pkill -9 -f "jaspr.dart"` and retry.                                                                                                                                                                             |

## Local dev workflow

```bash
just web-css-watch      # one terminal: Tailwind in watch mode
just web-serve          # another terminal: jaspr serve, hot reload, http://localhost:8080
```

Edit anything under `lib/`, `content/`, or `web/`. Tailwind recompiles
to `web/styles.css` on save; jaspr_cli reloads the page.

For a one-shot local build (no Nix, no commit): `just web-build-local`.
Output at `website/build/jaspr/`.

## Files involved

- `flake.nix` — declares `packages.<system>.website`.
- `nix/website_pkg.nix` — the build recipe (~110 lines).
- `nix/workspace_pubspec.lock.json` / `nix/workspace_dependency_graph.json`
  — generated by `just gen-locks` from `pubspec.lock`.
- `website/pubspec.yaml` — declares the f44/jaspr fork as the
  `jaspr_cli` source.
- `website/web/input.css` — Tailwind source.
- `website/lib/` + `website/content/` — site source.
- `justfile` — the `web-*` recipes.

If something fundamental shifts (Jaspr API, Tailwind major version,
nixpkgs Dart fork rebased), this doc gets out of date. Update it.
