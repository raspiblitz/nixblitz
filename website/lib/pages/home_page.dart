import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

import '../build_info.dart';
import '../components/asciinema_cast.dart';
import '../components/tile.dart';

/// `figlet -f "ANSI Shadow" NIXBLITZ` — duplicated from
/// `common/lib/src/branding.dart` because the website's web-build
/// pipeline (build_web_compilers) can't compile `common` cleanly:
/// `common.dart` re-exports services that touch `dart:io`, which
/// fails on the web target. Six lines, never reformat. Update the
/// `common` copy in lockstep — the TUI renders the same banner.
const String _asciiBanner = r'''
███╗   ██╗██╗██╗  ██╗██████╗ ██╗     ██╗████████╗███████╗
████╗  ██║██║╚██╗██╔╝██╔══██╗██║     ██║╚══██╔══╝╚══███╔╝
██╔██╗ ██║██║ ╚███╔╝ ██████╔╝██║     ██║   ██║     ███╔╝
██║╚██╗██║██║ ██╔██╗ ██╔══██╗██║     ██║   ██║    ███╔╝
██║ ╚████║██║██╔╝ ██╗██████╔╝███████╗██║   ██║   ███████╗
╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝   ╚═╝   ╚══════╝
''';

const String _kRepoUrl = 'https://github.com/raspiblitz/nixblitz';

class HomePage extends StatelessComponent {
  const HomePage({super.key});

  @override
  Component build(BuildContext context) {
    return Component.fragment([
      _hero(),
      _section(
        anchor: 'overview',
        title: 'overview',
        text: const _OverviewBody(),
        media: null,
      ),
      _section(
        anchor: 'installation',
        title: 'installation',
        text: const _InstallationBody(),
        media: const AsciinemaCast(
          src: '/casts/install-demo.cast',
          caption:
              'The real thing: SSH into the live ISO, pick a disk, and the '
              'fully offline install runs to completion — recorded '
              'unscripted, install phase time-compressed 4x.',
          cols: 100,
          poster: 'npt:0:06',
          rows: 34,
        ),
      ),
      _section(
        anchor: 'the-tui',
        title: 'the tui',
        text: const _TuiBody(),
        media: const _Screenshot(
          src: '/screenshots/2026-05-13-dashboard.png',
          alt:
              'The dashboard view: header with node alias and pending count, '
              'tile grid with node summary, hardware, system services, '
              'Bitcoin Core, Lightning, LNBits, Tailscale, and a footer '
              'with keybind hints.',
          caption: 'Dashboard — the home screen after first-boot setup.',
        ),
      ),
      _section(
        anchor: 'configure-apply',
        title: 'configure → apply',
        text: const _ConfigureApplyBody(),
        media: const _Screenshot(
          src: '/screenshots/2026-05-13-configuration-menu.png',
          alt:
              'The Configure view: left sidebar lists System and each '
              'installed app (Bitcoin Core, Blitz API, LNBits, LND, '
              'Tailscale, Plugins); right pane shows the selected '
              'section\'s editable rows.',
          caption: 'Configure — edit values; apply commits and rebuilds.',
        ),
      ),
      _section(
        anchor: 'system',
        title: 'system menu',
        text: const _UpdateBody(),
        media: const _Screenshot(
          src: '/screenshots/2026-05-13-system-update-menu.png',
          alt:
              'The System view: sidebar splits Check / Apply / Power; '
              'the Check pane shows a "Last check" status panel with '
              'flake inputs (resolved + follows-only entries dimmed), '
              'plugin updates, and a "9 need compile" system-closure '
              'signal, plus the action list (Check for updates, View '
              'package diff, View packages to compile).',
          caption:
              'System — read-only checks, the single Apply path, and '
              'shutdown / reboot on one sidebar.',
        ),
      ),
      _section(
        anchor: 'debug',
        title: 'debug menu',
        text: const _DebugBody(),
        media: const _Screenshot(
          src: '/screenshots/2026-05-13-debug-menu.png',
          alt:
              'The Debug view: action list for service health, API '
              'login password, unit log tailing, regtest block '
              'generation, and the Test-LN helpers (status / fund '
              'wallets / open channel / pay self-invoice).',
          caption: 'Debug — service health and regtest helpers.',
        ),
      ),
      _goDeeperSection(),
    ]);
  }

