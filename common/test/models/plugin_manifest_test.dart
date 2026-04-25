import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';

void main() {
  group('PluginManifest.fromJson', () {
    test('parses a minimal valid manifest', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 1,
          'min_tui_version': 1,
          'name': 'nixblitz-tailscale',
          'description': 'Enable Tailscale on this node',
        },
      });
      expect(m.name, 'nixblitz-tailscale');
      expect(m.schemaVersion, 1);
      expect(m.minTuiVersion, 1);
      expect(m.config, isEmpty);
      expect(m.permissions.isEmpty, isTrue);
    });

    test('parses config fields', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 1,
          'min_tui_version': 1,
          'name': 'tailscale',
        },
        'config': {
          'auth_key': {'type': 'secret', 'label': 'Auth key', 'required': false},
          'tags': {'type': 'list<string>', 'label': 'ACL tags'},
          'exit_node': {'type': 'bool', 'label': 'Exit node', 'default': false},
        },
      });
      expect(m.config.keys, containsAll(['auth_key', 'tags', 'exit_node']));
      expect(m.config['auth_key']!.type, 'secret');
      expect(m.config['tags']!.type, 'list<string>');
      expect(m.config['exit_node']!.defaultValue, false);
    });

    test('parses actions block', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'reset_db': {
            'label': 'Reset database',
            'description': 'Wipes the DB.',
            'command': 'lnbits-reset',
            'run_as_root': true,
            'confirm': true,
            'timeout_seconds': 60,
          },
          'whoami': {
            'label': 'Who am I',
            'command': 'whoami',
            'confirm': false,
          },
        },
      });
      expect(m.actions.keys, containsAll(['reset_db', 'whoami']));
      expect(m.actions['reset_db']!.label, 'Reset database');
      expect(m.actions['reset_db']!.runAsRoot, isTrue);
      expect(m.actions['reset_db']!.timeoutSeconds, 60);
      expect(m.actions['whoami']!.confirm, isFalse);
      expect(m.actions['whoami']!.timeoutSeconds, 300); // default
      expect(m.actions['whoami']!.runAsRoot, isFalse); // default
    });

    test('action without label throws FormatException', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'broken': {'command': 'whoami'},
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action without command throws FormatException', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'broken': {'label': 'no command'},
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action with non-positive timeout throws FormatException', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'bad': {
              'label': 'x',
              'command': 'true',
              'timeout_seconds': 0,
            },
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('actions round-trip via toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'r': {
            'label': 'R',
            'command': 'true',
            'run_as_root': true,
            'timeout_seconds': 90,
          },
        },
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.actions['r']!.runAsRoot, isTrue);
      expect(back.actions['r']!.timeoutSeconds, 90);
    });

    test('parses permissions block', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
        'permissions': {
          'bitcoin': ['rpc:read'],
          'network': ['outbound'],
          'filesystem': {
            'read': ['/mnt/data'],
          },
        },
      });
      expect(m.permissions.bitcoin, ['rpc:read']);
      expect(m.permissions.network, ['outbound']);
      expect(m.permissions.filesystemRead, ['/mnt/data']);
      expect(m.permissions.filesystemWrite, isEmpty);
    });

    test('round-trips via toJson', () {
      final json = {
        'manifest': {
          'schema_version': 1,
          'min_tui_version': 1,
          'name': 'p',
          'description': 'desc',
        },
        'config': {
          'k': {'type': 'string', 'label': 'K', 'required': true},
        },
        'permissions': {
          'bitcoin': ['rpc:read'],
        },
      };
      final m = PluginManifest.fromJson(json);
      final roundTripped = PluginManifest.fromJson(m.toJson());
      expect(roundTripped.name, m.name);
      expect(roundTripped.config['k']!.required, true);
      expect(roundTripped.permissions.bitcoin, ['rpc:read']);
    });

    test('throws PluginTooNewException when min_tui_version > current', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {
            'schema_version': 99,
            'min_tui_version': currentPluginManifestVersion + 1,
            'name': 'too-new',
          },
        }),
        throwsA(isA<PluginTooNewException>()),
      );
    });

    test('throws FormatException when manifest block missing', () {
      expect(
        () => PluginManifest.fromJson({'config': {}}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when name missing', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 1, 'min_tui_version': 1},
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ConfigField type parsing', () {
    test('accepts all primitive types', () {
      for (final t in ['bool', 'int', 'string', 'secret']) {
        final f = ConfigField.fromJson({'type': t, 'label': 'x'});
        expect(f.type, t);
      }
    });

    test('accepts select with choices', () {
      final f = ConfigField.fromJson({
        'type': 'select<red|green|blue>',
        'label': 'Color',
      });
      expect(f.type, 'select<red|green|blue>');
    });

    test('accepts list with primitive element type', () {
      final f = ConfigField.fromJson({
        'type': 'list<string>',
        'label': 'Tags',
      });
      expect(f.type, 'list<string>');
    });

    test('rejects unknown primitive', () {
      expect(
        () => ConfigField.fromJson({'type': 'date', 'label': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects list of unsupported inner type', () {
      expect(
        () => ConfigField.fromJson({'type': 'list<date>', 'label': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects select with empty choice', () {
      expect(
        () => ConfigField.fromJson({'type': 'select<a||b>', 'label': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ConfigField.validate', () {
    test('returns null for acceptable primitive values', () {
      expect(
        ConfigField.fromJson({'type': 'bool', 'label': 'x'}).validate(true),
        isNull,
      );
      expect(
        ConfigField.fromJson({'type': 'int', 'label': 'x'}).validate(42),
        isNull,
      );
      expect(
        ConfigField.fromJson({'type': 'string', 'label': 'x'}).validate('ok'),
        isNull,
      );
    });

    test('returns error for type mismatch', () {
      expect(
        ConfigField.fromJson({'type': 'int', 'label': 'x'}).validate('nope'),
        isNotNull,
      );
    });

    test('respects required', () {
      final f = ConfigField.fromJson({
        'type': 'string',
        'label': 'x',
        'required': true,
      });
      expect(f.validate(null), isNotNull);
      expect(f.validate(''), isNull); // empty string is still a string
    });

    test('select accepts listed choices only', () {
      final f = ConfigField.fromJson({
        'type': 'select<a|b>',
        'label': 'x',
      });
      expect(f.validate('a'), isNull);
      expect(f.validate('b'), isNull);
      expect(f.validate('c'), isNotNull);
      expect(f.validate(42), isNotNull);
    });

    test('list validates each element', () {
      final f = ConfigField.fromJson({
        'type': 'list<int>',
        'label': 'x',
      });
      expect(f.validate([1, 2, 3]), isNull);
      expect(f.validate([1, 'oops', 3]), isNotNull);
      expect(f.validate('not a list'), isNotNull);
    });
  });
}
