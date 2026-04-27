import 'dart:async';
import 'dart:math';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../ui/widgets/scrollable_log.dart';
import '../../ui/widgets/spinner.dart';
import '../dev_app.dart';

final _demoLinesProvider = StateProvider<List<String>>((ref) => []);
final _demoRunningProvider = StateProvider<bool>((ref) => false);

const List<String> _fakeLines = [
  'building the system configuration...',
  'evaluating derivation \'/nix/store/abcd1234-nixos-25.11.drv\'',
  'copying path \'/nix/store/xyz9876-some-really-long-package-name-1.2.3\' from \'https://cache.nixos.org\'...',
  'unpacking source archive /build/download.tar.gz',
  '  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current\n                                 Dload  Upload   Total   Spent    Left  Speed\n100 1575  100 1575    0     0   5653      0 --:--:-- --:--:-- --:--:--  5653',
  '+ sgdisk --clear /dev/vda',
  '+ mkfs.ext4 -F /dev/disk/by-partlabel/disk-main-root',
  'Creating filesystem with 15728640 4k blocks and 3932160 inodes\nFilesystem UUID: abc-def-123\nSuperblock backups stored on blocks:\n\t32768, 98304, 163840',
  'error: some random error happened',
  'installing the boot loader...',
  'activating the configuration...',
  'reloading user units for admin...',
  'setting up tmpfiles',
  'done.',
];

class LogDemoView extends StatefulComponent {
  const LogDemoView({super.key});

  @override
  State<LogDemoView> createState() => _LogDemoViewState();
}

class _LogDemoViewState extends State<LogDemoView> {
  Timer? _emitter;
  final _rng = Random();

  @override
  void dispose() {
    _emitter?.cancel();
    super.dispose();
  }

  void _start() {
    if (context.read(_demoRunningProvider)) return;
    context.read(_demoRunningProvider.notifier).state = true;
    _emitter = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final line = _fakeLines[_rng.nextInt(_fakeLines.length)];
      final current = context.read(_demoLinesProvider);
      context.read(_demoLinesProvider.notifier).state = [...current, line];
    });
  }

  void _stop() {
    _emitter?.cancel();
    _emitter = null;
    context.read(_demoRunningProvider.notifier).state = false;
  }

  void _clear() {
    _stop();
    context.read(_demoLinesProvider.notifier).state = [];
  }

  @override
  Component build(BuildContext context) {
    final lines = context.watch(_demoLinesProvider);
    final running = context.watch(_demoRunningProvider);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyS) {
            running ? _stop() : _start();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyC) {
            _clear();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyA) {
            // Append a single random line
            final line = _fakeLines[_rng.nextInt(_fakeLines.length)];
            final current = context.read(_demoLinesProvider);
            context.read(_demoLinesProvider.notifier).state = [
              ...current,
              line,
            ];
            return true;
          }
          if (event.logicalKey == LogicalKey.keyM) {
            // Append a multi-line entry
            final current = context.read(_demoLinesProvider);
            context.read(_demoLinesProvider.notifier).state = [
              ...current,
              'multi-line entry:\n  first\n  second\n  third\n  fourth',
            ];
            return true;
          }
          if (event.logicalKey == LogicalKey.escape) {
            _stop();
            context.read(currentDevViewProvider.notifier).state = DevView.menu;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Log demo key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (running)
                  Spinner(label: 'Log Demo (emitting...)')
                else
                  Text(
                    'Log Demo (stopped)',
                    style: const TextStyle(
                      color: Color.fromRGB(247, 147, 26),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                Text(
                  '  ${lines.length} lines',
                  style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ],
            ),
            Text(
              '[s] start/stop  [a] add one  [m] add multi-line  [c] clear  '
              '[/] search  [Esc] back',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            // `focused: true` so j/k, PgUp/PgDn, and / search are wired
            // to the log itself. Keys the log doesn't consume bubble up
            // to the outer Focusable for s/a/m/c/Esc.
            Expanded(
              child: ScrollableLog(lines: lines, focused: true),
            ),
          ],
        ),
      ),
    );
  }
}
