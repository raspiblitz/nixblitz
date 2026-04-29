import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:common/src/models/plugin/plugin_tile.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/plugin_dashboard_provider.dart';

/// Seed a fully-formed plugin under `$home/plugins/$dirName/` —
/// manifest with a dashboard block, plugin.nix stub, and an entry
/// in main config.json. The plugin's tile-state command echoes
/// fixed JSON so tests don't depend on real apps being installed.
void _seedPluginWithTileCommand(
  Directory home,
  String dirName, {
  required String tileCommand,
  Duration pollInterval = const Duration(seconds: 5),
}) {
  final dir = Directory('${home.path}/plugins/$dirName');
  dir.createSync(recursive: true);
  File('${dir.path}/plugin.nix').writeAsStringSync('{}\n');
  File('${dir.path}/manifest.json').writeAsStringSync(
    jsonEncode({
      'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': dirName},
      'dashboard': {
        'title': dirName,
        'command': tileCommand,
        'poll_interval_seconds': pollInterval.inSeconds,
        'timeout_seconds': 5,
      },
    }),
  );
  File('${dir.path}/config.json').writeAsStringSync('{}\n');
}

void _writeMainConfig(Directory home, List<String> pluginDirs) {
  // Hand-rolled main config; PluginEntry's required fields filled
  // with deterministic stand-ins (ts not the focus of these tests).
  final now = DateTime.parse('2026-01-01T00:00:00Z').toIso8601String();
  final config = {
    'version': 14,
    'min_compatible_version': 1,
    'initialized': false,
    'system': {'hostname': 'h', 'timezone': 'UTC', 'platform': 'x86'},
    'bitcoind': {
      'enabled': true,
      'network': 'mainnet',
      'pruned': true,
      'prune_size_gb': 550,
    },
    'lnd': {'enabled': false, 'alias': ''},
    'cln': {'enabled': false},
    'blitz_api': {'enabled': true},
    'blitz_web': {'enabled': true},
    'plugins': [
      for (final dir in pluginDirs)
        {
          'id': 'file://$dir',
          'url': 'file://$dir',
          'branch': 'main',
          'pinned_rev': 'a' * 40,
          'dir_name': dir,
          'installed_at': now,
          'last_updated_at': now,
          'enabled': true,
          'auto_update': true,
        },
    ],
  };
  File('${home.path}/config.json').writeAsStringSync(jsonEncode(config));
}

ProviderContainer _makeContainer(Directory home) {
  return ProviderContainer(
    overrides: [baseDirProvider.overrideWithValue(home.path)],
  );
}

Future<PluginTileSnapshot?> _waitForSnapshot(
  ProviderContainer container,
  String dirName, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final svc = container.read(pluginDashboardServiceProvider);
    final snap = svc.seed[dirName];
    if (snap != null) return snap;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return null;
}

void main() {
  group('PluginDashboardService', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('nixblitz_pds_');
    });

    tearDown(() => home.deleteSync(recursive: true));

    test('polls a plugin tile command and parses JSON output', () async {
      _seedPluginWithTileCommand(
        home,
        'demo',
        tileCommand:
            r'''echo '{"_status_label":"online","_status_color":"ok","tailnet":"home"}' ''',
      );
      _writeMainConfig(home, ['demo']);

      final container = _makeContainer(home);
      addTearDown(container.dispose);

      final svc = container.read(pluginDashboardServiceProvider);
      addTearDown(svc.dispose);

      final snap = await _waitForSnapshot(container, 'demo');
      expect(snap, isNotNull);
      expect(snap!.title, 'demo');
      expect(snap.statusLabel, 'online');
      expect(snap.statusColor, PluginTileStatus.ok);
      expect(snap.rows.map((r) => r.label).toList(), ['tailnet']);
      expect(snap.rows.first.value, 'home');
      expect(snap.footer, isNull);
    });

    test('non-zero exit produces failure snapshot with stderr tail', () async {
      _seedPluginWithTileCommand(
        home,
        'demo',
        tileCommand: r'echo "bad thing happened" 1>&2; exit 7',
      );
      _writeMainConfig(home, ['demo']);

      final container = _makeContainer(home);
      addTearDown(container.dispose);
      final svc = container.read(pluginDashboardServiceProvider);
      addTearDown(svc.dispose);

      final snap = await _waitForSnapshot(container, 'demo');
      expect(snap, isNotNull);
      expect(snap!.footer, contains('exit 7'));
      expect(snap.footer, contains('bad thing happened'));
      expect(snap.footerColor, PluginTileStatus.error);
    });

    test(
      'exit 127 (command-not-found) renders as a yellow pending tile',
      () async {
        // Regression: before the fix, a freshly-installed plugin
        // whose tile-state script wasn't on PATH yet (because the
        // operator hadn't run Apply) rendered as a red runtime
        // error. The right shape is a soft "pending" tile pointing
        // them at Apply.
        //
        // Use the literal exit-127 from `bash -c <missing>` rather
        // than spelling it out so the test mirrors what bash itself
        // produces when a script is missing from PATH.
        _seedPluginWithTileCommand(
          home,
          'demo',
          tileCommand: 'definitely-not-a-real-binary-aiyf',
        );
        _writeMainConfig(home, ['demo']);

        final container = _makeContainer(home);
        addTearDown(container.dispose);
        final svc = container.read(pluginDashboardServiceProvider);
        addTearDown(svc.dispose);

        final snap = await _waitForSnapshot(container, 'demo');
        expect(snap, isNotNull);
        expect(snap!.statusLabel, 'pending');
        expect(snap.statusColor, PluginTileStatus.warn);
        expect(snap.footerColor, PluginTileStatus.warn);
        expect(snap.footer, contains('awaiting Apply'));
        expect(snap.footer, contains('definitely-not-a-real-binary-aiyf'));
      },
    );

    test('invalid JSON output produces failure snapshot', () async {
      _seedPluginWithTileCommand(home, 'demo', tileCommand: r'echo "not json"');
      _writeMainConfig(home, ['demo']);

      final container = _makeContainer(home);
      addTearDown(container.dispose);
      final svc = container.read(pluginDashboardServiceProvider);
      addTearDown(svc.dispose);

      final snap = await _waitForSnapshot(container, 'demo');
      expect(snap, isNotNull);
      expect(snap!.footer, contains('invalid JSON'));
      expect(snap.footerColor, PluginTileStatus.error);
    });

    test('skips plugins without a dashboard block', () async {
      // Create a plugin WITHOUT a dashboard block; service should
      // not poll it. We use a separate minimal seed since
      // _seedPluginWithTileCommand always adds a dashboard.
      Directory('${home.path}/plugins/headless').createSync(recursive: true);
      File(
        '${home.path}/plugins/headless/plugin.nix',
      ).writeAsStringSync('{}\n');
      File('${home.path}/plugins/headless/manifest.json').writeAsStringSync(
        jsonEncode({
          'manifest': {
            'schema_version': 2,
            'min_tui_version': 1,
            'name': 'headless',
          },
        }),
      );
      File(
        '${home.path}/plugins/headless/config.json',
      ).writeAsStringSync('{}\n');
      _writeMainConfig(home, ['headless']);

      final container = _makeContainer(home);
      addTearDown(container.dispose);
      final svc = container.read(pluginDashboardServiceProvider);
      addTearDown(svc.dispose);

      // Wait briefly to ensure no poller would have run.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(svc.seed.containsKey('headless'), isFalse);
    });
  });
}
