import 'package:nocterm/nocterm.dart';

/// Yellow used for the `*` pending-change marker. Same shade
/// as the dashboard's drift banner so the operator's eye reads
/// the two as the same "needs your attention" cue.
const _kPendingColor = Color.fromRGB(220, 180, 100);

/// Trailing-marker chunk shown after every option editor when
/// the row's value differs from `HEAD:config.json`. Single
/// space + asterisk in yellow, no row tint — focus orange and
/// pending yellow live in different positions and don't fight
/// each other.
Component _pendingMarker(bool pending) {
  if (!pending) return const SizedBox.shrink();
  return const Text(' *', style: TextStyle(color: _kPendingColor));
}

class BoolOptionEditor extends StatelessComponent {
  final String label;
  final bool value;
  final bool focused;
  final bool pending;
  final ValueChanged<bool>? onChanged;

  const BoolOptionEditor({
    super.key,
    required this.label,
    required this.value,
    this.focused = false,
    this.pending = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final check = value ? 'x' : ' ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    return Row(
      children: [
        Text('$prefix$label: [$check]', style: TextStyle(color: color)),
        _pendingMarker(pending),
      ],
    );
  }
}

class SelectOptionEditor extends StatelessComponent {
  final String label;
  final String value;
  final List<String> options;
  final bool focused;
  final bool pending;
  final ValueChanged<String>? onChanged;

  const SelectOptionEditor({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    this.focused = false,
    this.pending = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    return Row(
      children: [
        Text('$prefix$label: [$value]', style: TextStyle(color: color)),
        _pendingMarker(pending),
      ],
    );
  }
}

class NumberOptionEditor extends StatelessComponent {
  final String label;
  final int value;
  final String unit;
  final bool focused;
  final bool pending;
  final ValueChanged<int>? onChanged;

  const NumberOptionEditor({
    super.key,
    required this.label,
    required this.value,
    this.unit = '',
    this.focused = false,
    this.pending = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    final suffix = unit.isNotEmpty ? ' $unit' : '';
    return Row(
      children: [
        Text('$prefix$label: [$value$suffix]', style: TextStyle(color: color)),
        _pendingMarker(pending),
      ],
    );
  }
}

class TextOptionEditor extends StatelessComponent {
  final String label;
  final String value;
  final bool focused;
  final bool pending;
  final ValueChanged<String>? onChanged;

  const TextOptionEditor({
    super.key,
    required this.label,
    required this.value,
    this.focused = false,
    this.pending = false,
    this.onChanged,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    return Row(
      children: [
        Text('$prefix$label: [$value]', style: TextStyle(color: color)),
        _pendingMarker(pending),
      ],
    );
  }
}
