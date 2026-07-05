import 'dart:async';

import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';

import '../../widgets/scrollable_log.dart';

/// Name of the transient systemd unit we create via
/// `systemd-run`. Single hard-coded name (rather than per-launch
/// generated) so the menu can find + stop the running miner on
/// re-entry, and so re-entering after a crash recovers
/// gracefully.
const String _kUnitName = 'nixblitz-regtest-automine.service';

/// Same wallet that `generate_blocks.dart` ensures-and-uses for
/// one-shot mining. Sharing it means the operator's regtest
/// balance accumulates in one place regardless of which menu
/// did the mining.
const String _kDebugWallet = 'nixblitz-debug';

/// How often the view re-checks unit status while open. Cheap —
/// `systemctl is-active` is sub-ms — and gives the operator a
/// near-real-time view that the miner is alive.
const _kStatusPollInterval = Duration(seconds: 2);

enum _Mode { configure, running }

final _modeProvider = StateProvider<_Mode>((ref) => _Mode.configure);
final _focusedFieldProvider = StateProvider<_Field>((ref) => _Field.minSeconds);
final _minSecondsProvider = StateProvider<int>((ref) => 5);
final _maxSecondsProvider = StateProvider<int>((ref) => 30);

/// Live status of the systemd unit, polled by [_StatusPoller].
/// `null` means "haven't checked yet"; we render a spinner-ish
/// placeholder until the first probe lands.
final _unitActiveProvider = StateProvider<bool?>((ref) => null);

/// Most recent journalctl tail for the unit. Refreshed alongside
/// the status probe; rendered in a ScrollableLog when the unit
/// is active so the operator can see what the loop just did.
final _unitLogsProvider = StateProvider<List<String>>((ref) => const []);

enum _Field { minSeconds, maxSeconds }

const int _kInputMax = 86400; // one day per interval; way past sane

class RegtestAutomineView extends StatefulComponent {
  final VoidCallback onExit;
  const RegtestAutomineView({super.key, required this.onExit});

  @override
  State<RegtestAutomineView> createState() => _RegtestAutomineViewState();
}