  Component _hero() {
    return section(classes: 'dotted-bg py-12 sm:py-20', [
      div(classes: 'max-w-6xl mx-auto px-4 text-center', [
        pre(
          // `text-left` overrides the parent `text-center`, which
          // would otherwise centre each line of the figlet banner
          // individually — fine for the wider lines but offsets
          // lines 3 + 4 which are 1-2 chars shorter than the rest,
          // breaking the rectangular silhouette. With text-left
          // the lines flush at the pre's left edge while the
          // `inline-block` + `mx-auto` keep the block itself
          // horizontally centred.
          classes:
              'ascii-banner inline-block text-left text-[0.5rem] sm:text-xs md:text-sm lg:text-base mx-auto',
          [Component.text(_asciiBanner)],
        ),
        p(
          classes: 'mt-6 sm:mt-8 mx-auto max-w-2xl text-base sm:text-lg',
          styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
          [
            Component.text(
              'A Bitcoin / Lightning node on NixOS — install with one command, '
              'configure with a TUI, run on x86 or Pi 5. No Nix knowledge required.',
            ),
          ],
        ),
        _experimentalCallout(),
        div(classes: 'mt-8 flex flex-wrap items-center justify-center gap-4', [
          a(href: '#installation', classes: 'btn-bracket', [
            Component.text('Get started'),
          ]),
          a(
            href: _kRepoUrl,
            classes: 'btn-bracket',
            attributes: {'target': '_blank', 'rel': 'noopener noreferrer'},
            [Component.text('View on Forge')],
          ),
        ]),
      ]),
    ]);
  }

  /// Up-front warning callout in the hero. NixBlitz is pre-1.0 and
  /// has not received a thorough security review; we'd rather scare
  /// off a casual mainnet operator than let them lose funds because
  /// the front page made it look production-ready.
  Component _experimentalCallout() {
    return div(classes: 'warning-callout mt-8 mx-auto max-w-2xl text-left', [
      div(classes: 'warning-callout-title', [
        Component.text('[!] highly experimental — under construction'),
      ]),
      p(classes: 'warning-callout-body', [
        Component.text(
          'NixBlitz has NOT received a thorough security review. '
          'Don\'t use it for production funds. Run on regtest in a '
          'VM or on dedicated hardware you\'re okay reinstalling. '
          'Things will break.',
        ),
      ]),
    ]);
  }

  Component _section({
    required String anchor,
    required String title,
    required Component text,
    required Component? media,
  }) {
    return section(id: anchor, classes: 'py-10 sm:py-14', [
      div(classes: 'max-w-6xl mx-auto px-4', [
        if (media == null)
          _titleTile(title, text)
        else
          div(classes: 'grid grid-cols-1 lg:grid-cols-2 gap-6', [
            _titleTile(title, text),
            media,
          ]),
      ]),
    ]);
  }

  Component _titleTile(String title, Component body) {
    return Tile(title: title, children: [body]);
  }

  Component _goDeeperSection() {
    return section(id: 'go-deeper', classes: 'py-10 sm:py-14', [
      div(classes: 'max-w-6xl mx-auto px-4', [
        Tile(
          title: 'go deeper',
          children: [
            p(
              classes: 'mb-4',
              styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
              [
                Component.text(
                  'Three operator-focused docs cover the rest. They live next to '
                  'this site so anything that lands here will land there too.',
                ),
              ],
            ),
            ul(classes: 'space-y-2', [
              _docLink(
                '/docs/installation',
                'installation',
                'Prebuilt image → working node; per-platform guides.',
              ),
              _docLink(
                '/docs/architecture',
                'architecture',
                'Mental model: config.json is truth, NixOS follows.',
              ),
              _docLink(
                '/docs/plugins',
                'plugins',
                'Manifest, two-stage plugin.nix ABI, worked examples.',
              ),
            ]),
          ],
        ),
      ]),
    ]);
  }

