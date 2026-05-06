import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest_error.dart';

void main() {
  group('PluginDep.fromJson', () {
    test('parses an app dep', () {
      final dep = PluginDep.fromJson({'type': 'app', 'id': 'bitcoind'});
      expect(dep, isA<AppDep>());
      expect((dep as AppDep).id, 'bitcoind');
    });

    test('parses a plugin dep with url', () {
      final dep = PluginDep.fromJson({
        'type': 'plugin',
        'url': 'git+https://example.com/some-plugin.git',
      });
      expect(dep, isA<PluginUrlDep>());
      expect(
        (dep as PluginUrlDep).url,
        'git+https://example.com/some-plugin.git',
      );
    });

    test('unknown type throws PluginManifestError', () {
      expect(
        () => PluginDep.fromJson({'type': 'plugin-by-name', 'id': 'foo'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('missing type throws PluginManifestError', () {
      expect(
        () => PluginDep.fromJson({'id': 'bitcoind'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('app dep missing id throws PluginManifestError', () {
      expect(
        () => PluginDep.fromJson({'type': 'app'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('app dep with empty id throws PluginManifestError', () {
      expect(
        () => PluginDep.fromJson({'type': 'app', 'id': ''}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('plugin dep missing url throws PluginManifestError', () {
      expect(
        () => PluginDep.fromJson({'type': 'plugin'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('plugin dep with empty url throws PluginManifestError', () {
      expect(
        () => PluginDep.fromJson({'type': 'plugin', 'url': ''}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('plugin dep with unrecognised scheme throws PluginManifestError', () {
      // Whitespace, bare paths, ftp, ssh-without-git+, etc. all rejected
      // at the manifest boundary so the dep resolver never sees them.
      for (final bad in [
        '  ',
        'example.com/foo.git',
        'ftp://example.com/foo.git',
        'ssh://git@example.com/foo.git',
      ]) {
        expect(
          () => PluginDep.fromJson({'type': 'plugin', 'url': bad}),
          throwsA(isA<PluginManifestError>()),
          reason: 'expected rejection of `$bad`',
        );
      }
    });

    test('plugin dep accepts each allowed url scheme', () {
      // Smoke-test the positive side of the scheme check.
      for (final good in [
        'git+https://example.com/x.git',
        'git+ssh://git@example.com/x.git',
        'https://example.com/x.git',
        'http://example.com/x.git',
        'file:/srv/plugins/x',
      ]) {
        final dep = PluginDep.fromJson({'type': 'plugin', 'url': good});
        expect(dep, isA<PluginUrlDep>());
        expect((dep as PluginUrlDep).url, good);
      }
    });

    test('sealed switch is exhaustive over AppDep | PluginUrlDep', () {
      // Compile-time check: this switch must be exhaustive.
      final deps = <PluginDep>[
        PluginDep.fromJson({'type': 'app', 'id': 'lnd'}),
        PluginDep.fromJson({
          'type': 'plugin',
          'url': 'git+https://example.com/x.git',
        }),
      ];
      final labels = deps
          .map(
            (d) => switch (d) {
              AppDep(:final id) => 'app:$id',
              PluginUrlDep(:final url) => 'plugin:$url',
            },
          )
          .toList();
      expect(labels, ['app:lnd', 'plugin:git+https://example.com/x.git']);
    });
  });
}
