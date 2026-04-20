import 'package:nocterm/nocterm.dart';

class BoolOptionEditor extends StatelessComponent {
  final String label;
  final bool value;
  final bool focused;
  final ValueChanged<bool>? onChanged;

  const BoolOptionEditor({super.key, required this.label, required this.value, this.focused = false, this.onChanged});

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final check = value ? 'x' : ' ';
    final color = focused ? const Color.fromRGB(247, 147, 26) : const Color.fromRGB(200, 200, 200);
    return Text('$prefix$label: [$check]', style: TextStyle(color: color));
  }
}

class SelectOptionEditor extends StatelessComponent {
  final String label;
  final String value;
  final List<String> options;
  final bool focused;
  final ValueChanged<String>? onChanged;

  const SelectOptionEditor({super.key, required this.label, required this.value, required this.options, this.focused = false, this.onChanged});

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused ? const Color.fromRGB(247, 147, 26) : const Color.fromRGB(200, 200, 200);
    return Text('$prefix$label: [$value]', style: TextStyle(color: color));
  }
}

class NumberOptionEditor extends StatelessComponent {
  final String label;
  final int value;
  final String unit;
  final bool focused;
  final ValueChanged<int>? onChanged;

  const NumberOptionEditor({super.key, required this.label, required this.value, this.unit = '', this.focused = false, this.onChanged});

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused ? const Color.fromRGB(247, 147, 26) : const Color.fromRGB(200, 200, 200);
    final suffix = unit.isNotEmpty ? ' $unit' : '';
    return Text('$prefix$label: [$value$suffix]', style: TextStyle(color: color));
  }
}

class TextOptionEditor extends StatelessComponent {
  final String label;
  final String value;
  final bool focused;
  final ValueChanged<String>? onChanged;

  const TextOptionEditor({super.key, required this.label, required this.value, this.focused = false, this.onChanged});

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused ? const Color.fromRGB(247, 147, 26) : const Color.fromRGB(200, 200, 200);
    return Text('$prefix$label: [$value]', style: TextStyle(color: color));
  }
}
