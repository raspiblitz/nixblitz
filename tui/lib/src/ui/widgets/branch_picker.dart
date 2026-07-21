import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

import 'popup_chrome.dart';

/// Outcome returned by [branchPickerChoice] — either the operator
/// picked one of the declared branch rows (and the result carries
/// the row's key, not its ref) or the trailing "Custom branch…"
/// row (and the caller transitions to a text-input phase).
sealed class BranchPickerSelection {
  const BranchPickerSelection();
}

/// The operator picked a declared row.
class DeclaredChoice extends BranchPickerSelection {
  const DeclaredChoice(this.key);
  final String key;
}

/// The operator picked the "Custom branch…" row — the caller
/// should transition to a free-form ref-input phase.
class CustomChoice extends BranchPickerSelection {
  const CustomChoice();
}

/// Number of navigable rows in the picker for the given manifest.
/// Always `declared.length + 1` (the +1 is the Custom branch row);
/// for a null manifest the count is `1`.
int branchPickerRowCount({required BranchManifest? manifest}) {
  return (manifest?.branches.length ?? 0) + 1;
}

/// Starting cursor index for the picker, derived from the
/// operator's current value:
///   - matches a declared key → that row's index
///   - starts with `custom:`  → the trailing Custom branch row
///   - null / unknown         → 0
int initialSelectedIndex({
  required BranchManifest? manifest,
  required String? currentValue,
}) {
  if (manifest == null) return 0;
  final v = currentValue;
  if (v == null) return 0;
  if (v.startsWith('custom:')) {
    // Custom branch row is at the end.
    return manifest.branches.length;
  }
  final keys = manifest.branches.keys.toList();
  final i = keys.indexOf(v);
  return i < 0 ? 0 : i;
}

/// Resolve a cursor index into the picker outcome — declared key
/// or the Custom branch sentinel. Does NOT include the encoded
/// `custom:<ref>` value; the caller fires that separately after
/// the operator types a ref.
BranchPickerSelection branchPickerChoice({
  required BranchManifest? manifest,
  required int selectedIndex,
}) {
  if (manifest == null) return const CustomChoice();
  final keys = manifest.branches.keys.toList();
  if (selectedIndex < keys.length) return DeclaredChoice(keys[selectedIndex]);
  return const CustomChoice();
}

/// Encode a free-form ref into the `custom:<ref>` form that the
/// rest of the system uses to disambiguate operator-typed refs
/// from declared keys. Trims whitespace.
String encodeCustomBranch(String ref) => 'custom:${ref.trim()}';

/// Extract the ref portion of a `custom:<ref>` current value so
/// the customInput phase can pre-fill its buffer; non-custom or
/// null values produce an empty string.
String prefilledCustomRef(String? currentValue) {
  final v = currentValue;
  if (v == null) return '';
  if (!v.startsWith('custom:')) return '';
  return v.substring('custom:'.length);
}

/// Build the picker's rendered text rows for the given state. The
/// cursor-marked row carries a leading "> " marker; the row
/// matching `currentValue` (declared key OR custom: sentinel)
/// carries a trailing " (current)" marker so the operator can see
/// what they're on regardless of where the cursor sits.
List<String> branchPickerRows({
  required BranchManifest? manifest,
  required String? currentValue,
  required int selectedIndex,
}) {
  final rows = <String>[];
  if (manifest != null) {
    final keys = manifest.branches.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      final branch = manifest.branches[key]!;
      final isSelected = i == selectedIndex;
      final isCurrent = key == currentValue;
      final prefix = isSelected ? '> ' : '  ';
      final suffix = isCurrent ? ' (current)' : '';
      final desc = branch.description;
      final descPart = (desc != null && desc.isNotEmpty) ? ' — $desc' : '';
      rows.add('$prefix$key (${branch.ref})$descPart$suffix');
    }
  }
  // Custom branch row — always last.
  final customIdx = (manifest?.branches.length ?? 0);
  final isSelected = selectedIndex == customIdx;
  final isCurrent = currentValue != null && currentValue.startsWith('custom:');
  final prefix = isSelected ? '> ' : '  ';
  final suffix = isCurrent ? ' (current)' : '';
  rows.add('${prefix}Custom branch…$suffix');
  return rows;
}

/// Phase model for the picker — list of declared rows + Custom
/// branch row, or the text-input field that opens after the
/// operator picks Custom branch.
enum _Phase { list, customInput }

/// Shared branch picker for nixblitz-self (System config) and
/// plugin switch flows. When [manifest] is null, only the
/// "Custom branch…" row is shown — the operator types a free-form
/// ref. When non-null, the declared rows are shown above the
/// Custom branch row.
///
/// [currentValue] is the operator's current pick, encoded as
/// either a declared key like "stable" / "next", or `custom:<ref>`
/// for a free-form ref, or null if no pick has been made yet. The
/// matching row carries a "(current)" marker so the operator can
/// see what they're on regardless of where the cursor sits.
///
/// [onSelected] fires once with the new value when the operator
/// confirms a row. For declared rows the value is the row's KEY
/// (not its underlying ref); for Custom branch, it's the encoded
/// `custom:<typed-ref>` form. [onCancel] fires on Esc from the
/// list phase — the caller decides whether that dismisses an
/// enclosing overlay or just yields focus.
class BranchPicker extends StatefulComponent {
  const BranchPicker({
    super.key,
    required this.manifest,
    required this.currentValue,
    required this.onSelected,
    this.onCancel,
    this.focused = true,
  });