  Component _docLink(String path, String label, String desc) {
    return li(classes: 'flex flex-wrap items-baseline gap-x-3', [
      a(href: href(path), classes: 'keybind', [
        span(classes: 'key', [Component.text('[>]')]),
        Component.text(' $label'),
      ]),
      span(
        classes: 'text-sm',
        styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
        [Component.text(desc)],
      ),
    ]);
  }
}

/// A row inside a tile body — `key` on the left, `value` on the right.
/// Mirrors the System / Hardware tile rows in the actual dashboard.
Component _kvRow(String key, String value, {String? valueColor}) {
  final valueStyle = valueColor != null
      ? Styles(raw: {'color': 'var(--color-tui-$valueColor)'})
      : null;
  return div(classes: 'flex items-baseline justify-between gap-4 py-0.5', [
    span(styles: Styles(raw: {'color': 'var(--color-tui-muted)'}), [
      Component.text(key),
    ]),
    span(styles: valueStyle, [Component.text(value)]),
  ]);
}

class _OverviewBody extends StatelessComponent {
  const _OverviewBody();

  @override
  Component build(BuildContext context) {
    return div([
      _kvRow('platform', 'x86  /  pi5'),
      _kvRow('os', 'NixOS 25.11', valueColor: 'cyan'),
      _kvRow('bitcoin', 'bitcoind via nix-bitcoin', valueColor: 'cyan'),
      _kvRow('lightning', 'LND  /  CLN  /  none', valueColor: 'magenta'),
      _kvRow('api + ui', 'blitz-api + blitz-web', valueColor: 'cyan'),
      _kvRow('config', '~/nixblitz/config.json'),
      _kvRow('vcs', 'git-tracked, every Apply is a commit'),
    ]);
  }
}

class _InstallationBody extends StatelessComponent {
  const _InstallationBody();

  @override
  Component build(BuildContext context) {
    return div([
      p(classes: 'mb-3', [
        Component.text(
          'Download the prebuilt image for your platform — TUI and a '
          'fully offline install closure baked in — flash it, boot, and '
          'walk the wizard. Reboot into a working node. No Nix '
          'knowledge required.',
        ),
      ]),
      ul(classes: 'space-y-1.5 mt-2', [
        _step('1', 'Download the image for your platform (links below).'),
        _step('2', 'Flash it, boot. The TUI launches in install mode.'),
        _step('3', 'Pick the target disk; the install runs fully offline.'),
        _step(
          '4',
          'Reboot. First-boot setup: admin password, Bitcoin network, '
              'Lightning backend, services.',
        ),
        _step('5', 'Back up the LND seed when prompted. Done.'),
      ]),
      p(classes: 'mt-4 space-x-4', [
        a(href: href('/docs/install-pi5'), classes: 'keybind', [
          span(classes: 'key', [Component.text('[>]')]),
          Component.text(' install on pi 5'),
        ]),
        a(href: href('/docs/install-x86'), classes: 'keybind', [
          span(classes: 'key', [Component.text('[>]')]),
          Component.text(' install on x86'),
        ]),
        span(
          classes: 'text-sm',
          styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
          [Component.text('— linear guides, flash to first boot')],
        ),
      ]),
    ]);
  }

  Component _step(String n, String text) {
    return li(classes: 'flex gap-3', [
      span(
        styles: Styles(
          raw: {'color': 'var(--color-tui-orange)', 'font-weight': '700'},
        ),
        [Component.text('$n.')],
      ),
      span([Component.text(text)]),
    ]);
  }
}

class _TuiBody extends StatelessComponent {
  const _TuiBody();

