import 'dart:async';
import 'package:nocterm/nocterm.dart';

/// A braille-dots spinner that animates at 100ms intervals.
/// Use with an optional label: `Spinner(label: 'Loading...')`
class Spinner extends StatefulComponent {
  final Color color;
  final String? label;

  const Spinner({
    super.key,
    this.color = const Color.fromRGB(247, 147, 26),
    this.label,
  });

  @override
  State<Spinner> createState() => SpinnerState();
}

class SpinnerState extends State<Spinner> {
  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() {
        _index = (_index + 1) % _frames.length;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    // Access component properties via the generic type
    final label = component.label;
    final color = component.color;

    if (label != null) {
      return Row(
        children: [
          Text(_frames[_index], style: TextStyle(color: color)),
          Text(' $label', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ],
      );
    }

    return Text(_frames[_index], style: TextStyle(color: color));
  }
}
