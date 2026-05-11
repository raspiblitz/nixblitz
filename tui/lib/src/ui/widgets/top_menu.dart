import 'package:nocterm/nocterm.dart';

import '../../providers/ui_state_provider.dart';

/// One entry in the top menu strip — a label paired with the
/// [AppView] it targets. Selection moves the operator to that view
/// immediately (no Enter step).
class TopMenuEntry {
  final String label;
  final AppView view;
  const TopMenuEntry({required this.label, required this.view});
}

/// Canonical ordered list of view entries shown in the top menu.
/// Help / Quit are NOT in the strip — they stay as their `?` / `q`
/// hotkey shortcuts; the strip is for view navigation only.
const List<TopMenuEntry> kTopMenuEntries = [
  TopMenuEntry(label: 'Dashboard', view: AppView.dashboard),
  TopMenuEntry(label: 'Configure', view: AppView.configure),
  TopMenuEntry(label: 'Apply', view: AppView.apply),
  TopMenuEntry(label: 'Update', view: AppView.update),
  TopMenuEntry(label: 'Debug', view: AppView.debug),
];

/// Find the menu index that matches [view], or -1 if [view] is one
/// of the lifecycle views (install / setup / configTooNew) that
/// don't appear in the strip.
int topMenuIndexForView(AppView view) {
  for (var i = 0; i < kTopMenuEntries.length; i++) {
    if (kTopMenuEntries[i].view == view) return i;
  }
  return -1;
}

/// Horizontal menu strip rendered between the header and the view
/// body. Stateless — the active entry is derived from
/// `currentViewProvider`; navigation is handled by the global
/// `_Shell.onKeyEvent` so the strip doesn't need its own focus.
///
/// Visual: active entry in the accent color + brackets, others
/// dim. Help / Quit hotkey hints sit on the right.
class TopMenu extends StatelessComponent {
  final AppView activeView;

  const TopMenu({super.key, required this.activeView});

  @override
  Component build(BuildContext context) {
    const accent = Color.fromRGB(247, 147, 26);
    const idle = Color.fromRGB(150, 150, 180);
    const dim = Color.fromRGB(120, 120, 140);

    final children = <Component>[];
    for (var i = 0; i < kTopMenuEntries.length; i++) {
      if (i > 0) {
        children.add(const Text('  ', style: TextStyle(color: dim)));
      }
      final entry = kTopMenuEntries[i];
      final isActive = entry.view == activeView;
      final label = isActive ? '[${entry.label}]' : ' ${entry.label} ';
      children.add(
        Text(
          label,
          style: TextStyle(
            color: isActive ? accent : idle,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
      decoration: const BoxDecoration(
        border: BoxBorder(
          bottom: BorderSide(color: Color.fromRGB(80, 80, 100)),
        ),
      ),
      child: Row(
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: children),
          Expanded(child: const SizedBox.shrink()),
          const Text('[?] Help   [q] Quit', style: TextStyle(color: dim)),
        ],
      ),
    );
  }
}
