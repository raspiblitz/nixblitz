import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

import '../components/tile.dart';

/// `figlet -f "ANSI Shadow" NIXBLITZ` — the wordmark in the hero.
/// Kept as a single string literal so the layout is exactly what
/// figlet emits; CSS handles overflow on narrow viewports.
const String _asciiBanner = r'''
███╗   ██╗██╗██╗  ██╗██████╗ ██╗     ██╗████████╗███████╗
████╗  ██║██║╚██╗██╔╝██╔══██╗██║     ██║╚══██╔══╝╚══███╔╝
██╔██╗ ██║██║ ╚███╔╝ ██████╔╝██║     ██║   ██║     ███╔╝
██║╚██╗██║██║ ██╔██╗ ██╔══██╗██║     ██║   ██║    ███╔╝
██║ ╚████║██║██╔╝ ██╗██████╔╝███████╗██║   ██║   ███████╗
╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝   ╚═╝   ╚══════╝
''';

const String _kRepoUrl = 'https://forge.f44.fyi/f44/nixblitz_ng';

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
        media: const _InstallPlaceholder(),
      ),
      _section(
        anchor: 'the-tui',
        title: 'the tui',
        text: const _TuiBody(),
        media: const _Screenshot(
          src: '/screenshots/dashboard.png',
          alt: 'The dashboard view: header, tile grid, footer keybind hints.',
          caption: 'Dashboard — the home screen after first-boot setup.',
        ),
      ),
      _section(
        anchor: 'configure-apply',
        title: 'configure → apply',
        text: const _ConfigureApplyBody(),
        media: const _Screenshot(
          src: '/screenshots/configuration_menu.png',
          alt: 'The Configure view: tabs across services, editable rows.',
          caption: 'Configure — edit values; apply commits and rebuilds.',
        ),
      ),
      _section(
        anchor: 'update',
        title: 'update menu',
        text: const _UpdateBody(),
        media: const _Screenshot(
          src: '/screenshots/update_menu.png',
          alt: 'The Update view: lists available upstream updates.',
          caption: 'Update — pull TUI, flake, and plugin updates.',
        ),
      ),
      _section(
        anchor: 'debug',
        title: 'debug menu',
        text: const _DebugBody(),
        media: const _Screenshot(
          src: '/screenshots/debug_menu.png',
          alt: 'The Debug view: service health, log tail, regtest helpers.',
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
          classes:
              'ascii-banner inline-block text-[0.5rem] sm:text-xs md:text-sm lg:text-base mx-auto',
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
                'Stock NixOS ISO → working node, x86 + Pi 5 walkthrough.',
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

  Component _docLink(String href, String label, String desc) {
    return li(classes: 'flex flex-wrap items-baseline gap-x-3', [
      a(href: href, classes: 'keybind', [
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
          'Boot a live image, run one command, walk a three-question '
          'wizard, reboot into a working node. On x86 the live image is '
          'stock NixOS from nixos.org — NixBlitz isn\'t baked in, the '
          'TUI bootstraps over the network. Pi 5 currently uses a '
          'third-party live image (a NixBlitz-branded Pi 5 image is on '
          'the roadmap).',
        ),
      ]),
      pre(
        classes: 'text-xs sm:text-sm overflow-x-auto p-3 my-3',
        styles: Styles(
          raw: {
            'background': 'var(--background)',
            'border': '1px solid var(--border)',
          },
        ),
        [
          Component.text(
            'nix run git+https://forge.f44.fyi/f44/nixblitz_ng \\\n'
            '  --experimental-features "nix-command flakes" \\\n'
            '  --no-write-lock-file --refresh',
          ),
        ],
      ),
      ul(classes: 'space-y-1.5 mt-2', [
        _step(
          '1',
          'Boot the NixOS 25.11 minimal ISO (or the Pi 5 live image).',
        ),
        _step(
          '2',
          'Run the bootstrap above. The TUI launches in install mode.',
        ),
        _step(
          '3',
          'Pick disk, network (mainnet / regtest), Lightning backend.',
        ),
        _step(
          '4',
          '`disko-install` partitions, copies, installs the bootloader.',
        ),
        _step(
          '5',
          'Reboot. First-boot wizard sets the admin password and brings services up.',
        ),
        _step('6', 'Back up the LND seed when prompted. Done.'),
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
            'Press `[a]` Apply. Review the unified `git diff`, confirm.',
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
          'Press `[u]` from the dashboard. The Update view pulls upstream HEAD '
          'for each flake input (nixpkgs, nix-bitcoin, etc.), shows what would '
          'change, and offers a single rebuild step.',
        ),
      ]),
      ul(classes: 'space-y-2', [
        li([
          Component.text(
            'Daily lightweight check (`nixblitz check light`) hits each input\'s API for branch HEAD.',
          ),
        ]),
        li([
          Component.text(
            'Weekly heavy check evaluates the new system + runs `nvd diff` for a per-package version delta.',
          ),
        ]),
        li([
          Component.text(
            'A dashboard banner surfaces results: `updates available — checked Xh ago`.',
          ),
        ]),
        li([
          Component.text(
            'Any unapplied Configure changes are applied during the same rebuild — one transaction.',
          ),
        ]),
        li([
          Component.text(
            'Plugin updates flow through the same path: `nixblitz plugin refresh` per plugin or system-wide.',
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
              src: src,
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
                src: src,
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

/// Placeholder tile for sections without a real screenshot yet (the
/// installation flow). A future media drop replaces this with a clip
/// or a frame.
class _InstallPlaceholder extends StatelessComponent {
  const _InstallPlaceholder();

  @override
  Component build(BuildContext context) {
    return Tile(
      title: 'media',
      titleColor: 'muted',
      status: 'placeholder',
      statusColor: 'muted',
      extraClasses: 'min-h-[280px]',
      children: [
        div(
          classes:
              'flex flex-col items-center justify-center text-center min-h-[240px] dotted-bg p-8',
          [
            p(
              classes: 'text-sm mb-2',
              styles: Styles(
                raw: {'color': 'var(--color-tui-orange)', 'font-weight': '700'},
              ),
              [Component.text('install wizard clip')],
            ),
            p(
              classes: 'text-sm',
              styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
              [
                Component.text(
                  'disk pick → network → lightning → confirm → reboot',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
