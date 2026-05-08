import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

import '../../ui/views/dashboard/node_tile.dart';
import '../dev_app.dart';

/// Synthetic state for the dashboard-header demo. Each provider holds
/// an index into a fixed cycle of values; the hotkey handler bumps
/// the index modulo the cycle length so we can step through the
/// states without typing values.
final _updatesIdxProvider = StateProvider<int>((ref) => 0);
final _configIdxProvider = StateProvider<int>((ref) => 0);
final _appliedIdxProvider = StateProvider<int>((ref) => 2);
final _uptimeIdxProvider = StateProvider<int>((ref) => 2);

/// Possible values for each dimension. `null` for `applied` represents
/// a fresh install with no Apply on record.
const _updatesCycle = <int>[0, 1, 3, 7];
const _configCycle = <int>[0, 1, 3, 5];
const _appliedCycle = <String?>[null, '30s ago', '2m ago', '3h ago', '2d ago'];
const _uptimeCycle = <int?>[null, 42, 7 * 60, 21 * 3600 + 7 * 60, 2 * 86400];

/// Names that show up in `system updates` (flake-input bumps —
/// nixpkgs, nix-bitcoin, plugins, etc.).
const _updateSourceCorpus = <String>[
  'nixpkgs',
  'nix-bitcoin',
  'blitz-api',
  'blitz-web',
  'disko',
  'nixos-raspberrypi',
  'nixblitz',
];

/// Names that show up in `config changes` (apps whose config the
/// operator edited via Configure).
const _configChangeCorpus = <String>[
  'bitcoind',
  'lnd',
  'cln',
  'blitz-api',
  'blitz-web',
];

class DashboardHeaderDemoView extends StatelessComponent {
  const DashboardHeaderDemoView({super.key});

  @override
  Component build(BuildContext context) {
    final updatesIdx = context.watch(_updatesIdxProvider);
    final configIdx = context.watch(_configIdxProvider);
    final appliedIdx = context.watch(_appliedIdxProvider);
    final uptimeIdx = context.watch(_uptimeIdxProvider);

    final updates = _updatesCycle[updatesIdx];
    final configChanges = _configCycle[configIdx];
    final applied = _appliedCycle[appliedIdx];
    final uptime = _uptimeCycle[uptimeIdx];
    final updateSources = _updateSourceCorpus.take(updates).toList();
    final configChangeNames = _configChangeCorpus.take(configChanges).toList();

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          final k = event.logicalKey;
          if (k == LogicalKey.escape) {
            context.read(currentDevViewProvider.notifier).state = DevView.menu;
            return true;
          }
          if (k == LogicalKey.keyU) {
            _cycle(context, _updatesIdxProvider, _updatesCycle.length);
            return true;
          }
          if (k == LogicalKey.keyC) {
            _cycle(context, _configIdxProvider, _configCycle.length);
            return true;
          }
          if (k == LogicalKey.keyT) {
            _cycle(context, _appliedIdxProvider, _appliedCycle.length);
            return true;
          }
          if (k == LogicalKey.keyY) {
            _cycle(context, _uptimeIdxProvider, _uptimeCycle.length);
            return true;
          }
          if (k == LogicalKey.keyR) {
            context.read(_updatesIdxProvider.notifier).state = 0;
            context.read(_configIdxProvider.notifier).state = 0;
            context.read(_appliedIdxProvider.notifier).state = 2;
            context.read(_uptimeIdxProvider.notifier).state = 2;
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Dashboard header demo key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Node tile preview',
              style: TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            // Constrained width: real dashboard tiles are ~40-50 cols
            // wide depending on the column count. Pin to 45 cols so
            // the preview doesn't sprawl across an 80+ col terminal.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 50),
              child: NodeTile(
                hostname: 'nixblitz',
                uptimeSec: uptime,
                appliedAgoText: applied,
                systemUpdatesCount: updates,
                systemUpdateSources: updateSources,
                configChangesCount: configChanges,
                configChangesNames: configChangeNames,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              'state — '
              'system updates: $updates  '
              'config changes: $configChanges  '
              'applied: ${applied ?? "—"}  '
              'uptime: ${uptime ?? "—"}',
              style: const TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            const Text(
              '[u] cycle system updates  [c] cycle config changes  '
              '[t] cycle applied-age  [y] cycle uptime',
              style: TextStyle(color: Color.fromRGB(120, 120, 140)),
            ),
            const Text(
              '[r] reset all  [Esc] back',
              style: TextStyle(color: Color.fromRGB(120, 120, 140)),
            ),
          ],
        ),
      ),
    );
  }

  void _cycle(BuildContext context, StateProvider<int> p, int len) {
    final cur = context.read(p);
    context.read(p.notifier).state = (cur + 1) % len;
  }
}