  final BranchManifest? manifest;
  final String? currentValue;
  final void Function(String newValue) onSelected;
  final VoidCallback? onCancel;

  /// Whether the picker's Focusable should claim key events. Set
  /// to false when an enclosing modal popup is up, per CLAUDE.md
  /// pitfall #6 (modal focus gating).
  final bool focused;

  @override
  State<BranchPicker> createState() => _BranchPickerState();
}

class _BranchPickerState extends State<BranchPicker> {
  _Phase _phase = _Phase.list;
  late int _selected;
  late String _buffer;

  @override
  void initState() {
    super.initState();
    _selected = initialSelectedIndex(
      manifest: component.manifest,
      currentValue: component.currentValue,
    );
    _buffer = prefilledCustomRef(component.currentValue);
  }

  bool _handleListKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      component.onCancel?.call();
      return true;
    }
    final total = branchPickerRowCount(manifest: component.manifest);
    if (event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.keyJ) {
      setState(() => _selected = (_selected + 1) % total);
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.keyK) {
      setState(() => _selected = (_selected - 1 + total) % total);
      return true;
    }
    if (event.logicalKey == LogicalKey.enter) {
      final choice = branchPickerChoice(
        manifest: component.manifest,
        selectedIndex: _selected,
      );
      switch (choice) {
        case DeclaredChoice(:final key):
          component.onSelected(key);
        case CustomChoice():
          setState(() {
            _phase = _Phase.customInput;
            // Keep the existing buffer (pre-filled from current
            // value if it was custom:…); operator can clear with
            // Backspace if they want a fresh ref.
          });
      }
      return true;
    }
    return false;
  }

  bool _handleCustomInputKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      setState(() => _phase = _Phase.list);
      return true;
    }
    if (event.logicalKey == LogicalKey.enter) {
      final trimmed = _buffer.trim();
      if (trimmed.isEmpty) {
        // Don't fire onSelected for an empty ref — the encoded
        // value "custom:" would silently break downstream.
        return true;
      }
      component.onSelected(encodeCustomBranch(trimmed));
      return true;
    }
    if (event.logicalKey == LogicalKey.backspace) {
      if (_buffer.isNotEmpty) {
        setState(() => _buffer = _buffer.substring(0, _buffer.length - 1));
      }
      return true;
    }
    // Paste handler — bracketed-paste arrives as Ctrl+V via
    // terminal_binding.dart. Strip whitespace so the ref lands
    // cleanly without trailing newline.
    if (event.logicalKey == LogicalKey.keyV && event.modifiers.ctrl) {
      final pasted = ClipboardManager.paste();
      if (pasted != null && pasted.isNotEmpty) {
        setState(() => _buffer += pasted.trim());
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
  }

  // Popup styles pull from the shared palette (widgets/popup_chrome.dart)
  // so every overlay picker shares one chrome + color set.
  static const _heading = TextStyle(
    color: kPopupAccent,
    fontWeight: FontWeight.bold,
  );
  static const _body = TextStyle(color: kPopupBody);
  static const _dim = TextStyle(color: kPopupDim);

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: component.focused,
      onKeyEvent: (event) {
        try {
          switch (_phase) {
            case _Phase.list:
              return _handleListKey(event);
            case _Phase.customInput:
              return _handleCustomInputKey(event);
          }
        } catch (e, st) {
          LogService.error('Branch picker key handler failed', e, st);
          return true;
        }
      },
      // The list phases size to content (MainAxisSize.min) so the
      // overlay doesn't fill the screen; PopupChrome owns the border +
      // surface.
      child: PopupChrome(
        child: switch (_phase) {
          _Phase.list => _buildList(),
          _Phase.customInput => _buildCustomInput(),
        },
      ),
    );
  }

  Component _buildList() {
    final rows = branchPickerRows(
      manifest: component.manifest,
      currentValue: component.currentValue,
      selectedIndex: _selected,
    );
    final children = <Component>[const Text('Branch:', style: _heading)];
    for (var i = 0; i < rows.length; i++) {
      final isSelected = i == _selected;
      children.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(color: isSelected ? kPopupAccent : null),
          child: Text(
            rows[i],
            style: TextStyle(
              color: isSelected ? kPopupSelectedFg : kPopupBody,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      );
    }
    children.add(
      const Text('↑/↓ select  Enter confirm  Esc cancel', style: _dim),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Component _buildCustomInput() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Branch (custom ref):', style: _heading),
        Text('Ref: ${_buffer}_', style: _body),
        const Text('Enter confirm  Esc back', style: _dim),
      ],
    );
  }
}