  @override
  Component build(BuildContext context) {
    return div([
      p(classes: 'mb-3', [
        Component.text(
          'A single binary on `tty1` (auto-login on the installed system). '
          'Re-run any time over SSH. Three regions:',
        ),
      ]),
      ul(classes: 'space-y-2', [
        _row(
          'header',
          'NIXBLITZ | <alias> | <platform> | <pending status> | <version>',
        ),
        _row(
          'main',
          'Tile grid: System, Hardware, Bitcoin, Lightning, plus any plugin tiles.',
        ),
        _row('footer', 'Keybind hints — only shown when their action applies.'),
      ]),
      p(
        classes: 'mt-4',
        styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
        [
          Component.text(
            'Live updates flow over SSE from blitz-api: sync %, peer counts, '
            'channel balances. Built-in tiles seed from REST on startup so the '
            'first paint isn\'t empty.',
          ),
        ],
      ),
    ]);
  }

  Component _row(String key, String value) {
    return li(classes: 'flex flex-col sm:flex-row sm:gap-4', [
      span(
        classes: 'sm:w-20 sm:flex-shrink-0',
        styles: Styles(
          raw: {'color': 'var(--color-tui-orange)', 'font-weight': '700'},
        ),
        [Component.text(key)],
      ),
      span([Component.text(value)]),
    ]);
  }
}

class _ConfigureApplyBody extends StatelessComponent {
  const _ConfigureApplyBody();

  @override
  Component build(BuildContext context) {
    return div([
      p(classes: 'mb-3', [
        Component.text('Two distinct steps. '),
        span(
          styles: Styles(
            raw: {'color': 'var(--color-tui-orange)', 'font-weight': '700'},
          ),
          [Component.text('Configure')],
        ),
        Component.text(' edits values in memory and on disk; '),
        span(
          styles: Styles(
            raw: {'color': 'var(--color-tui-orange)', 'font-weight': '700'},
          ),
          [Component.text('Apply')],
        ),
        Component.text(' commits + rebuilds NixOS.'),
      ]),
      ul(classes: 'space-y-2', [
        li([
          Component.text(
            'Press `[c]` from the dashboard. Tab through service tabs (system, bitcoind, lnd, …).',
          ),
        ]),
        li([
          Component.text(
            'Edit values inline. Each row that differs from the last Apply gets a yellow `*` marker.',
          ),
        ]),
        li([
          Component.text(
            'The header status flips from `all applied` to `X pending` as you go.',
          ),
        ]),
        li([
          Component.text(
            'Press `[a]` Apply. Review the unified screen — local config '
            'diff, any staged upstream pin moves, plugin updates, package '
            'diff — then confirm.',
          ),
        ]),
        li([
          Component.text(
            'TUI runs `nixos-rebuild switch`, streams output live, reports success/partial/failure.',
          ),
        ]),
      ]),
      p(
        classes: 'mt-4',
        styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
        [
          Component.text(
            'Every Apply is a git commit. To roll back: `git revert <hash>` then '
            '`[a]` again. NixOS generations also stick around — '
            '`nixos-rebuild switch --rollback` works without the TUI.',
          ),
        ],
      ),
    ]);
  }
}

class _UpdateBody extends StatelessComponent {
  const _UpdateBody();

