import 'dart:async';
import 'dart:convert';
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';
import '../../widgets/scrollable_log.dart';

// ─── Shared helpers ───────────────────────────────────────────────

/// Result of a single shell step: the rendered log lines (including
/// the command echo and stdout/stderr), and the raw stdout for chains
/// that need to parse it (pubkeys, addresses, invoices…).
class _StepResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  const _StepResult(this.exitCode, this.stdout, this.stderr);
  bool get ok => exitCode == 0;
}

/// Runs one command and appends prettified output to [append]. Returns
/// the raw result so callers can thread stdout into the next step.
Future<_StepResult> _step({
  required void Function(String) append,
  required String bin,
  required List<String> args,
  String? label,
}) async {
  final printed = '${label ?? "\$"} $bin ${args.join(' ')}';
  append('> $printed');
  try {
    final r = await runChecked(bin, args);
    final so = r.stdout.trim();
    final se = r.stderr.trim();
    if (so.isNotEmpty) {
      for (final l in so.split('\n')) {
        append('  $l');
      }
    }
    if (se.isNotEmpty) {
      for (final l in se.split('\n')) {
        append('  ! $l');
      }
    }
    if (r.exitCode != 0) {
      append('  (exit ${r.exitCode})');
    }
    return _StepResult(r.exitCode, so, se);
  } catch (e, st) {
    LogService.error('Test LN step failed: $printed', e, st);
    append('  error: $e');
    return _StepResult(1, '', '$e');
  }
}

/// Name of the wallet we create for funding the LN nodes. Separate
/// from whatever manual wallet the user may have around so our debug
/// actions don't depend on or mutate it.
const String _kDebugWallet = 'nixblitz-debug';

/// Shortcut for `bitcoin-cli -regtest <args>`.
Future<_StepResult> _btc(void Function(String) append, List<String> args) =>
    _step(append: append, bin: 'bitcoin-cli', args: ['-regtest', ...args]);

/// Wallet-scoped bitcoin-cli call (needs `-rpcwallet=<name>` for RPCs
/// like getnewaddress / sendtoaddress / getbalance ever since core
/// 0.21 stopped auto-creating a default wallet).
Future<_StepResult> _btcw(void Function(String) append, List<String> args) =>
    _step(
      append: append,
      bin: 'bitcoin-cli',
      args: ['-regtest', '-rpcwallet=$_kDebugWallet', ...args],
    );

/// Make sure the debug wallet exists and is loaded. Idempotent:
/// - already loaded → no-op
/// - not loaded but on disk → loadwallet
/// - not on disk → createwallet
Future<_StepResult> _ensureWallet(void Function(String) append) async {
  final listed = await _btc(append, ['listwallets']);
  if (!listed.ok) return listed;
  if (listed.stdout.contains('"$_kDebugWallet"')) return listed;

  final loaded = await _btc(append, ['loadwallet', _kDebugWallet]);
  if (loaded.ok) return loaded;

  // -18 = wallet file missing — create it.
  return _btc(append, ['createwallet', _kDebugWallet]);
}

Future<_StepResult> _lncli(void Function(String) append, List<String> args) =>
    _step(append: append, bin: 'lncli', args: args);

Future<_StepResult> _lncliTest(
  void Function(String) append,
  List<String> args,
) => _step(append: append, bin: 'lncli-test', args: args);

/// Extract a JSON field from the stdout of a `-cli` command.
String? _jsonField(String stdout, String key) {
  try {
    final obj = jsonDecode(stdout);
    if (obj is Map && obj[key] != null) return obj[key].toString();
  } catch (_) {}
  return null;
}

/// Shared container for each action — streams [_log] into a
/// ScrollableLog with color-coded lines, [Esc] to return to the
/// Debug menu.
class _TestLnShell extends StatefulComponent {
  final VoidCallback onExit;
  final String title;
  final Future<void> Function(void Function(String) append) runner;

  const _TestLnShell({
    required this.onExit,
    required this.title,
    required this.runner,
  });

  @override
  State<_TestLnShell> createState() => _TestLnShellState();
}

class _TestLnShellState extends State<_TestLnShell> {
  final List<String> _log = [];
  bool _started = false;
  bool _done = false;

  void _append(String line) {
    // Mirror to the main log file so the output is copy-pastable
    // outside the TUI. Prefix so it's easy to grep.
    LogService.info('[test-ln] $line');
    setState(() => _log.add(line));
  }

