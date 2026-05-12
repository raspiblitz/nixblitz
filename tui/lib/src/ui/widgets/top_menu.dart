import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/ui_state_provider.dart';
import '../../providers/viewport_provider.dart';
import '../shutdown.dart';
import 'tappable.dart';

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
///
/// Apply and Update are intentionally absent: both are reached via
/// the unified System tab's Apply / Check sections.
const List<TopMenuEntry> kTopMenuEntries = [
  TopMenuEntry(label: 'Dashboard', view: AppView.dashboard),
  TopMenuEntry(label: 'Configure', view: AppView.configure),
  TopMenuEntry(label: 'System', view: AppView.system),
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
/// body. Two visual modes:
///
///   - Wide (terminal ≥ 60 cols): full strip with every entry
///     spelled out + `[?] Help [q] Quit` on the right.
///   - Compact (< 60 cols): `◀ [Active] ▶  ☰` — cycler arrows
///     flanking the active label, hamburger on the right. The
///     overlay opened by the hamburger lists every entry in a
///     centered modal (see [TopMenuOverlay]).
///
/// Stateless — the active entry is derived from
/// `currentViewProvider`; navigation is handled by the global
/// `_Shell.onKeyEvent` so the strip doesn't need its own focus.
class TopMenu extends StatelessComponent {
  final AppView activeView;

  const TopMenu({super.key, required this.activeView});

  @override
  Component build(BuildContext context) {
    final compact =
        context.watch(viewportClassProvider) == ViewportClass.compact;
    return compact ? _buildCompact(context) : _buildWide(context);
  }

  Component _buildWide(BuildContext context) {
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
        Tappable(
          onTap: () =>
              context.read(currentViewProvider.notifier).state = entry.view,
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? accent : idle,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
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
          Tappable(
            onTap: () =>
                context.read(helpVisibleProvider.notifier).state = true,
            child: const Text('[?] Help', style: TextStyle(color: dim)),
          ),
          const Text('   ', style: TextStyle(color: dim)),
          Tappable(
            onTap: () => shutdownWithTerminalRestore(),
            child: const Text('[q] Quit', style: TextStyle(color: dim)),
          ),
        ],
      ),
    );
  }

  Component _buildCompact(BuildContext context) {
    const accent = Color.fromRGB(247, 147, 26);
    const idle = Color.fromRGB(150, 150, 180);
    const dim = Color.fromRGB(120, 120, 140);

    final activeIdx = topMenuIndexForView(activeView);
    final activeLabel = activeIdx >= 0 ? kTopMenuEntries[activeIdx].label : '?';

    void cycle(int delta) {
      final n = kTopMenuEntries.length;
      final i = activeIdx < 0 ? 0 : activeIdx;
      final next = ((i + delta) % n + n) % n;
      context.read(currentViewProvider.notifier).state =
          kTopMenuEntries[next].view;
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
          Tappable(
            onTap: () => cycle(-1),
            child: const Text('◀ ', style: TextStyle(color: idle)),
          ),
          Expanded(
            child: Center(
              child: Tappable(
                // Tap on the active label also opens the overlay —
                // same target the hamburger covers, just bigger and
                // more obvious to a phone operator.
                onTap: () =>
                    context.read(topMenuOverlayProvider.notifier).state = true,
                child: Text(
                  '[$activeLabel]',
                  style: const TextStyle(
                    color: accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          Tappable(
            onTap: () => cycle(1),
            child: const Text(' ▶', style: TextStyle(color: idle)),
          ),
          Tappable(
            onTap: () =>
                context.read(topMenuOverlayProvider.notifier).state = true,
            child: const Text('  ☰', style: TextStyle(color: dim)),
          ),
        ],
      ),
    );
  }
}

/// Centered modal listing every menu entry, opened by tapping the
/// `☰` glyph in compact mode. Renders above the body in a Stack,
/// same pattern as [HelpPopup]. Tap an entry → switch view +
/// dismiss; Esc / `?` also dismisses.
class TopMenuOverlay extends StatelessComponent {
  const TopMenuOverlay({super.key});

  @override
  Component build(BuildContext context) {
    final activeView = context.watch(currentViewProvider);
    final viewportWidth = context.watch(viewportSizeProvider).width;
    final width = viewportWidth < 28 ? viewportWidth - 4 : 24;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape ||
            event.logicalKey == LogicalKey.question) {
          context.read(topMenuOverlayProvider.notifier).state = false;
          return true;
        }
        return false;
      },
      child: Center(
        child: Container(
          width: width.toDouble(),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            border: BoxBorder.all(color: const Color.fromRGB(247, 147, 26)),
            color: const Color.fromRGB(24, 24, 36),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in kTopMenuEntries)
                Tappable(
                  onTap: () {
                    context.read(currentViewProvider.notifier).state =
                        entry.view;
                    context.read(topMenuOverlayProvider.notifier).state = false;
                  },
                  child: _OverlayEntry(
                    entry: entry,
                    active: entry.view == activeView,
                  ),
                ),
              const SizedBox(height: 1),
              Row(
                children: [
                  Tappable(
                    onTap: () {
                      context.read(topMenuOverlayProvider.notifier).state =
                          false;
                      context.read(helpVisibleProvider.notifier).state = true;
                    },
                    child: const Text(
                      '[?] Help',
                      style: TextStyle(color: Color.fromRGB(120, 120, 140)),
                    ),
                  ),
                  const Text(
                    '   ',
                    style: TextStyle(color: Color.fromRGB(120, 120, 140)),
                  ),
                  Tappable(
                    onTap: () => shutdownWithTerminalRestore(),
                    child: const Text(
                      '[q] Quit',
                      style: TextStyle(color: Color.fromRGB(120, 120, 140)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverlayEntry extends StatelessComponent {
  final TopMenuEntry entry;
  final bool active;
  const _OverlayEntry({required this.entry, required this.active});

  @override
  Component build(BuildContext context) {
    return Text(
      active ? '[${entry.label}]' : ' ${entry.label}',
      style: TextStyle(
        color: active
            ? const Color.fromRGB(247, 147, 26)
            : const Color.fromRGB(180, 180, 200),
        fontWeight: active ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }
}
