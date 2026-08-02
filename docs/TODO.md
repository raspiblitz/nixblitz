# TODO — known issues & open questions

Found during the 2026-08-02 cast-recording session on a freshly
installed x86 VM (build `b94d859`). Each entry has enough context to
work standalone; file as forge/GitHub issues as they get picked up.

## Bugs

### 1. Setup wizard alias input drops keystrokes right after the step appears

During a scripted first-boot run, characters sent to the alias field
~1s after the "Lightning Node Name" screen painted never registered:
the raw asciinema shows zero repaints between the screen's first frame
(`Alias: [_] 0/32 chars`) and the build starting — no echo, counter
never moved — while the Enter sent 1.4s later DID register and
submitted the (legitimately) empty field. Suspected focus void: the
preceding `markStepCompleted(selectLightningBackend)` config write
triggers a watcher reload + tree rebuild, and keys arriving before the
rebuilt input regains focus are silently dropped. A fast human typist
could hit the same window. Alias set later via Configure → Lightning
(LND) works fine. Repro likely needs scripted input (tmux send-keys
immediately after the step transition).

### 2. Plugin catalog pane doesn't scroll

Configure → Plugins renders the official catalog (6 entries) in a
fixed pane. At 34 terminal rows only 2 entries fit; ↑/↓ moves the
selection past the viewport edge with no scrolling, so the `>` cursor
walks invisibly off-pane. Worst case an operator presses Enter on a
selection they cannot see and lands in the consent screen for a plugin
they didn't mean to pick. The catalog list region needs to scroll with
the selection (the `ScrollableLog`-style viewport used elsewhere).

### 3. Plugin-install view re-fires after a successful install

After installing a plugin and applying (install → consent → "Apply
now?" → Apply Complete), navigating back to Configure rebuilds the
plugin-install view, which auto-fires the pending install again and
surfaces `install failed: Bad state: Plugin already installed:
<id>` to the operator. Same auto-fire-on-rebuild + guard-reset family
as the wizard's bitcoind flicker loop (fixed in `setup_view.dart` —
the guard must persist across rebuilds and only an explicit retry may
reset it). The pending-install providers
(`_pendingInstallUrlProvider` / `_installingPluginProvider` in
`configure_view.dart`) need the same treatment. Note: this is NOT a
regression of the wizard fix (`206b2d74`) — that commit postdates
`b94d859`, so the node that showed this never carried it, and the
failing site is `configure_view.dart`, which never had the guard.

### 4. Plugin dashboard tiles only register at TUI startup

`TileEventSource` registration happens once at startup, so a plugin
installed during the session (e.g. LNBits with its `dashboard` tile)
shows no tile until the TUI is quit and relaunched. The config watcher
already reloads config on changes — tile-source registration should
re-run on plugin-set changes too.

### 5. Concurrent TUI instances race on the config repo

The console (tty1 autologin) TUI and an SSH TUI running simultaneously
both auto-fire wizard/setup steps and both `git commit` in
`~/nixblitz`, producing lost commits (`fatal: cannot lock ref 'HEAD':
HEAD.lock exists`) and double-fired steps. Observed live during
first-boot setup with a monitor attached + SSH session. Needs either a
lock (single-instance guard with a "TUI already running on ttyN"
notice) or at minimum serialized git access with retry.

## Open questions

### Pin the templates flake's disko input?

`templates/flake.nix` pins `disko` rev-less
(`github:nix-community/disko`), so every node re-lock resolves
upstream HEAD. Consequence: each disko push makes **all nodes** report
"NixBlitz update available" with ~16 eval-glue rebuilds (etc, units,
os-release…) even though nothing operator-visible changed. It also
made the updates cast possible without pushing anything, which proves
the pipeline — but steady-state it's noise. Options: pin to a
rev/tag and bump deliberately (matches the nixos-raspberrypi
philosophy), or keep floating and accept the churn.
