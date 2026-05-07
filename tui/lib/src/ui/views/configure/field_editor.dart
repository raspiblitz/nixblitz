import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import '../../widgets/option_editor.dart';

// ---------------------------------------------------------------------------
// Display helpers
// ---------------------------------------------------------------------------

/// Format a field's current value for display. Falls back to the field's
/// [AppConfigField.defaultValue] when [value] is null. Public for testability.
///
/// [SecretField] always renders as `(unset)` or `•••` to avoid
/// shoulder-surfing leaks — the actual value is never shown in the
/// read-only row, only in the edit overlay (where the operator already
/// has eyes on the input).
String formatFieldValue(AppConfigField field, dynamic value) {
  return switch (field) {
    BoolField() => (value as bool? ?? field.defaultValue) ? 'on' : 'off',
    StringField() => (value as String? ?? field.defaultValue),
    SecretField() =>
      ((value as String? ?? field.defaultValue).isEmpty) ? '(unset)' : '•••',
    IntField() => '${value as int? ?? field.defaultValue}',
    EnumField() => (value as String? ?? field.defaultValue),
  };
}

// ---------------------------------------------------------------------------
// FieldDisplayRow
// ---------------------------------------------------------------------------

/// Read-only display row for one manifest-declared field.
///
/// Renders using the existing [BoolOptionEditor], [TextOptionEditor],
/// [NumberOptionEditor], and [SelectOptionEditor] primitives from
/// `option_editor.dart` so the appearance is consistent with the
/// hand-coded configure_view rows.
///
/// [pending] lights the trailing `*` marker (value differs from HEAD).
/// [selected] highlights the row with the orange focus colour.
class FieldDisplayRow extends StatelessComponent {
  final AppConfigField field;
  final dynamic currentValue;
  final bool selected;
  final bool pending;

  const FieldDisplayRow({
    required this.field,
    required this.currentValue,
    this.selected = false,
    this.pending = false,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    return switch (field) {
      BoolField f => BoolOptionEditor(
        label: f.label,
        value: currentValue as bool? ?? f.defaultValue,
        focused: selected,
        pending: pending,
      ),
      StringField f => TextOptionEditor(
        label: f.label,
        value: currentValue as String? ?? f.defaultValue,
        focused: selected,
        pending: pending,
      ),
      SecretField f => TextOptionEditor(
        label: f.label,
        // Masked display — see formatFieldValue for the same masking
        // logic. Never shows the underlying credential at rest; the
        // edit overlay handles input visibility.
        value: ((currentValue as String? ?? f.defaultValue).isEmpty)
            ? '(unset)'
            : '•••',
        focused: selected,
        pending: pending,
      ),
      IntField f => NumberOptionEditor(
        label: f.label,
        value: currentValue as int? ?? f.defaultValue,
        focused: selected,
        pending: pending,
      ),
      EnumField f => SelectOptionEditor(
        label: f.label,
        value: currentValue as String? ?? f.defaultValue,
        options: f.choices,
        focused: selected,
        pending: pending,
      ),
    };
  }
}

// ---------------------------------------------------------------------------
// Editor overlay widgets
// ---------------------------------------------------------------------------

/// Inline text-input overlay for [StringField] values.
///
/// Mirrors the inline text-edit flow that configure_view uses for hostname,
/// timezone, and LND alias: a [_buffer] string is mutated via key events,
/// committed on Enter, cancelled on Esc.
///
/// [onSubmit] receives the new trimmed string value. [onCancel] is called on
/// Esc. Task 7 will wire these callbacks into the generic configure_view
/// walker.
class StringFieldEditor extends StatefulComponent {
  final StringField field;
  final String initialValue;
  final void Function(String value) onSubmit;
  final VoidCallback onCancel;

