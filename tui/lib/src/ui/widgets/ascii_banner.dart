import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart' show nixblitzAsciiBanner;

/// Renders the shared NIXBLITZ figlet wordmark in Bitcoin orange.
/// Used at the top of the install wizard's first screen and the
/// first-boot setup's first step — same wordmark the website hero
/// shows, kept in sync via `common`'s `nixblitzAsciiBanner` const.
///
/// Six lines, 56 columns wide. Renders unconditionally; tiny
/// terminals (< 56 cols) clip on the right. If a real surface
/// hits that case, gate via `MediaQuery` and skip the widget
/// when there isn't room.
class AsciiBanner extends StatelessComponent {
  const AsciiBanner({super.key});

  static const _kOrange = Color.fromRGB(247, 147, 26);

  @override
  Component build(BuildContext context) {
    // Splitting on '\n' so each line becomes a separate Text widget.
    // A single Text with embedded newlines would also work, but the
    // per-line approach is simpler to reason about for terminal
    // wrapping behaviour and matches how nocterm handles ASCII art
    // in other widgets.
    final lines = nixblitzAsciiBanner.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          if (line.isNotEmpty)
            Text(line, style: const TextStyle(color: _kOrange)),
      ],
    );
  }
}
