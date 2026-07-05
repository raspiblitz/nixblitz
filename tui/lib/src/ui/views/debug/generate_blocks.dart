import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../widgets/scrollable_log.dart';

/// Highest value any of the three numeric inputs can reach. One
/// million blocks is well past anyone's regtest patience but
/// safely under int32 — keeps the rendered text width sane and
/// guards against accidental key-mash overflow into multi-second
/// `runChecked` timeouts.
const _kInputMax = 999999;

enum _GbMode { configure, running, done }

enum _GbField { blocks, initialDelay, interval }

final _gbModeProvider = StateProvider<_GbMode>((ref) => _GbMode.configure);
final _gbFocusedField = StateProvider<_GbField>((ref) => _GbField.blocks);

/// Direct integer-valued inputs (replaced the preset-cycler).
/// Default to a single-block dry run with no waits — typing
/// digits appends, Backspace deletes one, Up/Down move between
/// fields. The values persist across view re-entries (the
/// providers live for the ProviderScope's lifetime), so a repeat
/// run remembers what the operator just typed.
final _gbBlocks = StateProvider<int>((ref) => 1);
final _gbDelay = StateProvider<int>((ref) => 0);
final _gbInterval = StateProvider<int>((ref) => 0);

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
      final listRes = await runChecked('bitcoin-cli', [
        '-regtest',
        'listwallets',
      ]);
      if (listRes.exitCode == 0 &&
          !listRes.stdout.contains('"nixblitz-debug"')) {
        _append('> bitcoin-cli -regtest loadwallet nixblitz-debug');
        final loadRes = await runChecked('bitcoin-cli', [
          '-regtest',
          'loadwallet',
          'nixblitz-debug',
        ]);
        if (loadRes.exitCode != 0) {
          _append('> bitcoin-cli -regtest createwallet nixblitz-debug');
          await runChecked('bitcoin-cli', [
            '-regtest',
            'createwallet',
            'nixblitz-debug',
          ]);
        }
      }

      _append('> bitcoin-cli -regtest -rpcwallet=nixblitz-debug getnewaddress');
      final addrRes = await runChecked('bitcoin-cli', [
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
      final addr = addrRes.stdout.trim();
      _append('Mining to: $addr');

      // Fast path: zero interval → one batch call.
      if (interval == 0) {
        _append('> bitcoin-cli -regtest generatetoaddress $blocks $addr');
        final res = await runChecked('bitcoin-cli', [
          '-regtest',
          'generatetoaddress',
          '$blocks',
          addr,
        ]);
        final hashes = res.stdout.trim();
        final err = res.stderr.trim();
        if (err.isNotEmpty) _append(err);
        if (hashes.isNotEmpty) _append(hashes);
        context.read(_gbExitCodeProvider.notifier).state = res.exitCode;
      } else {
        // Slow path: one block per loop, with interval between.
        for (var i = 1; i <= blocks && !_cancelRequested; i++) {
          _append('[$i/$blocks] generatetoaddress 1');
          final res = await runChecked('bitcoin-cli', [
            '-regtest',
            'generatetoaddress',
            '1',
            addr,
          ]);
          if (res.exitCode != 0) {
            _append('failed: ${res.stderr.trim()}');
            context.read(_gbExitCodeProvider.notifier).state = res.exitCode;
            context.read(_gbModeProvider.notifier).state = _GbMode.done;
            return;
          }
          final hash = res.stdout.trim().replaceAll(RegExp(r'[\[\]"]'), '');
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
    final blocks = context.watch(_gbBlocks);
    final delay = context.watch(_gbDelay);
    final interval = context.watch(_gbInterval);

    /// Returns the StateProvider backing whichever field is
    /// currently focused — used by the digit / Backspace
    /// handlers below to mutate the right value without three
    /// parallel switch arms.
    StateProvider<int> currentProvider() {
      return switch (focused) {
        _GbField.blocks => _gbBlocks,
        _GbField.initialDelay => _gbDelay,
        _GbField.interval => _gbInterval,
      };
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
          // Digit append: append the typed digit to the focused
          // field's value, capped at [_kInputMax]. j/k get
          // intercepted by the field-switch arm above so they
          // can't be typed into Blocks — that's fine, we don't
          // need 'jk' as digits.
          final ch = event.character;
          if (ch != null && ch.length == 1) {
            final code = ch.codeUnitAt(0);
            if (code >= 0x30 && code <= 0x39) {
              final p = currentProvider();
              final old = context.read(p);
              final next = old * 10 + (code - 0x30);
              context.read(p.notifier).state = next > _kInputMax
                  ? _kInputMax
                  : next;
              return true;
            }
          }
          // Backspace: trim one digit off the focused field.
          if (event.logicalKey == LogicalKey.backspace) {
            final p = currentProvider();
            context.read(p.notifier).state = context.read(p) ~/ 10;
            return true;
          }
          if (event.logicalKey == LogicalKey.keyG) {
            // Refuse to launch if blocks is zero — there's nothing
            // to mine, the rest of the run would be no-op + log
            // noise. The form keeps focus so the operator types a
            // value first.
            if (blocks == 0) return true;
            _run(blocks, delay, interval);
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
            _row('Blocks', '$blocks', focused == _GbField.blocks),
            _row(
              'Initial delay',
              '${delay}s',
              focused == _GbField.initialDelay,
            ),
            _row('Interval', '${interval}s', focused == _GbField.interval),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓] field   [0-9] type   [⌫] delete   [g] generate   [Esc] back',
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
