import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_manifest_error.dart';
import 'package:common/src/models/plugin/plugin_streamer_spec.dart';

void main() {
  group('StreamerSpec.fromJson', () {
    test('parses a full spec', () {
      final s = StreamerSpec.fromJson({
        'name': 'blitz-api',
        'command': 'python3',
        'args': ['streamer.py', '--verbose'],
        'tile_ids': ['btc-status', 'lnd-status'],
      });
      expect(s.name, 'blitz-api');
      expect(s.command, 'python3');
      expect(s.args, ['streamer.py', '--verbose']);
      expect(s.tileIds, {'btc-status', 'lnd-status'});
    });

    test('args defaults to empty list when omitted', () {
      final s = StreamerSpec.fromJson({
        'name': 's',
        'command': 'python3',
        'tile_ids': ['t1'],
      });
      expect(s.args, isEmpty);
    });

    test('args may be explicitly empty', () {
      final s = StreamerSpec.fromJson({
        'name': 's',
        'command': 'python3',
        'args': <String>[],
        'tile_ids': ['t1'],
      });
      expect(s.args, isEmpty);
      expect(s.tileIds, {'t1'});
    });

    test('missing name throws PluginManifestError', () {
      expect(
        () => StreamerSpec.fromJson({
          'command': 'python3',
          'tile_ids': ['t1'],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('empty name throws PluginManifestError', () {
      expect(
        () => StreamerSpec.fromJson({
          'name': '',
          'command': 'python3',
          'tile_ids': ['t1'],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('missing command throws PluginManifestError', () {
      expect(
        () => StreamerSpec.fromJson({
          'name': 's',
          'tile_ids': ['t1'],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('empty command throws PluginManifestError', () {
      expect(
        () => StreamerSpec.fromJson({
          'name': 's',
          'command': '',
          'tile_ids': ['t1'],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('missing tile_ids throws PluginManifestError', () {
      expect(
        () => StreamerSpec.fromJson({'name': 's', 'command': 'python3'}),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('empty tile_ids throws PluginManifestError', () {
      // A streamer that emits for no tiles is meaningless.
      expect(
        () => StreamerSpec.fromJson({
          'name': 's',
          'command': 'python3',
          'tile_ids': <String>[],
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('toJson round-trips full spec', () {
      final s = StreamerSpec.fromJson({
        'name': 'blitz-api',
        'command': 'python3',
        'args': ['streamer.py'],
        'tile_ids': ['t1', 't2'],
      });
      final back = StreamerSpec.fromJson(s.toJson());
      expect(back.name, s.name);
      expect(back.command, s.command);
      expect(back.args, s.args);
      expect(back.tileIds, s.tileIds);
    });
  });
}