  @override
  Component build(BuildContext context) {
    return div([
      p(classes: 'mb-3', [
        Component.text(
          'Press `[a]` (Apply) or `[u]` (Update) from the dashboard. Both '
          'land on the System view; the sidebar splits read-only Check '
          'probes, destructive Apply (the only path that touches a '
          'generation), and Power (shutdown / reboot).',
        ),
      ]),
      ul(classes: 'space-y-2', [
        li([
          Component.text(
            'A daily `nixblitz check` timer probes each flake input + plugin '
            'against upstream HEAD, runs `nix build --dry-run` + `nvd diff` '
            'against the cache, and stages any lock / pin / nvd deltas '
            'under `/var/lib/nixblitz-tui/staging/`. Run it on demand via '
            'the Check menu.',
          ),
        ]),
        li([
          Component.text(
            'A dashboard banner surfaces what\'s queued: `updates available '
            '— checked Xh ago`. Empty when nothing\'s pending.',
          ),
        ]),
        li([
          Component.text(
            'Apply opens a single review screen listing everything queued '
            'for the next generation — local config edits, upstream pin '
            'updates, plugin updates, package diff — before any mutation. '
            'Confirm and the whole bundle commits + rebuilds atomically. '
            'No silent side effects: if it\'s on the screen, it lands.',
          ),
        ]),
        li([
          Component.text(
            'A compile-needed bail aborts the dry-run probe before '
            'realising the toplevel when any path isn\'t substitutable, '
            'so a rustc storm on Pi 5 never sneaks up on the operator. '
            'The would-build list is reachable via "View packages to '
            'compile."',
          ),
        ]),
      ]),
    ]);
  }
}

class _DebugBody extends StatelessComponent {
  const _DebugBody();

  @override
  Component build(BuildContext context) {
    return div([
      p(classes: 'mb-3', [
        Component.text(
          '`Shift-D` from the dashboard. For diagnosing problems and exercising '
          'regtest flows.',
        ),
      ]),
      ul(classes: 'space-y-2', [
        li([
          Component.text(
            'Service health: per-unit status, restart, journal tail.',
          ),
        ]),
        li([
          Component.text('Generate regtest blocks (numeric input, mine N).'),
        ]),
        li([
          Component.text(
            'Regtest auto-miner — transient systemd unit, mines on a random cadence, survives TUI exit.',
          ),
        ]),
        li([
          Component.text(
            'Test-LND helpers: status, fund, open channel, pay self-invoice (regtest only).',
          ),
        ]),
        li([
          Component.text(
            'Plugin actions: `command:` runs as admin; `unit:` dispatches a Type=oneshot service via sudo.',
          ),
        ]),
      ]),
    ]);
  }
}

/// Real screenshot from `examples_redesign/screenshots/`, copied into
/// `web/screenshots/` at build time. Click expands the image into a
/// fullscreen lightbox via CSS `:target` — no JavaScript required for
/// the open/close, see `.lightbox` rules in `web/input.css`.
class _Screenshot extends StatelessComponent {
  final String src;
  final String alt;
  final String caption;

  const _Screenshot({
    required this.src,
    required this.alt,
    required this.caption,
  });

  /// Derives a stable, URL-safe lightbox id from the image filename.
  /// `/screenshots/dashboard.png` → `lb-dashboard`.
  String get _lightboxId {
    final base = src.split('/').last.split('.').first;
    return 'lb-$base';
  }

  @override
  Component build(BuildContext context) {
    return Tile(
      title: 'screenshot',
      titleColor: 'muted',
      children: [
        a(
          href: '#$_lightboxId',
          classes: 'block cursor-zoom-in',
          attributes: {'aria-label': 'Open $alt fullscreen'},
          [
            img(
              src: href(src),
              classes: 'w-full block',
              attributes: {'alt': alt, 'loading': 'lazy'},
            ),
          ],
        ),
        p(
          classes: 'mt-3 text-sm',
          styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
          [Component.text(caption)],
        ),
        div(
          id: _lightboxId,
          classes: 'lightbox',
          attributes: {'role': 'dialog', 'aria-modal': 'true'},
          [
            // Backdrop link covers the whole overlay; clicking
            // anywhere outside the image closes the lightbox.
            a(
              href: '#',
              classes: 'lightbox-backdrop',
              attributes: {'aria-label': 'Close'},
              [],
            ),
            div(classes: 'lightbox-content', [
              img(
                src: href(src),
                classes: 'lightbox-image',
                attributes: {'alt': alt},
              ),
              a(href: '#', classes: 'lightbox-close keybind', [
                span(classes: 'key', [Component.text('[esc]')]),
                Component.text(' close'),
              ]),
            ]),
          ],
        ),
      ],
    );
  }
}
