import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:common/src/models/plugin/plugin_tile.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/plugin_dashboard_provider.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';

/// Seed a fully-formed plugin under `$home/plugins/$id/` — manifest
/// with a dashboard block, plugin.nix stub, and the required
/// `.nixblitz-installed.json` marker. The plugin's tile-state command
/// echoes fixed JSON so tests don't depend on real apps being
/// installed.
void _seedPluginWithTileCommand(
  Directory home,
  String id, {
  required String tileCommand,
  Duration pollInterval = const Duration(seconds: 5),
  bool disabled = false,
}) {
  final dir = Directory('${home.path}/plugins/$id');
  dir.createSync(recursive: true);
  File('${dir.path}/plugin.nix').writeAsStringSync('{}\n');
  File('${dir.path}/plugin.json').writeAsStringSync(
    jsonEncode({
      'manifest': {'schema_version': 2, 'min_tui_version': 2, 'name': id},
      'id': id,
      'dashboard': {
        'title': id,
        'command': tileCommand,
        'poll_interval_seconds': pollInterval.inSeconds,
        'timeout_seconds': 5,
      },
    }),
  );
  writeMarker(
    dir.path,
    PluginMarker(
      id: id,
      url: 'file://${dir.path}',
      version: '0.1.0',
      rev: 'a' * 40,
      installedAt: DateTime.utc(2026, 1, 1),
      disabled: disabled,
    ),
  );
}

ProviderContainer _makeContainer(Directory home) {
  return ProviderContainer(
    overrides: [baseDirProvider.overrideWithValue(home.path)],
  );
}

Future<PluginTileSnapshot?> _waitForSnapshot(
  ProviderContainer container,
  String id, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final pluginDashboardService = container.read(
      pluginDashboardServiceProvider,
    );
    final snap = pluginDashboardService.seed[id];
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

      final container = _makeContainer(home);
      addTearDown(container.dispose);

      final pluginDashboardService = container.read(
        pluginDashboardServiceProvider,
      );
      addTearDown(pluginDashboardService.dispose);

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

      final container = _makeContainer(home);
      addTearDown(container.dispose);
      final pluginDashboardService = container.read(
        pluginDashboardServiceProvider,
      );
      addTearDown(pluginDashboardService.dispose);

      final snap = await _waitForSnapshot(container, 'demo');
      expect(snap, isNotNull);
      expect(snap!.footer, contains('exit 7'));
      expect(snap.footer, contains('bad thing happened'));
      expect(snap.footerColor, PluginTileStatus.error);
    });

    test(
      'exit 127 (command-not-found) renders as a yellow pending tile',
      () async {
        _seedPluginWithTileCommand(
          home,
          'demo',
          tileCommand: 'definitely-not-a-real-binary-aiyf',
        );

        final container = _makeContainer(home);
        addTearDown(container.dispose);
        final pluginDashboardService = container.read(
          pluginDashboardServiceProvider,
        );
        addTearDown(pluginDashboardService.dispose);

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

      final container = _makeContainer(home);
      addTearDown(container.dispose);
      final pluginDashboardService = container.read(
        pluginDashboardServiceProvider,
      );
      addTearDown(pluginDashboardService.dispose);

      final snap = await _waitForSnapshot(container, 'demo');
      expect(snap, isNotNull);
      expect(snap!.footer, contains('invalid JSON'));
      expect(snap.footerColor, PluginTileStatus.error);
    });

    test('skips plugins without a dashboard block', () async {
      // Create a plugin WITHOUT a dashboard block; service should
      // not poll it.
      final dir = Directory('${home.path}/plugins/headless')
        ..createSync(recursive: true);
      File('${dir.path}/plugin.nix').writeAsStringSync('{}\n');
      File('${dir.path}/plugin.json').writeAsStringSync(
        jsonEncode({
          'manifest': {
            'schema_version': 2,
            'min_tui_version': 2,
            'name': 'headless',
          },
          'id': 'headless',
        }),
      );
      writeMarker(
        dir.path,
        PluginMarker(
          id: 'headless',
          url: 'file://${dir.path}',
          version: '0.1.0',
          rev: 'a' * 40,
          installedAt: DateTime.utc(2026, 1, 1),
          disabled: false,
        ),
      );

      final container = _makeContainer(home);
      addTearDown(container.dispose);
      final pluginDashboardService = container.read(
        pluginDashboardServiceProvider,
      );
      addTearDown(pluginDashboardService.dispose);

      // Wait briefly to ensure no poller would have run.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(pluginDashboardService.seed.containsKey('headless'), isFalse);
    });

    test('skips disabled plugins', () async {
      _seedPluginWithTileCommand(
        home,
        'demo',
        tileCommand: r'''echo '{"_status_label":"x"}' ''',
        disabled: true,
      );

      final container = _makeContainer(home);
      addTearDown(container.dispose);
      final pluginDashboardService = container.read(
        pluginDashboardServiceProvider,
      );
      addTearDown(pluginDashboardService.dispose);

      // Wait briefly to ensure no poller would have run.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(pluginDashboardService.seed.containsKey('demo'), isFalse);
    });
  });
}
