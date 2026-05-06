import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/plugin/plugin_dep_check.dart';
import 'package:test/test.dart';

PluginManifest _m(
  String id, {
  List<PluginDep> requires = const [],
  String? url,
}) {
  return PluginManifest.fromJson({
    'manifest': {'schema_version': 2, 'min_tui_version': 2, 'name': id},
    'id': id,
    'url': ?url,
    'requires': [for (final d in requires) d.toJson()],
  });
}

NixblitzConfig _cfg(Map<String, Map<String, dynamic>> apps) =>
    NixblitzConfig(system: SystemConfig.defaults(), appConfigs: apps);

void main() {
  group('checkPluginDeps', () {
    test('plugin with no deps → ok', () {
      final result = checkPluginDeps([_m('p1')], _cfg({}));
      expect(result['p1'], same(DepStatus.ok));
    });

    test('app dep satisfied → ok', () {
      final plugins = [
        _m('p1', requires: const [AppDep(id: 'bitcoind')]),
      ];
      final result = checkPluginDeps(
        plugins,
        _cfg({
          'bitcoind': {'enabled': true},
        }),
      );
      expect(result['p1'], same(DepStatus.ok));
    });

    test('app dep missing → unsatisfied', () {
      final plugins = [
        _m('p1', requires: const [AppDep(id: 'bitcoind')]),
      ];
      final result = checkPluginDeps(plugins, _cfg({}));
      final status = result['p1'];
      expect(status, isA<DepMissing>());
      final missing = (status as DepMissing).missing;
      expect(missing, hasLength(1));
      expect(missing.first, isA<AppDep>());
      expect((missing.first as AppDep).id, 'bitcoind');
    });

    test('app dep disabled → unsatisfied', () {
      final plugins = [
        _m('p1', requires: const [AppDep(id: 'bitcoind')]),
      ];
      final result = checkPluginDeps(
        plugins,
        _cfg({
          'bitcoind': {'enabled': false},
        }),
      );
      final status = result['p1'];
      expect(status, isA<DepMissing>());
      final missing = (status as DepMissing).missing;
      expect(missing, hasLength(1));
      expect((missing.first as AppDep).id, 'bitcoind');
    });

    test('plugin url dep satisfied → ok', () {
      final url = 'git+https://x/bitcoind';
      final plugins = [
        _m('bitcoind-provider', url: url),
        _m('p2', requires: [PluginUrlDep(url: url)]),
      ];
      final result = checkPluginDeps(plugins, _cfg({}));
      expect(result['bitcoind-provider'], same(DepStatus.ok));
      expect(result['p2'], same(DepStatus.ok));
    });

    test('plugin url dep missing → unsatisfied', () {
      final plugins = [
        _m('p1', requires: [PluginUrlDep(url: 'git+https://x/missing')]),
      ];
      final result = checkPluginDeps(plugins, _cfg({}));
      final status = result['p1'];
      expect(status, isA<DepMissing>());
      final missing = (status as DepMissing).missing;
      expect(missing, hasLength(1));
      expect(missing.first, isA<PluginUrlDep>());
      expect((missing.first as PluginUrlDep).url, 'git+https://x/missing');
    });

    test(
      'mixed deps — some met, some not → unsatisfied with the unmet ones',
      () {
        final plugins = [
          _m(
            'p1',
            requires: [
              const AppDep(id: 'bitcoind'),
              PluginUrlDep(url: 'git+https://x/missing'),
            ],
          ),
        ];
        final result = checkPluginDeps(
          plugins,
          _cfg({
            'bitcoind': {'enabled': true},
          }),
        );
        final status = result['p1'];
        expect(status, isA<DepMissing>());
        final missing = (status as DepMissing).missing;
        expect(missing, hasLength(1));
        expect(missing.first, isA<PluginUrlDep>());
        expect((missing.first as PluginUrlDep).url, 'git+https://x/missing');
      },
    );

    test('DepMissing.missing is unmodifiable', () {
      final plugins = [
        _m('p1', requires: const [AppDep(id: 'bitcoind')]),
      ];
      final result = checkPluginDeps(plugins, _cfg({}));
      final missing = (result['p1']! as DepMissing).missing;
      expect(
        () => missing.add(const AppDep(id: 'lnd')),
        throwsUnsupportedError,
      );
    });
  });
}
