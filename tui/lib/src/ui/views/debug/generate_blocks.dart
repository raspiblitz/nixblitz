import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../widgets/scrollable_log.dart';

const _kBlocksPresets = [1, 6, 100, 1000];
const _kDelayPresets = [0, 2, 5, 30];
const _kIntervalPresets = [0, 1, 5, 30];

enum _GbMode { configure, running, done }

enum _GbField { blocks, initialDelay, interval }

final _gbModeProvider = StateProvider<_GbMode>((ref) => _GbMode.configure);
final _gbFocusedField = StateProvider<_GbField>((ref) => _GbField.blocks);
final _gbBlocksIdx = StateProvider<int>((ref) => 0);
final _gbDelayIdx = StateProvider<int>((ref) => 0);
final _gbIntervalIdx = StateProvider<int>((ref) => 0);
final _gbOutputProvider = StateProvider<List<String>>((ref) => []);
final _gbExitCodeProvider = StateProvider<int?>((ref) => null);

class GenerateBlocksView extends StatefulComponent {
  final VoidCallback onExit;
  const GenerateBlocksView({super.key, required this.onExit});

  @override
  State<GenerateBlocksView> createState() => _GenerateBlocksViewState();
}

class _GenerateBlocksViewState extends State<GenerateBlocksView> {
  bool _cancelRequested = false;

  void _append(String line) {
    // Also write to ~/nixblitz.log so output is copy-pastable outside
    // the TUI.
    LogService.info('[gen-blocks] $line');
    final current = context.read(_gbOutputProvider);
    context.read(_gbOutputProvider.notifier).state = [...current, line];
  }

  void _reset() {
    _cancelRequested = false;
    context.read(_gbModeProvider.notifier).state = _GbMode.configure;
    context.read(_gbOutputProvider.notifier).state = [];
    context.read(_gbExitCodeProvider.notifier).state = null;
  }

  Future<void> _run(int blocks, int initialDelay, int interval) async {
    _cancelRequested = false;
    context.read(_gbModeProvider.notifier).state = _GbMode.running;
    context.read(_gbOutputProvider.notifier).state = [];
    context.read(_gbExitCodeProvider.notifier).state = null;

    try {
      // Initial delay — countdown in the log so the user sees we haven't hung.
      for (var s = initialDelay; s > 0 && !_cancelRequested; s--) {
        _append('Starting in ${s}s…');
        await Future.delayed(const Duration(seconds: 1));
      }
      if (_cancelRequested) {
        _append('Cancelled before start.');
        context.read(_gbExitCodeProvider.notifier).state = 1;
        context.read(_gbModeProvider.notifier).state = _GbMode.done;
        return;
      }

      // Bitcoin Core 0.21+ ships with no default wallet — ensure one
      // is loaded before any wallet-scoped RPC (getnewaddress etc.)
      // works.
      _append('> bitcoin-cli -regtest listwallets');
      final listRes = await Process.run('bitcoin-cli', [
        '-regtest',
        'listwallets',
      ]);
      if (listRes.exitCode == 0 &&
          !(listRes.stdout as String).contains('"nixblitz-debug"')) {
        _append('> bitcoin-cli -regtest loadwallet nixblitz-debug');
        final loadRes = await Process.run('bitcoin-cli', [
          '-regtest',
          'loadwallet',
          'nixblitz-debug',
        ]);
        if (loadRes.exitCode != 0) {
          _append('> bitcoin-cli -regtest createwallet nixblitz-debug');
          await Process.run('bitcoin-cli', [
            '-regtest',
            'createwallet',
            'nixblitz-debug',
          ]);
        }
      }

      _append('> bitcoin-cli -regtest -rpcwallet=nixblitz-debug getnewaddress');
      final addrRes = await Process.run('bitcoin-cli', [
        '-regtest',
        '-rpcwallet=nixblitz-debug',
        'getnewaddress',
      ]);
      if (addrRes.exitCode != 0) {
        _append('getnewaddress failed: ${addrRes.stderr}');
        context.read(_gbExitCodeProvider.notifier).state = addrRes.exitCode;
        context.read(_gbModeProvider.notifier).state = _GbMode.done;
        return;
      }
      final addr = (addrRes.stdout as String).trim();
      _append('Mining to: $addr');

      // Fast path: zero interval → one batch call.
      if (interval == 0) {
        _append('> bitcoin-cli -regtest generatetoaddress $blocks $addr');
        final res = await Process.run('bitcoin-cli', [
          '-regtest',
          'generatetoaddress',
          '$blocks',
          addr,
        ]);
        final hashes = (res.stdout as String).trim();
        final err = (res.stderr as String).trim();
        if (err.isNotEmpty) _append(err);
        if (hashes.isNotEmpty) _append(hashes);
        context.read(_gbExitCodeProvider.notifier).state = res.exitCode;
      } else {
        // Slow path: one block per loop, with interval between.
        for (var i = 1; i <= blocks && !_cancelRequested; i++) {
          _append('[$i/$blocks] generatetoaddress 1');
          final res = await Process.run('bitcoin-cli', [
            '-regtest',
            'generatetoaddress',
            '1',
            addr,
          ]);
          if (res.exitCode != 0) {
            _append('failed: ${(res.stderr as String).trim()}');
            context.read(_gbExitCodeProvider.notifier).state = res.exitCode;
            context.read(_gbModeProvider.notifier).state = _GbMode.done;
            return;
          }
          final hash = (res.stdout as String).trim().replaceAll(
            RegExp(r'[\[\]"]'),
            '',
          );
          _append('  $hash');
          if (i < blocks) {
            for (var s = interval; s > 0 && !_cancelRequested; s--) {
              await Future.delayed(const Duration(seconds: 1));
            }
          }
        }
        if (_cancelRequested) {
          _append('Cancelled mid-run.');
          context.read(_gbExitCodeProvider.notifier).state = 1;
        } else {
          context.read(_gbExitCodeProvider.notifier).state = 0;
        }
      }
      context.read(_gbModeProvider.notifier).state = _GbMode.done;
    } catch (e, st) {
      LogService.error('generate blocks failed', e, st);
      _append('Error: $e');
      context.read(_gbExitCodeProvider.notifier).state = 1;
      context.read(_gbModeProvider.notifier).state = _GbMode.done;
    }
  }

