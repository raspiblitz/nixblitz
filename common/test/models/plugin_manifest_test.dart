import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/models/plugin/plugin_manifest_error.dart';

void main() {
  group('PluginManifest.fromJson', () {
    test('parses a minimal valid manifest', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 2,
          'min_tui_version': 1,
          'name': 'nixblitz-tailscale',
          'description': 'Enable Tailscale on this node',
        },
      });
      expect(m.name, 'nixblitz-tailscale');
      expect(m.schemaVersion, 2);
      expect(m.minTuiVersion, 1);
      expect(m.config, isEmpty);
      expect(m.permissions.isEmpty, isTrue);
    });

    test('parses config fields', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 2,
          'min_tui_version': 1,
          'name': 'tailscale',
        },
        'config': {
          'auth_key': {
            'type': 'secret',
            'label': 'Auth key',
            'required': false,
          },
          'tags': {'type': 'list<string>', 'label': 'ACL tags'},
          'exit_node': {'type': 'bool', 'label': 'Exit node', 'default': false},
        },
      });
      expect(m.config.keys, containsAll(['auth_key', 'tags', 'exit_node']));
      expect(m.config['auth_key']!.type, 'secret');
      expect(m.config['tags']!.type, 'list<string>');
      expect(m.config['exit_node']!.defaultValue, false);
    });

    test('parses unprivileged command actions', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'whoami': {
            'label': 'Who am I',
            'command': 'whoami',
            'confirm': false,
          },
        },
      });
      expect(m.actions['whoami']!.command, 'whoami');
      expect(m.actions['whoami']!.unit, isNull);
      expect(m.actions['whoami']!.isPrivileged, isFalse);
      expect(m.actions['whoami']!.confirm, isFalse);
      expect(m.actions['whoami']!.timeoutSeconds, 300); // default
    });

    test('parses privileged unit actions', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'reset_db': {
            'label': 'Reset database',
            'description': 'Wipes the DB.',
            'unit': 'lnbits-reset-db.service',
            'timeout_seconds': 60,
          },
        },
        'permissions': {
          'privileged_units': ['lnbits-reset-db.service'],
        },
      });
      expect(m.actions['reset_db']!.unit, 'lnbits-reset-db.service');
      expect(m.actions['reset_db']!.command, isNull);
      expect(m.actions['reset_db']!.isPrivileged, isTrue);
      expect(m.actions['reset_db']!.timeoutSeconds, 60);
      expect(m.permissions.privilegedUnits, ['lnbits-reset-db.service']);
    });

    test('schema v1 manifest with no v1-only fields is rejected', () {
      // v1 manifests are no longer accepted; loader hard-fails so an
      // operator running an old TUI gets a clear migration message.
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('schema_version'),
          ),
        ),
      );
    });

    test('v1 run_as_root action gets migration-hint error', () {
      // The action-level `run_as_root: true` rejection has its own
      // pointed message even before the schema-version check fires.
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 1, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'r': {'label': 'R', 'command': 'true', 'run_as_root': true},
          },
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('run_as_root'),
          ),
        ),
      );
    });

    test('action with both command and unit rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'mixed': {
              'label': 'Mixed',
              'command': 'whoami',
              'unit': 'whoami.service',
            },
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action with neither command nor unit rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'noop': {'label': 'Noop'},
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('unit action without permissions.privileged_units entry rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'sneaky': {'label': 'Sneaky', 'unit': 'systemd-shutdown.service'},
          },
          // No permissions.privileged_units → unit reference is rejected.
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action without label throws FormatException', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'broken': {'command': 'whoami'},
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action with run_as_root in v2 manifest is rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'broken': {
              'label': 'broken',
              'command': 'whoami',
              'run_as_root': true,
            },
          },
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('run_as_root'),
          ),
        ),
      );
    });

    test('action with non-positive timeout throws FormatException', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'bad': {'label': 'x', 'command': 'true', 'timeout_seconds': 0},
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('command actions round-trip via toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'r': {'label': 'R', 'command': 'true', 'timeout_seconds': 90},
        },
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.actions['r']!.command, 'true');
      expect(back.actions['r']!.unit, isNull);
      expect(back.actions['r']!.timeoutSeconds, 90);
    });

    test('unit actions round-trip via toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'reset': {'label': 'Reset', 'unit': 'p-reset.service'},
        },
        'permissions': {
          'privileged_units': ['p-reset.service'],
        },
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.actions['reset']!.unit, 'p-reset.service');
      expect(back.actions['reset']!.command, isNull);
      expect(back.permissions.privilegedUnits, ['p-reset.service']);
    });

    test('parses dashboard block', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'dashboard': {
          'title': 'Tailscale',
          'accent_color': '#2596be',
          'command': 'tailscale-tile-state',
          'poll_interval_seconds': 30,
          'timeout_seconds': 5,
        },
      });
      expect(m.dashboard, isNotNull);
      expect(m.dashboard!.title, 'Tailscale');
      expect(m.dashboard!.accentColorHex, '#2596be');
      expect(m.dashboard!.command, 'tailscale-tile-state');
      expect(m.dashboard!.pollInterval, const Duration(seconds: 30));
      expect(m.dashboard!.timeout, const Duration(seconds: 5));
    });

    test('dashboard with run_as_root in v2 manifest is rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'dashboard': {'title': 'X', 'command': 'x', 'run_as_root': true},
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('run_as_root'),
          ),
        ),
      );
    });

    test('dashboard with defaults', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'dashboard': {'title': 'X', 'command': 'x-state'},
      });
      expect(m.dashboard!.pollInterval, const Duration(seconds: 30));
      expect(m.dashboard!.timeout, const Duration(seconds: 5));
      expect(m.dashboard!.accentColorHex, '#888899');
    });

    test('dashboard without title throws FormatException', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'dashboard': {'command': 'x'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('dashboard without command throws FormatException', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'dashboard': {'title': 'X'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('dashboard with malformed accent color throws', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'dashboard': {'title': 'X', 'command': 'x', 'accent_color': 'red'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('dashboard with poll_interval below floor throws', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'dashboard': {
            'title': 'X',
            'command': 'x',
            'poll_interval_seconds': 1,
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('manifest without dashboard block has null dashboard', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
      });
      expect(m.dashboard, isNull);
    });

    test('dashboard round-trips via toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'dashboard': {
          'title': 'X',
          'accent_color': '#abcdef',
          'command': 'x-state',
          'poll_interval_seconds': 60,
        },
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.dashboard!.title, 'X');
      expect(back.dashboard!.accentColorHex, '#abcdef');
      expect(back.dashboard!.pollInterval, const Duration(seconds: 60));
    });

    test('parses permissions block', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
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
          'schema_version': 2,
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
          'manifest': {'schema_version': 2, 'min_tui_version': 1},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('plugin without config_schema parses fine', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 2,
          'min_tui_version': 1,
          'name': 'test-plugin',
        },
      });
      expect(m.configSchema, isNull);
    });

    test('plugin with config_schema parses + inherits id', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 2,
          'min_tui_version': 1,
          'name': 'tailscale',
        },
        'config_schema': {
          'label': 'Tailscale',
          'fields': [
            {
              'name': 'enabled',
              'type': 'bool',
              'label': 'Enabled',
              'default': false,
            },
          ],
        },
      });
      expect(m.configSchema, isNotNull);
      expect(m.configSchema!.id, 'tailscale');
      expect(m.configSchema!.label, 'Tailscale');
      expect(m.configSchema!.fields.length, 1);
    });

    test('manifest with requires + module + streamers (full happy path)', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 2, 'name': 'p'},
        'requires': [
          {'type': 'app', 'id': 'bitcoind'},
          {'type': 'plugin', 'url': 'git+https://example.com/dep.git'},
        ],
        'module': 'module.nix',
        'streamers': [
          {
            'name': 's',
            'command': 'python3',
            'args': ['streamer.py'],
            'tile_ids': ['t1', 't2'],
          },
        ],
      });
      expect(m.requires.length, 2);
      expect(m.requires[0], isA<AppDep>());
      expect((m.requires[0] as AppDep).id, 'bitcoind');
      expect(m.requires[1], isA<PluginUrlDep>());
      expect(
        (m.requires[1] as PluginUrlDep).url,
        'git+https://example.com/dep.git',
      );
      expect(m.module, 'module.nix');
      expect(m.streamers.length, 1);
      expect(m.streamers.first.name, 's');
      expect(m.streamers.first.command, 'python3');
      expect(m.streamers.first.args, ['streamer.py']);
      expect(m.streamers.first.tileIds, {'t1', 't2'});
    });

    test(
      'manifest without requires/module/streamers defaults to empty/null',
      () {
        final m = PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        });
        expect(m.requires, isEmpty);
        expect(m.module, isNull);
        expect(m.streamers, isEmpty);
      },
    );

    test('requires + module + streamers round-trip via toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 2, 'name': 'p'},
        'requires': [
          {'type': 'app', 'id': 'lnd'},
        ],
        'module': 'nix/module.nix',
        'streamers': [
          {
            'name': 'blitz-api',
            'command': 'python3',
            'tile_ids': ['btc-status'],
          },
        ],
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.requires.length, 1);
      expect(back.requires.first, isA<AppDep>());
      expect((back.requires.first as AppDep).id, 'lnd');
      expect(back.module, 'nix/module.nix');
      expect(back.streamers.length, 1);
      expect(back.streamers.first.name, 'blitz-api');
      expect(back.streamers.first.tileIds, {'btc-status'});
    });

    test(
      'manifest with malformed requires entry rethrows PluginManifestError',
      () {
        expect(
          () => PluginManifest.fromJson({
            'manifest': {
              'schema_version': 2,
              'min_tui_version': 1,
              'name': 'p',
            },
            'requires': [
              {'type': 'unknown-kind'},
            ],
          }),
          throwsA(isA<PluginManifestError>()),
        );
      },
    );

    test('manifest with empty module string throws PluginManifestError', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'module': '',
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('manifest id defaults to name when absent', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
      });
      expect(m.id, 'p');
      expect(m.url, isNull);
      expect(m.version, isNull);
    });

    test('manifest with explicit id/url/version round-trips', () {
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 2,
          'min_tui_version': 2,
          'name': 'Blitz API',
        },
        'id': 'blitz-api',
        'url': 'git+https://forge.example/p',
        'version': '0.1.0',
      });
      expect(m.id, 'blitz-api');
      expect(m.name, 'Blitz API');
      expect(m.url, 'git+https://forge.example/p');
      expect(m.version, '0.1.0');

      final back = PluginManifest.fromJson(m.toJson());
      expect(back.id, 'blitz-api');
      expect(back.url, 'git+https://forge.example/p');
      expect(back.version, '0.1.0');
    });

    test('manifest empty id throws PluginManifestError', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'id': '',
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('manifest empty url throws PluginManifestError', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'url': '',
        }),
        throwsA(isA<PluginManifestError>()),
      );
    });

    test('config_schema round-trips via toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'config_schema': {
          'label': 'P',
          'fields': [
            {
              'name': 'enabled',
              'type': 'bool',
              'label': 'Enabled',
              'default': false,
            },
          ],
        },
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.configSchema, isNotNull);
      expect(back.configSchema!.id, 'p');
      expect(back.configSchema!.label, 'P');
      expect(back.configSchema!.fields.length, 1);
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
      final f = ConfigField.fromJson({'type': 'list<string>', 'label': 'Tags'});
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
      final f = ConfigField.fromJson({'type': 'select<a|b>', 'label': 'x'});
      expect(f.validate('a'), isNull);
      expect(f.validate('b'), isNull);
      expect(f.validate('c'), isNotNull);
      expect(f.validate(42), isNotNull);
    });

    test('list validates each element', () {
      final f = ConfigField.fromJson({'type': 'list<int>', 'label': 'x'});
      expect(f.validate([1, 2, 3]), isNull);
      expect(f.validate([1, 'oops', 3]), isNotNull);
      expect(f.validate('not a list'), isNotNull);
    });
  });
}
