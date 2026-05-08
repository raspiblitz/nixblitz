import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../dev_app.dart';

final _menuSelectionProvider = StateProvider<int>((ref) => 0);

class _DevMenuEntry {
  final String label;
  final String description;
  final DevView view;

  const _DevMenuEntry(this.label, this.description, this.view);
}

const _entries = [
  _DevMenuEntry(
    'Log Demo',
    'Scrollable log widget with multi-line entries',
    DevView.logDemo,
  ),
  _DevMenuEntry(
    'Password Input',
    'Masked password entry with confirmation + peek (Tab)',
    DevView.passwordInput,
  ),
  _DevMenuEntry(
    'Confirm Prompt',
    'Yes/No selection list with warning + details',
    DevView.confirmPrompt,
  ),
  _DevMenuEntry(
    'Select Popup',
    'Inline list picker (↑/↓ + Enter)',
    DevView.selectPopup,
  ),
  _DevMenuEntry(
    'Spinner',
    'Animated braille spinner (various colors + labels)',
    DevView.spinner,
  ),
  _DevMenuEntry(
    'Option Editors',
    'Bool / Select / Number / Text option display widgets',
    DevView.optionEditor,
  ),
  _DevMenuEntry(
    'Service Card',
    'Service status display with running/stopped/failed states',
    DevView.serviceCard,
  ),
  _DevMenuEntry(
    'Help Popup',
    'Modal overlay with keybinding reference',
    DevView.helpPopup,
  ),
  _DevMenuEntry(
    'Dashboard Layout',
    'Static preview of the dashboard tile grid with realistic '
        'content sizes — for iterating on tile spacing and alignment',
    DevView.dashboard,
  ),
  _DevMenuEntry(
    'Node Tile (header)',
    'NodeTile preview with hotkey-toggleable update / drift / pending / '
        'applied-age state. Use for iterating on the dashboard-header '
        'replacement — see how the tile renders for each state combo.',
    DevView.dashboardHeader,
  ),
  _DevMenuEntry(
    'Seed Reveal Flow',
    'First-boot LND seed disclosure: choice → display → confirm, '
        'with a fake mnemonic so it can be exercised without a real '
        'install.',
    DevView.seedReveal,
  ),
];

class DevMenuView extends StatelessComponent {
  const DevMenuView({super.key});

  @override
  Component build(BuildContext context) {
    final selection = context.watch(_menuSelectionProvider);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (selection < _entries.length - 1) {
              context.read(_menuSelectionProvider.notifier).state =
                  selection + 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (selection > 0) {
              context.read(_menuSelectionProvider.notifier).state =
                  selection - 1;
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            context.read(currentDevViewProvider.notifier).state =
                _entries[selection].view;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Dev menu key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Widget & View Demos',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            ...List.generate(_entries.length, (i) {
              final focused = i == selection;
              final prefix = focused ? '> ' : '  ';
              final color = focused
                  ? const Color.fromRGB(247, 147, 26)
                  : const Color.fromRGB(200, 200, 200);
              return Text(
                '$prefix${_entries[i].label}',
                style: TextStyle(color: color),
              );
            }),
            const SizedBox(height: 1),
            Text(
              _entries[selection].description,
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            Text(
              '[↑/↓] navigate  [Enter] open  [q] quit',
              style: const TextStyle(color: Color.fromRGB(120, 120, 140)),
            ),
          ],
        ),
      ),
    );
  }
}