  void _run() {
    if (_started) return;
    _started = true;
    Future<void>(() async {
      try {
        await component.runner(_append);
      } catch (e, st) {
        LogService.error('Test LN runner crashed', e, st);
        _append('! $e');
      } finally {
        setState(() => _done = true);
      }
    });
  }

  @override
  Component build(BuildContext context) {
    if (!_started) Future.microtask(_run);

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape) {
          component.onExit();
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
              component.title,
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: ScrollableLog(
                lines: _log,
                focused: true,
                onKeyEvent: (event) {
                  if (event.logicalKey == LogicalKey.escape) {
                    component.onExit();
                    return true;
                  }
                  return false;
                },
                lineColor: _colorize,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              _done
                  ? '[↑/↓ j/k] scroll   [Esc] back to Debug menu'
                  : 'Working…   [Esc] cancel',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }
}

Color? _colorize(String line) {
  if (line.startsWith('> ')) return const Color.fromRGB(120, 200, 220);
  if (line.startsWith('  ! ') || line.startsWith('! ')) {
    return const Color.fromRGB(255, 120, 120);
  }
  if (line.startsWith('  (exit ')) return const Color.fromRGB(255, 120, 120);
  return null;
}

// ─── Status ──────────────────────────────────────────────────────

class TestLnStatusView extends StatelessComponent {
  final VoidCallback onExit;
  const TestLnStatusView({super.key, required this.onExit});

  @override
  Component build(BuildContext context) {
    return _TestLnShell(
      onExit: onExit,
      title: 'Test LN: status',
      runner: (append) async {
        append('── primary LND ──');
        final info1 = await _lncli(append, ['getinfo']);
        if (info1.ok) {
          final pk = _jsonField(info1.stdout, 'identity_pubkey') ?? '?';
          append('');
          append('primary pubkey: $pk');
        }
        await _lncli(append, ['walletbalance']);

        append('');
        append('── test LND ──');
        final info2 = await _lncliTest(append, ['getinfo']);
        if (info2.ok) {
          final pk = _jsonField(info2.stdout, 'identity_pubkey') ?? '?';
          append('');
          append('test pubkey: $pk');
        }
        await _lncliTest(append, ['walletbalance']);
      },
    );
  }
}

// ─── Fund wallets ────────────────────────────────────────────────

class TestLnFundView extends StatelessComponent {
  final VoidCallback onExit;
  const TestLnFundView({super.key, required this.onExit});

  @override
  Component build(BuildContext context) {
    return _TestLnShell(
      onExit: onExit,
      title: 'Test LN: fund wallets',
      runner: (append) async {
        // Pre-flight: bitcoin core 0.21+ ships no default wallet, so
        // we need to explicitly create/load one before any
        // wallet-scoped RPC works.
        append('── ensuring debug wallet ──');
        final w = await _ensureWallet(append);
        if (!w.ok) {
          append('! could not create/load the debug wallet');
          return;
        }

        // Chain height. If < 101, coinbase isn't mature enough to spend.
        append('');
        final height = await _btc(append, ['getblockcount']);
        final h = int.tryParse(height.stdout.trim()) ?? 0;
        append('');
        append('chain height: $h');

        if (h < 101) {
          append('');
          append('Mining 101 blocks to a fresh address so coinbase matures…');
          final addr = await _btcw(append, ['getnewaddress']);
          if (!addr.ok) {
            append('! could not get a bitcoind address');
            return;
          }
          await _btc(append, ['generatetoaddress', '101', addr.stdout.trim()]);
        }

        // Fund primary LND.
        append('');
        append('── primary LND on-chain funding ──');
        final lndAddr = await _lncli(append, ['newaddress', 'p2wkh']);
        final lndAddress = _jsonField(lndAddr.stdout, 'address');
        if (lndAddress == null) {
          append('! could not parse lncli newaddress');
          return;
        }
        await _btcw(append, ['sendtoaddress', lndAddress, '1']);

        // Fund test LND.
        append('');
        append('── test LND on-chain funding ──');
        final testAddr = await _lncliTest(append, ['newaddress', 'p2wkh']);
        final testAddress = _jsonField(testAddr.stdout, 'address');
        if (testAddress == null) {
          append('! could not parse lncli-test newaddress');
          return;
        }
        await _btcw(append, ['sendtoaddress', testAddress, '1']);

        // Confirm both transfers.
        append('');
        append('Mining 6 blocks to confirm…');
        final confAddr = await _btcw(append, ['getnewaddress']);
        await _btc(append, ['generatetoaddress', '6', confAddr.stdout.trim()]);

        // Final balances.
        append('');
        append('── final balances ──');
        await _lncli(append, ['walletbalance']);
        await _lncliTest(append, ['walletbalance']);
      },
    );
  }
}

// ─── Open channel primary → test ─────────────────────────────────

class TestLnChannelView extends StatelessComponent {
  final VoidCallback onExit;
  const TestLnChannelView({super.key, required this.onExit});