class _RegtestAutomineViewState extends State<RegtestAutomineView> {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // First probe immediately so the view doesn't sit on
    // "checking…" for two seconds. Subsequent polls happen on
    // the timer.
    Future.microtask(_probeStatus);
    _pollTimer = Timer.periodic(_kStatusPollInterval, (_) => _probeStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _probeStatus() async {
    try {
      // is-active returns 0 / "active" when the unit is up,
      // non-zero / "inactive" / "failed" otherwise. Plain
      // `systemctl` (no sudo) is enough for read-only queries.
      final res = await runChecked('systemctl', ['is-active', _kUnitName]);
      final active = res.exitCode == 0;
      if (!mounted) return;
      context.read(_unitActiveProvider.notifier).state = active;
      if (active) {
        // Tail the journal so the running view shows what the
        // loop just did. `--no-pager` is essential — without it
        // journalctl detects no tty and would page anyway.
        final logRes = await runChecked('journalctl', [
          '-u',
          _kUnitName,
          '-n',
          '40',
          '--no-pager',
          '--output=cat',
        ]);
        if (!mounted) return;
        final lines = logRes.stdout
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList(growable: false);
        context.read(_unitLogsProvider.notifier).state = lines;
        context.read(_modeProvider.notifier).state = _Mode.running;
      } else {
        context.read(_modeProvider.notifier).state = _Mode.configure;
        context.read(_unitLogsProvider.notifier).state = const [];
      }
    } catch (e, st) {
      LogService.warn('regtest-automine status probe failed: $e');
      LogService.error('regtest-automine probe trace', e, st);
    }
  }

  /// Writes the loop body to a stable path under `/tmp` and
  /// returns the path. Lives at a deterministic name so
  /// repeated start cycles overwrite cleanly; harmless leftover
  /// after stop. See the comment in [_start] for why we use a
  /// file rather than `/bin/sh -c '<inline>'`.
  String _writeLoopScript(int minS, int maxS) {
    final range = maxS - minS + 1;
    const scriptPath = '/tmp/nixblitz-regtest-automine.sh';
    final script =
        '''
#!/run/current-system/sw/bin/bash
set -u

WALLET=$_kDebugWallet
BCC=/run/current-system/sw/bin/bitcoin-cli
SLEEP=/run/current-system/sw/bin/sleep

# Best-effort wallet bring-up. Errors silenced — the loop's
# generatetoaddress below surfaces anything that actually
# blocks mining. loadwallet returns -35 ("already loaded")
# silently; createwallet returns -4 ("already exists") when
# the wallet is on disk but isn't loaded — both are fine for
# our purposes, we just need ONE of them to win.
"\$BCC" -regtest loadwallet "\$WALLET" >/dev/null 2>&1 || true
"\$BCC" -regtest createwallet "\$WALLET" >/dev/null 2>&1 || true

while true; do
  s=\$(( RANDOM % $range + $minS ))
  echo "sleep \${s}s, then mine 1"
  "\$SLEEP" "\$s"
  addr=\$("\$BCC" -regtest -rpcwallet="\$WALLET" getnewaddress 2>&1) || {
    echo "getnewaddress failed: \$addr"
    continue
  }
  "\$BCC" -regtest -rpcwallet="\$WALLET" generatetoaddress 1 "\$addr" \\
      >/dev/null 2>&1 || echo "generatetoaddress failed for \$addr"
done
''';
    writeExecutableScriptSync(scriptPath, script);
    return scriptPath;
  }

  Future<void> _start(BuildContext context, int minS, int maxS) async {
    if (minS > maxS) {
      // UI should already prevent this (we clamp on input), but
      // defensive — refuse the launch rather than spawn an unit
      // that loops sleep'ing on garbage.
      LogService.warn(
        'regtest-automine: refusing launch with min=$minS > max=$maxS',
      );
      return;
    }

    // Loop body lives on disk at a stable path. Two things kill
    // the older `/bin/sh -c '<inline>'` form:
    //
    // - **systemd-run does its own `$VAR` expansion** on
    //   `ExecStart` arguments before handing them to the exec.
    //   Our `$s` / `${s}` shell variables got eaten —
    //   "Referenced but unset environment variable evaluates
    //   to an empty string: s" in the journal. File-based
    //   execution side-steps this entirely; systemd never
    //   reads the file content.
    // - **Empty PATH** in transient units means bare names
    //   like `grep`, `sleep`, `bitcoin-cli` all resolve as
    //   "command not found". File contents use absolute paths
    //   into `/run/current-system/sw/bin/…` so PATH is
    //   irrelevant.
    //
    // bash on the shebang (not sh) — dash doesn't expose
    // `$RANDOM` and we rely on it for the interval jitter.
    //
    // `set -u` only — drop `set -e` on purpose. A transient
    // bitcoin-cli failure shouldn't kill the loop; the
    // operator wants persistence. Failed mine → log, next
    // interval retries.
    final scriptPath = _writeLoopScript(minS, maxS);

    final session = context.read(sudoSessionProvider);
    final ok = await session.ensureFresh();
    if (!ok) {
      LogService.warn(
        'regtest-automine: sudo authorization cancelled; not starting',
      );
      return;
    }
    // `--collect` so the unit auto-removes when it exits or is
    // stopped — keeps `systemctl list-units` clean across
    // multiple start/stop cycles in one session.
    //
    // `--service-type=simple` because our exec runs forever; we
    // don't want systemd waiting for a "ready" signal.
    final res = await session.runOneShot([
      'systemd-run',
      '--collect',
      '--service-type=simple',
      '--unit=$_kUnitName',
      '--description=NixBlitz regtest auto-miner (debug)',
      scriptPath,
    ]);
    if (res.exitCode != 0) {
      LogService.warn(
        'regtest-automine: systemd-run failed: '
        'exit=${res.exitCode} stderr=${res.stderr.trim()}',
      );
      return;
    }
    LogService.info(
      'regtest-automine: started unit $_kUnitName (min=${minS}s max=${maxS}s)',
    );
    // Probe immediately so the view flips to running mode
    // without waiting for the next periodic tick.
    await _probeStatus();
  }

  Future<void> _stop(BuildContext context) async {
    final session = context.read(sudoSessionProvider);
    final ok = await session.ensureFresh();
    if (!ok) {
      LogService.warn(
        'regtest-automine: sudo authorization cancelled; not stopping',
      );
      return;
    }
    final res = await session.runOneShot(['systemctl', 'stop', _kUnitName]);
    if (res.exitCode != 0) {
      LogService.warn(
        'regtest-automine: systemctl stop failed: '
        'exit=${res.exitCode} stderr=${res.stderr.trim()}',
      );
    } else {
      LogService.info('regtest-automine: stopped unit $_kUnitName');
    }
    await _probeStatus();
  }

  @override
  Component build(BuildContext context) {
    final mode = context.watch(_modeProvider);
    final active = context.watch(_unitActiveProvider);

    if (active == null) {
      return const Padding(
        padding: EdgeInsets.all(2),
        child: Text(
          'Checking auto-miner status…',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      );
    }

    return switch (mode) {
      _Mode.configure => _buildConfigure(context),
      _Mode.running => _buildRunning(context),
    };
  }

  Component _buildConfigure(BuildContext context) {
    final focused = context.watch(_focusedFieldProvider);
    final minS = context.watch(_minSecondsProvider);
    final maxS = context.watch(_maxSecondsProvider);

    StateProvider<int> currentProvider() {
      return switch (focused) {
        _Field.minSeconds => _minSecondsProvider,
        _Field.maxSeconds => _maxSecondsProvider,
      };
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            component.onExit();
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowUp ||
              event.logicalKey == LogicalKey.keyK) {
            final n = _Field.values.indexOf(focused);
            if (n > 0) {
              context.read(_focusedFieldProvider.notifier).state =
                  _Field.values[n - 1];
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowDown ||
              event.logicalKey == LogicalKey.keyJ) {
            final n = _Field.values.indexOf(focused);
            if (n < _Field.values.length - 1) {
              context.read(_focusedFieldProvider.notifier).state =
                  _Field.values[n + 1];
            }
            return true;
          }
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
          if (event.logicalKey == LogicalKey.backspace) {
            final p = currentProvider();
            context.read(p.notifier).state = context.read(p) ~/ 10;
            return true;
          }
          if (event.logicalKey == LogicalKey.keyS) {
            // Block start until min ≤ max. UI doesn't auto-clamp
            // because that would surprise the operator typing
            // values; show "min > max" as a soft error instead
            // (just refuse to start).
            if (minS > maxS) return true;
            if (minS == 0 && maxS == 0) return true;
            unawaited(_start(context, minS, maxS));
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('regtest-automine configure key handler', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Regtest auto-miner',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              'Mines one block at a random interval, in a transient',
              style: TextStyle(color: Color.fromRGB(180, 180, 200)),
            ),
            const Text(
              'systemd unit. Survives TUI exit. Stops on reboot.',
              style: TextStyle(color: Color.fromRGB(180, 180, 200)),
            ),
            const SizedBox(height: 1),
            _row('Min interval', '${minS}s', focused == _Field.minSeconds),
            _row('Max interval', '${maxS}s', focused == _Field.maxSeconds),
            const SizedBox(height: 1),
            if (minS > maxS)
              Text(
                '! min > max — adjust before starting',
                style: const TextStyle(color: Color.fromRGB(255, 200, 80)),
              ),
            if (minS == 0 && maxS == 0)
              Text(
                '! both zero — picks a non-zero interval first',
                style: const TextStyle(color: Color.fromRGB(255, 200, 80)),
              ),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓] field   [0-9] type   [⌫] delete   [s] start   [Esc] back',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _buildRunning(BuildContext context) {
    final logs = context.watch(_unitLogsProvider);
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            component.onExit();
            return true;
          }
          if (event.character?.toUpperCase() == 'S') {
            unawaited(_stop(context));
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('regtest-automine running key handler', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Text(
                  'Regtest auto-miner ',
                  style: TextStyle(
                    color: Color.fromRGB(247, 147, 26),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '[running]',
                  style: TextStyle(
                    color: Color.fromRGB(110, 220, 110),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 1),
            const Text(
              'Unit: $_kUnitName',
              style: TextStyle(color: Color.fromRGB(180, 180, 200)),
            ),
            const Text(
              'Logs from journalctl (refreshing every 2s):',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: logs, focused: true)),
            const SizedBox(height: 1),
            const Text(
              '[↑/↓ j/k] scroll   [/] search   [S] stop   [Esc] back',
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
}
