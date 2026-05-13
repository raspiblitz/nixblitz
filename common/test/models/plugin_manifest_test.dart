import 'package:test/test.dart';
import 'package:common/src/models/plugin/plugin_dep.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/models/plugin/plugin_manifest_error.dart';

void main() {
  group('PluginManifest.fromJsonString', () {
    test('parses a JSON string', () {
      final m = PluginManifest.fromJsonString('''
        {
          "manifest": {"schema_version": 2, "min_tui_version": 2, "name": "p"},
          "id": "p"
        }
      ''');
      expect(m.id, 'p');
      expect(m.name, 'p');
    });
  });

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
      expect(m.permissions.isEmpty, isTrue);
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

    test('parses action with inputs', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'connect': {
            'label': 'Connect',
            'unit': 'p-connect.service',
            'inputs': [
              {
                'name': 'authkey',
                'label': 'Pre-auth key',
                'description': 'One-time, expires in 1h.',
                'type': 'secret',
              },
            ],
          },
        },
        'permissions': {
          'privileged_units': ['p-connect.service'],
        },
      });
      final action = m.actions['connect']!;
      expect(action.inputs, hasLength(1));
      expect(action.inputs.first.name, 'authkey');
      expect(action.inputs.first.label, 'Pre-auth key');
      expect(action.inputs.first.type, 'secret');
      expect(action.inputs.first.envVarName, 'NIXBLITZ_INPUT_AUTHKEY');
    });

    test('action with empty inputs list parses', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'r': {'label': 'R', 'command': 'true', 'inputs': []},
        },
      });
      expect(m.actions['r']!.inputs, isEmpty);
    });

    test('action input with bad name is rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'r': {
              'label': 'R',
              'command': 'true',
              'inputs': [
                {'name': 'BAD-NAME', 'label': 'x'},
              ],
            },
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action input with unknown type is rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'r': {
              'label': 'R',
              'command': 'true',
              'inputs': [
                {'name': 'x', 'label': 'x', 'type': 'integer'},
              ],
            },
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action with duplicate input names is rejected', () {
      expect(
        () => PluginManifest.fromJson({
          'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
          'actions': {
            'r': {
              'label': 'R',
              'command': 'true',
              'inputs': [
                {'name': 'k', 'label': 'a'},
                {'name': 'k', 'label': 'b'},
              ],
            },
          },
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('action with inputs round-trips via toJson', () {
      final m = PluginManifest.fromJson({
        'manifest': {'schema_version': 2, 'min_tui_version': 1, 'name': 'p'},
        'actions': {
          'r': {
            'label': 'R',
            'command': 'true',
            'inputs': [
              {'name': 'authkey', 'label': 'Key', 'type': 'secret'},
            ],
          },
        },
      });
      final back = PluginManifest.fromJson(m.toJson());
      expect(back.actions['r']!.inputs.first.name, 'authkey');
      expect(back.actions['r']!.inputs.first.type, 'secret');
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
        'permissions': {
          'bitcoin': ['rpc:read'],
        },
      };
      final m = PluginManifest.fromJson(json);
      final roundTripped = PluginManifest.fromJson(m.toJson());
      expect(roundTripped.name, m.name);
      expect(roundTripped.description, 'desc');
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

    test('config_schema id falls back to plugin id, not display name', () {
      // Regression: before Task 1.5 introduced top-level `id`, the
      // config_schema id fallback used the display `name`. With id ≠ name
      // (e.g. id "blitz-api" vs name "Blitz API"), the AppManifest id
      // would be the display name — wrong, since dep-check / install flow
      // key on `id`. The fallback must prefer `id`.
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 2,
          'min_tui_version': 2,
          'name': 'Blitz API',
        },
        'id': 'blitz-api',
        'config_schema': {
          'label': 'Blitz API',
          'description': 'FastAPI backend',
          'capabilities': <String>[],
          'fields': <Map<String, dynamic>>[],
        },
      });
      expect(m.configSchema, isNotNull);
      expect(m.configSchema!.id, 'blitz-api');
    });

    test('config_schema id falls back to name when no top-level id', () {
      // Existing v2 tailscale-style manifests had no top-level `id`;
      // their config_schema continues to use `name` as fallback so
      // back-compat is preserved.
      final m = PluginManifest.fromJson({
        'manifest': {
          'schema_version': 2,
          'min_tui_version': 1,
          'name': 'tailscale',
        },
        'config_schema': {
          'label': 'Tailscale',
          'description': '',
          'capabilities': <String>[],
          'fields': <Map<String, dynamic>>[],
        },
      });
      expect(m.configSchema!.id, 'tailscale');
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
}