  @override
  Component build(BuildContext context) {
    return _TestLnShell(
      onExit: onExit,
      title: 'Test LN: open channel (primary → test)',
      runner: (append) async {
        // 1. Precondition: primary must have > channel capacity on-chain.
        const capacitySat = 1000000;
        final bal = await _lncli(append, ['walletbalance']);
        final confirmed =
            int.tryParse(_jsonField(bal.stdout, 'confirmed_balance') ?? '') ??
            0;
        append('');
        append('primary confirmed balance: $confirmed sat');
        if (confirmed < capacitySat) {
          append('');
          append(
            '! insufficient funds — need at least $capacitySat sat. '
            "Run 'Test LN: fund wallets' first.",
          );
          return;
        }

        // 2. Get test LND pubkey.
        final info = await _lncliTest(append, ['getinfo']);
        final testPubkey = _jsonField(info.stdout, 'identity_pubkey');
        if (testPubkey == null) {
          append('! could not fetch test LND pubkey');
          return;
        }
        append('');
        append('test pubkey: $testPubkey');

        // 3. Connect (idempotent — ignore "already connected" errors).
        append('');
        final connect = await _lncli(append, [
          'connect',
          '$testPubkey@127.0.0.1:9736',
        ]);
        if (!connect.ok && !connect.stderr.contains('already connected')) {
          append('! connect failed');
          return;
        }

        // 4. Open channel.
        append('');
        final open = await _lncli(append, [
          'openchannel',
          testPubkey,
          '$capacitySat',
          // push some sats to the test side so it can send back too.
          '100000',
        ]);
        if (!open.ok) {
          append('! openchannel failed');
          return;
        }

        // 5. Mine 6 confirmations.
        append('');
        append('Mining 6 blocks to confirm the channel…');
        final w = await _ensureWallet(append);
        if (!w.ok) {
          append('! could not create/load the debug wallet');
          return;
        }
        final confAddr = await _btcw(append, ['getnewaddress']);
        await _btc(append, ['generatetoaddress', '6', confAddr.stdout.trim()]);

        // 6. Show the channel.
        append('');
        await _lncli(append, ['listchannels']);
      },
    );
  }
}

// ─── Pay self-invoice ───────────────────────────────────────────

class TestLnPayView extends StatelessComponent {
  final VoidCallback onExit;
  const TestLnPayView({super.key, required this.onExit});

  @override
  Component build(BuildContext context) {
    return _TestLnShell(
      onExit: onExit,
      title: 'Test LN: pay self-invoice',
      runner: (append) async {
        // Pre-check: at least one active channel.
        final channels = await _lncli(append, ['listchannels']);
        if (!channels.ok) {
          append('! could not query primary channels');
          return;
        }
        final hasChannel =
            channels.stdout.contains('"active": true') ||
            channels.stdout.contains('"active":true');
        if (!hasChannel) {
          append('');
          append("! no active channels — run 'Test LN: open channel' first.");
          return;
        }

        // 1. Test node generates an invoice.
        append('');
        final invoiceRes = await _lncliTest(append, [
          'addinvoice',
          '--amt',
          '1000',
          '--memo',
          'debug self-pay',
        ]);
        final invoice = _jsonField(invoiceRes.stdout, 'payment_request');
        if (invoice == null) {
          append('! could not extract payment_request');
          return;
        }
        append('');
        append('invoice: $invoice');

        // 2. Primary pays it (force, no prompt).
        append('');
        await _lncli(append, ['payinvoice', '-f', invoice]);

        // 3. Show updated balances.
        append('');
        append('── post-payment balances ──');
        await _lncli(append, ['channelbalance']);
        await _lncliTest(append, ['channelbalance']);
      },
    );
  }
}
