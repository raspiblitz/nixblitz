import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../widgets/scrollable_log.dart';

const _kUnits = [
  'bitcoind',
  'lnd',
  'clightning',
  'redis',
  'blitz-api',
  'blitz-api-celery-worker',
  'blitz-api-celery-beat',
  'nginx',
];

final _healthLinesProvider = StateProvider<List<String>>((ref) => []);
final _healthLoadingProvider = StateProvider<bool>((ref) => true);

class ServiceHealthView extends StatefulComponent {
  final VoidCallback onExit;
  const ServiceHealthView({super.key, required this.onExit});

  @override
  State<ServiceHealthView> createState() => _ServiceHealthViewState();
}

class _ServiceHealthViewState extends State<ServiceHealthView> {
  bool _started = false;

  void _run() {
    if (_started) return;
    _started = true;
    context.read(_healthLoadingProvider.notifier).state = true;
    context.read(_healthLinesProvider.notifier).state = [];

    Future<void>(() async {
      final rows = <String>[];
      for (final unit in _kUnits) {
        String state;
        try {
          final r = await Process.run(
            'systemctl',
            ['is-active', unit],
            runInShell: false,
          );
          state = (r.stdout as String).trim();
          if (state.isEmpty) state = '(unknown)';
        } catch (e) {
          state = 'error: $e';
        }
        rows.add('${unit.padRight(28)} $state');
      }
      context.read(_healthLinesProvider.notifier).state = rows;
      context.read(_healthLoadingProvider.notifier).state = false;
      _started = false;
    });
  }

  @override
  Component build(BuildContext context) {
    if (!_started && context.read(_healthLinesProvider).isEmpty) {
      Future.microtask(_run);
    }

    final lines = context.watch(_healthLinesProvider);
    final loading = context.watch(_healthLoadingProvider);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            component.onExit();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyR) {
            _run();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Service health key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Service health',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            if (loading) const Text('Checking...'),
            Expanded(
              child: ScrollableLog(
                lines: lines,
                lineColor: _stateColor,
                focused: true,
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [/] search   [r] refresh   [Esc] back',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}

Color? _stateColor(String line) {
  if (line.endsWith(' active')) return const Color.fromRGB(110, 220, 110);
  if (line.endsWith(' inactive') || line.endsWith(' dead')) {
    return const Color.fromRGB(150, 150, 180);
  }
  if (line.contains(' failed') || line.contains(' error')) {
    return const Color.fromRGB(255, 120, 120);
  }
  if (line.endsWith(' activating') || line.endsWith(' reloading')) {
    return const Color.fromRGB(220, 180, 100);
  }
  return null;
}
