import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

import 'tile.dart';

/// Wraps an asciinema cast file in a `Tile`, paired with a caption.
///
/// Player init is centralised: the global walker injected into
/// `<head>` from `main.server.dart` finds every element with a
/// `data-asciinema-cast` attribute on `DOMContentLoaded` and calls
/// `AsciinemaPlayer.create(...)` against it. That keeps the
/// per-cast markup tiny — just a div with data-* attributes — and
/// avoids one inline `<script>` per cast.
class AsciinemaCast extends StatelessComponent {
  final String src;
  final String caption;
  final int cols;
  final int rows;

  /// `npt:M:S` jumps the poster frame to that timestamp; null
  /// means the player shows the first frame as the poster.
  final String? poster;

  /// Compress idle stretches longer than this (in seconds) so a
  /// cast with a 30-second pause doesn't actually pause for 30s
  /// during playback. asciinema's recommended default is 2.0.
  final double idleTimeLimit;

  const AsciinemaCast({
    required this.src,
    required this.caption,
    this.cols = 80,
    this.rows = 20,
    this.poster,
    this.idleTimeLimit = 2.0,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final attrs = <String, String>{
      'data-asciinema-cast': src,
      'data-cols': '$cols',
      'data-rows': '$rows',
      'data-idle-time-limit': '$idleTimeLimit',
    };
    if (poster != null) {
      attrs['data-poster'] = poster!;
    }

    return Tile(
      title: 'asciicast',
      titleColor: 'muted',
      children: [
        div(classes: 'asciinema-cast', attributes: attrs, []),
        p(
          classes: 'mt-3 text-sm',
          styles: Styles(raw: {'color': 'var(--color-tui-muted)'}),
          [Component.text(caption)],
        ),
      ],
    );
  }
}
