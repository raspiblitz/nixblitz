import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

/// Manifest-driven plugin-config field renderers.
///
/// Two widgets cover Phase 2:
///
/// - [PluginFieldRow] — inline single-line display of a field's
///   label + current value, shown in the list of fields. Mimics the
///   shape of `BoolOptionEditor` / `SelectOptionEditor` from
///   `option_editor.dart` so the plugin form visually matches the
///   main Configure view.
///
/// - [PluginTextOverlay] — full-focus text-input overlay for the
///   text-shaped field types (`string`, `secret`, `list&lt;string&gt;`).
///   Modeled on `password_input.dart`: `Focusable` + local buffer +
///   Enter to commit, Esc to cancel.
///
/// `bool` and `select&lt;…&gt;` don't need the overlay — the parent view
/// (`plugin_config_view.dart`) cycles them in place on Enter using
/// [cyclePrimitiveValue].

const _orange = Color.fromRGB(247, 147, 26);
const _dim = Color.fromRGB(200, 200, 200);
const _faint = Color.fromRGB(110, 110, 130);

/// True if the field needs a separate text-input overlay to edit
/// (`string` / `secret` / `list<…>`). False for `bool` + `select`
/// which cycle in place.
bool fieldRequiresOverlay(ConfigField spec) {
  final t = spec.type;
  if (t == 'bool') return false;
  if (t.startsWith('select<')) return false;
  if (t == 'string' || t == 'secret') return true;
  if (t.startsWith('list<')) return true;
  throw UnimplementedError(
    'plugin_field_editor: no editor for type `$t` yet. '
    'Supported in Phase 2: bool, string, secret, select<…>, list<string>.',
  );
}

/// Cycle a primitive value (bool toggle, select rotation). Returns
/// the new value, or null if this type requires the overlay instead.
dynamic cyclePrimitiveValue(ConfigField spec, dynamic current) {
  final t = spec.type;
  if (t == 'bool') {
    return !(current is bool ? current : false);
  }
  final sm = RegExp(r'^select<([^<>]+)>$').firstMatch(t);
  if (sm != null) {
    final choices = sm.group(1)!.split('|');
    final idx = current is String ? choices.indexOf(current) : -1;
    return choices[(idx + 1) % choices.length];
  }
  return null;
}

/// Compact human-readable rendering of a value for the field row.
/// Secrets are always masked.
String fieldDisplayValue(ConfigField spec, dynamic value) {
  if (spec.type == 'secret') {
    final len = value is String ? value.length : 0;
    return len == 0 ? '(unset)' : '*' * len.clamp(1, 8);
  }
  if (value == null) return '(unset)';
  if (spec.type.startsWith('list<')) {
    if (value is List) {
      if (value.isEmpty) return '[]';
      return value.join(', ');
    }
    return value.toString();
  }
  if (value is bool) return value ? 'x' : ' ';
  return value.toString();
}

class PluginFieldRow extends StatelessComponent {
  final ConfigField spec;
  final String fieldKey;
  final dynamic value;
  final bool focused;

  const PluginFieldRow({
    super.key,
    required this.spec,
    required this.fieldKey,
    required this.value,
    this.focused = false,
  });

  @override
  Component build(BuildContext context) {
    final prefix = focused ? '> ' : '  ';
    final color = focused ? _orange : _dim;
    final label = spec.label.isNotEmpty ? spec.label : fieldKey;
    final display = fieldDisplayValue(spec, value);
    final typeBadge = '(${spec.type})';

    return Row(
      children: [
        Text('$prefix$label: [$display]', style: TextStyle(color: color)),
        const SizedBox(width: 2),
        Text(typeBadge, style: const TextStyle(color: _faint)),
      ],
    );
  }
}

/// Full-focus text entry for `string` / `secret` / `list&lt;string&gt;`
/// fields. Caller renders this when the user hits Enter on a
/// text-shaped field; the widget's `onSubmit` returns the
/// already-deserialized value (`String` for string/secret,
/// `List&lt;String&gt;` for list). Caller is responsible for persisting
/// via the provider.
class PluginTextOverlay extends StatefulComponent {
  final ConfigField spec;
  final String fieldKey;
  final dynamic initialValue;
  final void Function(dynamic value) onSubmit;
  final VoidCallback onCancel;

  const PluginTextOverlay({
    super.key,
    required this.spec,
    required this.fieldKey,
    required this.initialValue,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<PluginTextOverlay> createState() => _PluginTextOverlayState();
}

class _PluginTextOverlayState extends State<PluginTextOverlay> {
  late String _buffer;
  bool _reveal = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _buffer = _initialBuffer();
  }

  String _initialBuffer() {
    final v = component.initialValue;
    if (v == null) return '';
    if (component.spec.type.startsWith('list<') && v is List) {
      return v.join(', ');
    }
    return v.toString();
  }

  bool get _isSecret => component.spec.type == 'secret';
  bool get _isList => component.spec.type.startsWith('list<');

  dynamic _parsedValue() {
    if (_isList) {
      // Comma-separated for Phase 2. Trim whitespace; drop empties.
      return _buffer
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return _buffer;
  }

  @override
  Component build(BuildContext context) {
    final comp = component;
    final spec = comp.spec;
    final label = spec.label.isNotEmpty ? spec.label : comp.fieldKey;
    final display = _isSecret && !_reveal
        ? '*' * _buffer.length
        : _buffer;

    final hint = _error ??
        (_isList
            ? 'Comma-separated values. Enter to save, Esc to cancel.'
            : 'Enter to save, Esc to cancel.'
                '${_isSecret ? '  [Tab] reveal' : ''}');
    final hintColor = _error != null
        ? const Color.fromRGB(255, 80, 80)
        : const Color.fromRGB(150, 150, 180);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            comp.onCancel();
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            final value = _parsedValue();
            final err = spec.validate(value);
            if (err != null) {
              setState(() => _error = err);
              return true;
            }
            comp.onSubmit(value);
            return true;
          }
          if (event.logicalKey == LogicalKey.tab && _isSecret) {
            setState(() => _reveal = !_reveal);
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            if (_buffer.isNotEmpty) {
              setState(() {
                _buffer = _buffer.substring(0, _buffer.length - 1);
                _error = null;
              });
            }
            return true;
          }
          final ch = event.character;
          if (ch != null && ch.isNotEmpty) {
            setState(() {
              _buffer += ch;
              _error = null;
            });
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('plugin text overlay key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit: $label',
              style: const TextStyle(
                color: _orange,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '(${spec.type})',
              style: const TextStyle(color: _faint),
            ),
            const SizedBox(height: 1),
            Text('$label: $display'),
            const SizedBox(height: 1),
            Text(hint, style: TextStyle(color: hintColor)),
          ],
        ),
      ),
    );
  }
}
