import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../widgets/scrollable_log.dart';
import '../../widgets/select_popup.dart';

enum _TailMode { picking, viewing }

final _tailModeProvider = StateProvider<_TailMode>((ref) => _TailMode.picking);
final _tailPickIndexProvider = StateProvider<int>((ref) => 0);
final _tailUnitProvider = StateProvider<String?>((ref) => null);
final _tailLinesProvider = StateProvider<List<String>>((ref) => []);

class TailLogView extends StatefulComponent {
  final VoidCallback onExit;
  const TailLogView({super.key, required this.onExit});

  @override
  State<TailLogView> createState() => _TailLogViewState();
}

class _TailLogViewState extends State<TailLogView> {
  void _loadUnit(String unit) {
    context.read(_tailUnitProvider.notifier).state = unit;
    context.read(_tailLinesProvider.notifier).state = ['Loading…'];
    context.read(_tailModeProvider.notifier).state = _TailMode.viewing;

    Future<void>(() async {
      try {
        final r = await runChecked('journalctl', [
          '-u',
          unit,
          '-n',
          '200',
          '--no-pager',
        ]);
        final out = r.stdout + r.stderr;
        context.read(_tailLinesProvider.notifier).state = out
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
      } catch (e, st) {
        LogService.error('journalctl failed', e, st);
        context.read(_tailLinesProvider.notifier).state = ['Error: $e'];
      }
    });
  }

  void _reset() {
    context.read(_tailModeProvider.notifier).state = _TailMode.picking;
    context.read(_tailPickIndexProvider.notifier).state = 0;
    context.read(_tailUnitProvider.notifier).state = null;
    context.read(_tailLinesProvider.notifier).state = [];
  }

  @override
  Component build(BuildContext context) {
    final mode = context.watch(_tailModeProvider);
    return switch (mode) {
      _TailMode.picking => _buildPicker(context),
      _TailMode.viewing => _buildViewer(context),
    };
  }

  Component _buildPicker(BuildContext context) {
    final selectedIndex = context.watch(_tailPickIndexProvider);
    final registry = context.watch(appManifestRegistryProvider);
    final units = registry.serviceIds();
    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tail a unit log',
            style: TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          SelectPopup(
            title: 'Pick a unit',
            options: units,
            selectedIndex: selectedIndex,
            onHighlight: (i) =>
                context.read(_tailPickIndexProvider.notifier).state = i,
            onConfirm: (i) => _loadUnit(units[i]),
            onCancel: () {
              _reset();
              component.onExit();
            },
          ),
        ],
      ),
    );
  }

  Component _buildViewer(BuildContext context) {
    final unit = context.watch(_tailUnitProvider) ?? '?';
    final lines = context.watch(_tailLinesProvider);

    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'journalctl -u $unit -n 200',
            style: const TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 1),
          Expanded(
            child: ScrollableLog(
              lines: lines,
              focused: true,
              onKeyEvent: (event) {
                if (event.logicalKey == LogicalKey.escape) {
                  _reset();
                  component.onExit();
                  return true;
                }
                if (event.logicalKey == LogicalKey.keyR) {
                  _loadUnit(unit);
                  return true;
                }
                return false;
              },
            ),
          ),
          const SizedBox(height: 1),
          const Text(
            '[↑/↓ j/k] scroll   [PgUp/PgDn] page   [r] refresh   [Esc] back',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ],
      ),
    );
  }
}
