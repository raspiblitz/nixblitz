import 'package:nocterm/nocterm.dart';

/// Adds a tap (mouse-press / touch) target around [child]. Fires
/// [onTap] when a primary-button press lands inside the widget's
/// box — covers both desktop mouse clicks and SSH-over-phone touch
/// taps, since both surface as SGR mouse sequences nocterm already
/// parses.
///
/// Implementation rides on [MouseRegion]'s hover callback rather
/// than the global mouse stream: the framework's hit-test runs for
/// every event (press, release, motion), and dispatches `onHover`
/// to every region currently under the pointer. Filtering for
/// `pressed && button == left && !isMotion` inside the hover
/// callback gives us a "primary press inside my box" signal
/// without an explicit subscription / hit-test of our own.
///
/// Tap fires on PRESS, not release — matches Material's
/// InkResponse and iOS's tap-down feedback. The two-press
/// confirmation pattern used for destructive actions (System →
/// Power, plugin install consent) carries over by having the first
/// tap arm a flag and the second tap confirm — same shape as the
/// keyboard arming model.
class Tappable extends StatelessComponent {
  final Component child;
  final VoidCallback onTap;

  /// When true (default), the region is opaque to hit testing —
  /// taps don't fall through to widgets behind it. Set false for
  /// transparent overlays (rare).
  final bool opaque;

  const Tappable({
    super.key,
    required this.child,
    required this.onTap,
    this.opaque = true,
  });

  @override
  Component build(BuildContext context) {
    return MouseRegion(
      opaque: opaque,
      onHover: (event) {
        if (event.pressed &&
            event.button == MouseButton.left &&
            !event.isMotion) {
          onTap();
        }
      },
      child: child,
    );
  }
}