  const StringFieldEditor({
    super.key,
    required this.field,
    required this.initialValue,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<StringFieldEditor> createState() => _StringFieldEditorState();
}

class _StringFieldEditorState extends State<StringFieldEditor> {
  late String _buffer;

  @override
  void initState() {
    super.initState();
    _buffer = component.initialValue;
  }

  @override
  Component build(BuildContext context) {
    final comp = component;
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            comp.onCancel();
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            comp.onSubmit(_buffer);
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            if (_buffer.isNotEmpty) {
              setState(
                () => _buffer = _buffer.substring(0, _buffer.length - 1),
              );
            }
            return true;
          }
          final ch = event.character;
          if (ch != null && ch.length == 1) {
            final code = ch.codeUnitAt(0);
            if (code >= 0x20 && code <= 0x7E) {
              setState(() => _buffer += ch);
            }
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('StringFieldEditor key handler failed', e, st);
          return true;
        }
      },
      child: TextOptionEditor(
        label: comp.field.label,
        value: '${_buffer}_',
        focused: true,
      ),
    );
  }
}

/// Inline credential-input overlay for [SecretField] values.
///
/// Behaves like [StringFieldEditor] (Esc cancels, Enter submits the
/// trimmed buffer, backspace deletes, printable ASCII appends) but
/// renders the input MASKED — the rendered value shows one `•` per
/// buffer character followed by the cursor `_`. Operators get the
/// confirmation that "yes, my keystroke registered" without the actual
/// secret hitting the screen / a recording / a screenshot.
class SecretFieldEditor extends StatefulComponent {
  final SecretField field;
  final String initialValue;
  final void Function(String value) onSubmit;
  final VoidCallback onCancel;

  const SecretFieldEditor({
    super.key,
    required this.field,
    required this.initialValue,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<SecretFieldEditor> createState() => _SecretFieldEditorState();
}

class _SecretFieldEditorState extends State<SecretFieldEditor> {
  late String _buffer;

  @override
  void initState() {
    super.initState();
    _buffer = component.initialValue;
  }

  @override
  Component build(BuildContext context) {
    final comp = component;
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            comp.onCancel();
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            comp.onSubmit(_buffer);
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            if (_buffer.isNotEmpty) {
              setState(
                () => _buffer = _buffer.substring(0, _buffer.length - 1),
              );
            }
            return true;
          }
          final ch = event.character;
          if (ch != null && ch.length == 1) {
            final code = ch.codeUnitAt(0);
            if (code >= 0x20 && code <= 0x7E) {
              setState(() => _buffer += ch);
            }
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('SecretFieldEditor key handler failed', e, st);
          return true;
        }
      },
      child: TextOptionEditor(
        label: comp.field.label,
        // Mask: one bullet per character + cursor. Length confirms
        // input registered without leaking the value.
        value: '${'•' * _buffer.length}_',
        focused: true,
      ),
    );
  }
}

/// Inline numeric-input overlay for [IntField] values.
///
/// Accepts digits only. Parses the buffer as int on Enter; falls back to
/// [IntField.defaultValue] if the buffer is empty or non-numeric. Respects
/// [IntField.min] and [IntField.max] by clamping before calling [onSubmit].
class IntFieldEditor extends StatefulComponent {
  final IntField field;
  final int initialValue;
  final void Function(int value) onSubmit;
  final VoidCallback onCancel;