  @override
  Component build(BuildContext context) {
    final mode = context.watch(_gbModeProvider);
    return switch (mode) {
      _GbMode.configure => _buildConfigure(context),
      _GbMode.running => _buildRunning(context),
      _GbMode.done => _buildDone(context),
    };
  }

  Component _buildConfigure(BuildContext context) {
    final focused = context.watch(_gbFocusedField);
    final bIdx = context.watch(_gbBlocksIdx);
    final dIdx = context.watch(_gbDelayIdx);
    final iIdx = context.watch(_gbIntervalIdx);

    void cycle(int delta) {
      switch (focused) {
        case _GbField.blocks:
          final n = (bIdx + delta) % _kBlocksPresets.length;
          context.read(_gbBlocksIdx.notifier).state = n < 0
              ? n + _kBlocksPresets.length
              : n;
        case _GbField.initialDelay:
          final n = (dIdx + delta) % _kDelayPresets.length;
          context.read(_gbDelayIdx.notifier).state = n < 0
              ? n + _kDelayPresets.length
              : n;
        case _GbField.interval:
          final n = (iIdx + delta) % _kIntervalPresets.length;
          context.read(_gbIntervalIdx.notifier).state = n < 0
              ? n + _kIntervalPresets.length
              : n;
      }
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            _reset();
            component.onExit();
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowUp ||
              event.logicalKey == LogicalKey.keyK) {
            final n = _GbField.values.indexOf(focused);
            if (n > 0) {
              context.read(_gbFocusedField.notifier).state =
                  _GbField.values[n - 1];
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowDown ||
              event.logicalKey == LogicalKey.keyJ) {
            final n = _GbField.values.indexOf(focused);
            if (n < _GbField.values.length - 1) {
              context.read(_gbFocusedField.notifier).state =
                  _GbField.values[n + 1];
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowLeft) {
            cycle(-1);
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowRight) {
            cycle(1);
            return true;
          }
          if (event.logicalKey == LogicalKey.keyG) {
            _run(
              _kBlocksPresets[bIdx],
              _kDelayPresets[dIdx],
              _kIntervalPresets[iIdx],
            );
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Generate blocks key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Generate regtest blocks',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            _row(
              'Blocks',
              '${_kBlocksPresets[bIdx]}',
              focused == _GbField.blocks,
            ),
            _row(
              'Initial delay',
              '${_kDelayPresets[dIdx]}s',
              focused == _GbField.initialDelay,
            ),
            _row(
              'Interval',
              '${_kIntervalPresets[iIdx]}s',
              focused == _GbField.interval,
            ),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓] field   [←/→] value   [g] generate   [Esc] back',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _row(String label, String value, bool focused) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    return Text(
      '$prefix${label.padRight(18)} $value',
      style: TextStyle(color: color),
    );
  }

  Component _buildRunning(BuildContext context) {
    final lines = context.watch(_gbOutputProvider);
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape) {
          _cancelRequested = true;
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Generating blocks…',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: lines, focused: true)),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [/] search   [Esc] cancel',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildDone(BuildContext context) {
    final lines = context.watch(_gbOutputProvider);
    final exit = context.watch(_gbExitCodeProvider);
    final success = exit == 0;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter ||
            event.logicalKey == LogicalKey.escape) {
          _reset();
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              success ? 'Done' : 'Failed',
              style: TextStyle(
                color: success
                    ? const Color.fromRGB(110, 220, 110)
                    : const Color.fromRGB(255, 120, 120),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: ScrollableLog(
                lines: lines,
                focused: true,
                onKeyEvent: (event) {
                  if (event.logicalKey == LogicalKey.enter ||
                      event.logicalKey == LogicalKey.escape) {
                    _reset();
                    return true;
                  }
                  return false;
                },
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [Enter/Esc] new run',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}
