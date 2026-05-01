import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

import '../components/tile.dart';

class ChangelogPage extends StatelessComponent {
  const ChangelogPage({super.key});

  @override
  Component build(BuildContext context) {
    return div(classes: 'max-w-3xl mx-auto px-4 py-12 sm:py-16', [
      div(classes: 'mb-8', [
        span(
          classes: 'block text-sm tracking-widest uppercase mb-2',
          styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
          [Component.text('changelog')],
        ),
        h1(
          classes: 'text-3xl sm:text-4xl font-bold',
          styles: Styles(raw: {'color': 'var(--color-tui-orange)'}),
          [Component.text('Releases')],
        ),
      ]),
      Tile(
        title: 'unreleased',
        status: 'in development',
        statusColor: 'warn',
        children: [
          p(classes: 'mb-3', [
            Component.text(
              'NixBlitz is in active 0.x development. Tagged releases will land '
              'here once the install + first-boot flow is stable across both '
              'x86 and Pi 5 platforms.',
            ),
          ]),
          p(styles: Styles(raw: {'color': 'var(--color-tui-muted)'}), [
            Component.text('Track development at '),
            a(
              href: 'https://forge.f44.fyi/f44/nixblitz_ng',
              attributes: {'target': '_blank', 'rel': 'noopener noreferrer'},
              styles: Styles(
                raw: {
                  'color': 'var(--color-tui-orange)',
                  'text-decoration': 'underline',
                  'text-underline-offset': '4px',
                },
              ),
              [Component.text('forge.f44.fyi/f44/nixblitz_ng')],
            ),
            Component.text(
              '. Check `git log` on `main` for the latest activity, or '
              'subscribe to the release feed once the first tag lands.',
            ),
          ]),
        ],
      ),
    ]);
  }
}