  const IntFieldEditor({
    super.key,
    required this.field,
    required this.initialValue,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<IntFieldEditor> createState() => _IntFieldEditorState();
}

class _IntFieldEditorState extends State<IntFieldEditor> {
  late String _buffer;

  @override
  void initState() {
    super.initState();
    _buffer = '${component.initialValue}';
  }

  int _parsed() {
    final n = int.tryParse(_buffer) ?? component.field.defaultValue;
    final min = component.field.min;
    final max = component.field.max;
    if (min != null && n < min) return min;
    if (max != null && n > max) return max;
    return n;
  }

  @override
  Component build(BuildContext context) {
    final comp = component;
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            comp.onCancel();
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            comp.onSubmit(_parsed());
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            if (_buffer.isNotEmpty) {
              setState(
                () => _buffer = _buffer.substring(0, _buffer.length - 1),
              );
            }
            return true;
          }
          final ch = event.character;
          if (ch != null && ch.length == 1) {
            final code = ch.codeUnitAt(0);
            if (code >= 0x30 && code <= 0x39) {
              // digits only for numeric fields
              setState(() => _buffer += ch);
            }
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('IntFieldEditor key handler failed', e, st);
          return true;
        }
      },
      child: NumberOptionEditor(
        label: comp.field.label,
        value: int.tryParse(_buffer) ?? comp.field.defaultValue,
        focused: true,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit-mode dispatcher
// ---------------------------------------------------------------------------

/// Returns `true` if [field] is edited via an overlay widget (see
/// [buildFieldEditor]).  Returns `false` for fields whose value is cycled
/// in-place (currently only [BoolField]).
bool fieldRequiresEditor(AppConfigField field) {
  return switch (field) {
    BoolField() => false,
    StringField() => true,
    SecretField() => true,
    IntField() => true,
    // EnumField uses SelectOptionEditor cycling in-place (like configure_view's
    // SelectOptionEditor rows do today). Task 7 may change this to a SelectPopup
    // overlay — for now, cycle in-place keeps parity with the existing view.
    EnumField() => false,
  };
}

/// Toggle / cycle a [BoolField] or [EnumField] value in-place.
///
/// Returns the new value. Throws [ArgumentError] if [field] requires an
/// overlay editor instead (i.e. [fieldRequiresEditor] returns true).
dynamic cycleFieldValue(AppConfigField field, dynamic current) {
  return switch (field) {
    BoolField f => !(current as bool? ?? f.defaultValue),
    EnumField f => _cycleEnum(f, current as String?),
    StringField() => throw ArgumentError(
      'StringField requires an overlay editor — call buildFieldEditor instead',
    ),
    SecretField() => throw ArgumentError(
      'SecretField requires an overlay editor — call buildFieldEditor instead',
    ),
    IntField() => throw ArgumentError(
      'IntField requires an overlay editor — call buildFieldEditor instead',
    ),
  };
}

String _cycleEnum(EnumField field, String? current) {
  final choices = field.choices;
  final idx = current != null ? choices.indexOf(current) : -1;
  return choices[(idx + 1) % choices.length];
}

/// Build the appropriate editor overlay for [field].
///
/// The returned [Component] is a self-contained, focusable overlay. The
/// caller is responsible for inserting it into the widget tree (typically
/// replacing the configure view's body while in edit mode) and for calling
/// [onSubmit] / [onCancel] to return control.
///
/// Only valid for fields where [fieldRequiresEditor] returns true; calling
/// this for a [BoolField] or [EnumField] throws [ArgumentError].
Component buildFieldEditor({
  required AppConfigField field,
  required dynamic currentValue,
  required void Function(dynamic value) onSubmit,
  required VoidCallback onCancel,
}) {
  return switch (field) {
    BoolField() => throw ArgumentError(
      'BoolField is edited in-place; use cycleFieldValue',
    ),
    EnumField() => throw ArgumentError(
      'EnumField is cycled in-place; use cycleFieldValue',
    ),
    StringField f => StringFieldEditor(
      field: f,
      initialValue: currentValue as String? ?? f.defaultValue,
      onSubmit: (v) => onSubmit(v),
      onCancel: onCancel,
    ),
    SecretField f => SecretFieldEditor(
      field: f,
      initialValue: currentValue as String? ?? f.defaultValue,
      onSubmit: (v) => onSubmit(v),
      onCancel: onCancel,
    ),
    IntField f => IntFieldEditor(
      field: f,
      initialValue: currentValue as int? ?? f.defaultValue,
      onSubmit: (v) => onSubmit(v),
      onCancel: onCancel,
    ),
  };
}
