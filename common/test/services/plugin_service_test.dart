import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_install_preview.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:common/src/services/plugin_service.dart';

import '../test_helpers/git_isolation.dart';

/// Seed a fresh git repo at [path] with a minimal plugin layout:
/// plugin.nix, plugin.json, and a README. Returns the path so the
/// caller can clone via `file://`.
///
/// The manifest's `id` is what determines the on-disk plugin
/// directory under `<baseDir>/plugins/`. Tests passing different
/// names through `id` exercise the new id-collision behaviour.
Future<String> _seedPluginRepo(
  String path, {
  String id = 'tailscale',
  String name = 'nixblitz-tailscale',
  bool includePluginNix = true,
  bool includeManifest = true,
  Map<String, dynamic>? manifestOverride,
}) async {
  final dir = Directory(path);
  dir.createSync(recursive: true);

  if (includePluginNix) {
    File(
      '$path/plugin.nix',
    ).writeAsStringSync('{ services.tailscale.enable = true; }\n');
  }

  if (includeManifest) {
    final manifest =
        manifestOverride ??
        {
          'manifest': {'schema_version': 2, 'min_tui_version': 2, 'name': name},
          'id': id,
        };
    File(
      '$path/plugin.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  }

  File('$path/README.md').writeAsStringSync('# $name\n');

  // git init + commit so `git clone --depth 1 --branch main` works.
  Future<void> run(List<String> args) async {
    final r = await testGit(args, workingDirectory: path);
    if (r.exitCode != 0) {
      throw StateError('git ${args.join(" ")} failed: ${r.stderr}');
    }
  }

  await run(['init', '-b', 'main']);
  await run(['add', '-A']);
  await run(['commit', '-m', 'initial']);

  return path;
}

Future<void> _seedBaseConfig(String baseDir) async {
  final configService = ConfigService(baseDir: baseDir);
  await configService.writeConfig(NixblitzConfig.defaults());
}

void main() {
  group('PluginService', () {
    late Directory home;
    late Directory srcRepo;
    late PluginService pluginService;

    setUp(() async {
      home = Directory.systemTemp.createTempSync('nixblitz_plugin_home_');
      srcRepo = Directory.systemTemp.createTempSync('nixblitz_plugin_src_');
      await _seedBaseConfig(home.path);
      await _seedPluginRepo(srcRepo.path);
      pluginService = PluginService(baseDir: home.path);
    });

    tearDown(() {
      home.deleteSync(recursive: true);
      srcRepo.deleteSync(recursive: true);
    });

    test('install creates plugin dir + marker + plugins.list', () async {
      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );

      expect(marker.id, 'tailscale');
      expect(marker.rev, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(marker.branch, 'main');
      expect(marker.disabled, isFalse);
      expect(marker.autoUpdate, isTrue);

      final pluginDir = Directory('${home.path}/plugins/${marker.id}');
      expect(pluginDir.existsSync(), isTrue);
      expect(File('${pluginDir.path}/plugin.nix').existsSync(), isTrue);
      expect(File('${pluginDir.path}/plugin.json').existsSync(), isTrue);
      expect(
        File('${pluginDir.path}/.nixblitz-installed.json').existsSync(),
        isTrue,
      );
      // No per-plugin config.json — config now lives in main
      // config.json's app_configs map.
      expect(File('${pluginDir.path}/config.json').existsSync(), isFalse);

      // plugins.list is regenerated on install (id-only format).
      final pluginsList = File('${home.path}/plugins.list');
      expect(pluginsList.existsSync(), isTrue);
      expect(pluginsList.readAsStringSync().trim(), 'tailscale');
    });

    test('install copies helper modules beyond the whitelist', () async {
      // A plugin whose plugin.nix imports a helper module (e.g.
      // extension-lib.nix) must get that module copied to the node —
      // the old hardcoded whitelist silently dropped it, breaking eval
      // with "path does not exist". Copy the whole tree, minus .git.
      File(
        '${srcRepo.path}/extension-lib.nix',
      ).writeAsStringSync('{lib, ...}: {}\n');
      File('${srcRepo.path}/extensions.json').writeAsStringSync('{}\n');
      final add = await testGit(['add', '-A'], workingDirectory: srcRepo.path);
      expect(add.exitCode, 0, reason: add.stderr.toString());
      final commit = await testGit([
        'commit',
        '-m',
        'add helper module',
      ], workingDirectory: srcRepo.path);
      expect(commit.exitCode, 0, reason: commit.stderr.toString());

      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      final pluginDir = Directory('${home.path}/plugins/${marker.id}');

      expect(
        File('${pluginDir.path}/extension-lib.nix').existsSync(),
        isTrue,
        reason: 'helper modules imported by plugin.nix must be copied',
      );
      expect(File('${pluginDir.path}/extensions.json').existsSync(), isTrue);
      // ...but VCS metadata must never be dragged along.
      expect(Directory('${pluginDir.path}/.git').existsSync(), isFalse);
    });

    test('install rejects id collision from a different URL', () async {
      await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );

      // Build a second source repo with the same manifest `id` but
      // a different URL.
      final second = Directory.systemTemp.createTempSync(
        'nixblitz_plugin_collide_',
      );
      try {
        await _seedPluginRepo(second.path, id: 'tailscale');
        await expectLater(
          () => pluginService.install(
            'file://${second.path}',
            allowInsecure: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('id collision'), contains('tailscale')),
            ),
          ),
        );
      } finally {
        second.deleteSync(recursive: true);
      }
    });

    test('install refuses duplicate of same URL when active', () async {
      await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      expect(
        () => pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('reinstall over a disabled marker wipes + recreates', () async {
      final first = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      await pluginService.disable(first.id);

      // Drop a sentinel file so we can verify the dir was wiped.
      final sentinel = File('${home.path}/plugins/${first.id}/leftover.txt');
      sentinel.writeAsStringSync('stale');

      final second = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      expect(second.id, first.id);
      expect(second.disabled, isFalse);
      expect(sentinel.existsSync(), isFalse);
    });

    test('install confirm callback receives manifest preview', () async {
      PluginInstallPreview? captured;
      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
        confirm: (preview) async {
          captured = preview;
          return true;
        },
      );

      expect(captured, isNotNull);
      expect(captured!.name, 'nixblitz-tailscale');
      expect(captured!.url, contains(srcRepo.path));
      expect(captured!.branch, 'main');
      expect(captured!.pinnedRev, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(captured!.schemaVersion, 2);
      // Fixture declares no `type: secret` fields → no cleartext warning.
      expect(captured!.secretFieldNames, isEmpty);

      expect(marker.rev, captured!.pinnedRev);
    });

    test('install preview surfaces secret config fields', () async {
      final withSecret = Directory.systemTemp.createTempSync(
        'nixblitz_plugin_secret_',
      );
      try {
        await _seedPluginRepo(
          withSecret.path,
          id: 'with-secret',
          name: 'with-secret',
          manifestOverride: {
            'manifest': {
              'schema_version': 2,
              'min_tui_version': 2,
              'name': 'with-secret',
            },
            'id': 'with-secret',
            'config_schema': {
              'id': 'with-secret',
              'label': 'With Secret',
              'fields': [
                {
                  'type': 'bool',
                  'name': 'enabled',
                  'label': 'Enabled',
                  'default': false,
                },
                {
                  'type': 'secret',
                  'name': 'auth_key',
                  'label': 'Auth key',
                  'default': '',
                },
              ],
            },
          },
        );

        PluginInstallPreview? captured;
        await pluginService.install(
          'file://${withSecret.path}',
          allowInsecure: true,
          confirm: (preview) async {
            captured = preview;
            return true;
          },
        );

        // The consent prompt keys its cleartext-storage warning off
        // this list — a manifest with a secret field must surface it.
        expect(captured!.secretFieldNames, ['auth_key']);
      } finally {
        withSecret.deleteSync(recursive: true);
      }
    });

    test('install confirm returning false aborts cleanly', () async {
      expect(
        () => pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
          confirm: (_) async => false,
        ),
        throwsA(isA<PluginInstallCancelled>()),
      );

      // Nothing landed on disk.
      final pluginsDir = Directory('${home.path}/plugins');
      if (pluginsDir.existsSync()) {
        expect(pluginsDir.listSync(), isEmpty);
      }
    });

    test('install with null confirm skips the prompt entirely', () async {
      var calls = 0;
      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      expect(marker.id, isNotEmpty);
      expect(calls, 0);
    });

    test('install with malformed manifest leaves nothing behind', () async {
      final bad = Directory.systemTemp.createTempSync('nixblitz_plugin_bad_');
      await _seedPluginRepo(bad.path, manifestOverride: {'not': 'a manifest'});

      expect(
        () => pluginService.install('file://${bad.path}', allowInsecure: true),
        throwsA(anything),
      );

      final pluginsDir = Directory('${home.path}/plugins');
      if (pluginsDir.existsSync()) {
        expect(pluginsDir.listSync(), isEmpty);
      }

      bad.deleteSync(recursive: true);
    });

    test('install refuses when plugin.nix is missing', () async {
      final noPluginNix = Directory.systemTemp.createTempSync(
        'nixblitz_plugin_nopkg_',
      );
      await _seedPluginRepo(noPluginNix.path, includePluginNix: false);

      expect(
        () => pluginService.install(
          'file://${noPluginNix.path}',
          allowInsecure: true,
        ),
        throwsA(isA<StateError>()),
      );

      noPluginNix.deleteSync(recursive: true);
    });

    test('insecure schemes refused without --insecure', () async {
      expect(
        () => pluginService.install('file://${srcRepo.path}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('clone failure on a subdir inside a repo suggests --subdir', () async {
      final outer = Directory.systemTemp.createTempSync('nixblitz_outer_');
      try {
        await _seedPluginRepo(outer.path);
        Directory('${outer.path}/tailscale').createSync();
        File('${outer.path}/tailscale/plugin.nix').writeAsStringSync('{}\n');
        File('${outer.path}/tailscale/plugin.json').writeAsStringSync(
          jsonEncode({
            'manifest': {
              'schema_version': 2,
              'min_tui_version': 2,
              'name': 'ts',
            },
            'id': 'ts',
          }),
        );

        await expectLater(
          () => pluginService.install(
            '${outer.path}/tailscale',
            allowInsecure: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('sits inside the git repo'),
                contains(outer.path),
                contains('--subdir tailscale'),
              ),
            ),
          ),
        );
      } finally {
        outer.deleteSync(recursive: true);
      }
    });

    test(
      'multi-plugin repo without --subdir lists available plugins',
      () async {
        final multi = Directory.systemTemp.createTempSync(
          'nixblitz_multi_list_',
        );
        try {
          for (final name in ['tailscale', 'btcpay']) {
            Directory('${multi.path}/$name').createSync(recursive: true);
            File('${multi.path}/$name/plugin.nix').writeAsStringSync('{}\n');
            File('${multi.path}/$name/plugin.json').writeAsStringSync(
              jsonEncode({
                'manifest': {
                  'schema_version': 2,
                  'min_tui_version': 2,
                  'name': name,
                },
                'id': name,
              }),
            );
          }
          Directory('${multi.path}/docs').createSync();
          File('${multi.path}/docs/notes.md').writeAsStringSync('# docs\n');
          File('${multi.path}/README.md').writeAsStringSync('# multi\n');

          for (final args in [
            ['init', '-b', 'main'],
            ['add', '-A'],
            ['commit', '-m', 'initial'],
          ]) {
            final r = await testGit(args, workingDirectory: multi.path);
            expect(r.exitCode, 0, reason: r.stderr.toString());
          }

          await expectLater(
            () => pluginService.install(
              'file://${multi.path}',
              allowInsecure: true,
            ),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('btcpay'),
                  contains('tailscale'),
                  contains('--subdir'),
                  isNot(contains('docs')),
                ),
              ),
            ),
          );
        } finally {
          multi.deleteSync(recursive: true);
        }
      },
    );

    test('install with --subdir from a multi-plugin repo', () async {
      final multi = Directory.systemTemp.createTempSync('nixblitz_multi_');
      try {
        Directory('${multi.path}/tailscale').createSync(recursive: true);
        File(
          '${multi.path}/tailscale/plugin.nix',
        ).writeAsStringSync('{ services.tailscale.enable = true; }\n');
        File('${multi.path}/tailscale/plugin.json').writeAsStringSync(
          jsonEncode({
            'manifest': {
              'schema_version': 2,
              'min_tui_version': 2,
              'name': 'tailscale',
            },
            'id': 'tailscale',
          }),
        );
        File('${multi.path}/README.md').writeAsStringSync('# multi\n');
        for (final args in [
          ['init', '-b', 'main'],
          ['add', '-A'],
          ['commit', '-m', 'initial'],
        ]) {
          final r = await testGit(args, workingDirectory: multi.path);
          expect(r.exitCode, 0, reason: r.stderr.toString());
        }

        final marker = await pluginService.install(
          'file://${multi.path}',
          allowInsecure: true,
          subdir: 'tailscale',
        );
        expect(marker.url, contains('dir=tailscale'));
        expect(marker.id, 'tailscale');

        final pluginDir = Directory('${home.path}/plugins/${marker.id}');
        expect(File('${pluginDir.path}/plugin.nix').existsSync(), isTrue);
      } finally {
        multi.deleteSync(recursive: true);
      }
    });

    test('refuses to install a repo containing a symlink', () async {
      final malicious = Directory.systemTemp.createTempSync(
        'nixblitz_plugin_evil_',
      );
      try {
        await _seedPluginRepo(malicious.path);
        Link('${malicious.path}/leak').createSync('/etc/passwd');
        final addRes = await testGit([
          'add',
          '-A',
        ], workingDirectory: malicious.path);
        expect(addRes.exitCode, 0, reason: 'git add failed: ${addRes.stderr}');
        final commitRes = await testGit([
          'commit',
          '-m',
          'add symlink',
        ], workingDirectory: malicious.path);
        expect(
          commitRes.exitCode,
          0,
          reason: 'git commit failed: ${commitRes.stderr}',
        );

        await expectLater(
          () => pluginService.install(
            'file://${malicious.path}',
            allowInsecure: true,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('symlink'),
            ),
          ),
        );

        final pluginsDir = Directory('${home.path}/plugins');
        if (pluginsDir.existsSync()) {
          expect(pluginsDir.listSync(), isEmpty);
        }
      } finally {
        malicious.deleteSync(recursive: true);
      }
    });

    test('remove wipes dir + marker; plugins.list dropped', () async {
      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      final pluginDir = Directory('${home.path}/plugins/${marker.id}');
      expect(pluginDir.existsSync(), isTrue);

      await pluginService.remove(marker.id);

      expect(pluginDir.existsSync(), isFalse);
      expect(
        File('${home.path}/plugins.list').readAsStringSync().trim(),
        isEmpty,
      );
    });

    test('remove on missing plugin throws StateError', () async {
      expect(
        () => pluginService.remove('not-installed'),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'disable flips marker.disabled and drops the plugin from plugins.list',
      () async {
        final marker = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        final disabled = await pluginService.disable(marker.id);
        expect(disabled.disabled, isTrue);

        // Marker stays on disk.
        final read = readMarker('${home.path}/plugins/${marker.id}');
        expect(read?.disabled, isTrue);

        // plugins.list excludes the disabled plugin.
        expect(
          File('${home.path}/plugins.list').readAsStringSync().trim(),
          isEmpty,
        );
      },
    );

    test('enable flips marker.disabled back to false', () async {
      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      await pluginService.disable(marker.id);
      final enabled = await pluginService.enable(marker.id);
      expect(enabled.disabled, isFalse);

      // plugins.list includes it again (id-only format).
      expect(
        File('${home.path}/plugins.list').readAsStringSync().trim(),
        marker.id,
      );
    });

    test('refresh re-fetches files and updates marker rev', () async {
      final first = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );

      // Advance the upstream repo: change plugin.nix, commit.
      File('${srcRepo.path}/plugin.nix').writeAsStringSync(
        '# refreshed plugin.nix v2\n{ services.tailscale.enable = true; }\n',
      );
      for (final args in [
        ['add', '-A'],
        ['commit', '-m', 'update plugin'],
      ]) {
        final r = await testGit(args, workingDirectory: srcRepo.path);
        expect(r.exitCode, 0, reason: r.stderr.toString());
      }

      final refreshed = await pluginService.refresh(
        first.id,
        allowInsecure: true,
      );

      expect(refreshed.rev, isNot(first.rev));
      expect(refreshed.id, first.id);

      final pluginNix = File(
        '${home.path}/plugins/${refreshed.id}/plugin.nix',
      ).readAsStringSync();
      expect(pluginNix, contains('# refreshed plugin.nix v2'));

      // Marker is rewritten with the new rev.
      final reread = readMarker('${home.path}/plugins/${refreshed.id}')!;
      expect(reread.rev, refreshed.rev);
    });

    test('refresh is a no-op when upstream pin matches existing', () async {
      final first = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );

      final refreshed = await pluginService.refresh(
        first.id,
        allowInsecure: true,
      );

      expect(refreshed.rev, first.rev);
      expect(
        refreshed.installedAt,
        first.installedAt,
        reason: 'installedAt should not bump on no-op refresh',
      );
    });

    test('refresh throws when plugin is not installed', () async {
      expect(
        () => pluginService.refresh('not-installed', allowInsecure: true),
        throwsA(isA<StateError>()),
      );
    });

    test('install consent preview carries the commit signature', () async {
      // Hermetic seed repos commit unsigned, so the captured
      // signature surfaces as status `N` with empty fingerprint —
      // exactly the data the consent prompt needs to render
      // "(unsigned)".
      PluginInstallPreview? captured;
      await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
        confirm: (preview) async {
          captured = preview;
          return true;
        },
      );

      expect(captured, isNotNull);
      expect(captured!.signature.status, 'N');
      expect(captured!.signature.fingerprint, isEmpty);
      expect(captured!.signature.isPresent, isFalse);
    });

    test(
      'install on unsigned commit leaves signatureFingerprint null',
      () async {
        final marker = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        expect(marker.signatureFingerprint, isNull);

        final reread = readMarker('${home.path}/plugins/${marker.id}')!;
        expect(reread.signatureFingerprint, isNull);
      },
    );

    test(
      'refresh throws PluginSignatureMismatch when pinned fp differs',
      () async {
        final marker = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );

        // Forge a pinned fingerprint on the marker so the next
        // refresh takes the mismatch branch instead of the
        // silent-upgrade one.
        writeMarker(
          '${home.path}/plugins/${marker.id}',
          marker.copyWith(signatureFingerprint: 'SHA256:fake-pinned-key'),
        );

        // Advance the upstream pin so refresh has *something* to do
        // (a no-op refresh returns early before the signature check).
        File(
          '${srcRepo.path}/plugin.nix',
        ).writeAsStringSync('# v2\n{ services.tailscale.enable = true; }\n');
        for (final args in [
          ['add', '-A'],
          ['commit', '-m', 'rotate'],
        ]) {
          final r = await testGit(args, workingDirectory: srcRepo.path);
          expect(r.exitCode, 0, reason: r.stderr.toString());
        }

        await expectLater(
          () => pluginService.refresh(marker.id, allowInsecure: true),
          throwsA(
            isA<PluginSignatureMismatch>()
                .having((e) => e.pluginId, 'pluginId', marker.id)
                .having((e) => e.expected, 'expected', 'SHA256:fake-pinned-key')
                .having((e) => e.actual, 'actual', isNull),
          ),
        );

        // Mismatch is hard-fail: marker stays untouched.
        final after = readMarker('${home.path}/plugins/${marker.id}')!;
        expect(after.rev, marker.rev);
        expect(after.signatureFingerprint, 'SHA256:fake-pinned-key');
      },
    );

    test(
      'refresh with no pinned fp adopts whatever the new commit has',
      () async {
        final marker = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        expect(marker.signatureFingerprint, isNull);

        File(
          '${srcRepo.path}/plugin.nix',
        ).writeAsStringSync('# v2\n{ services.tailscale.enable = true; }\n');
        for (final args in [
          ['add', '-A'],
          ['commit', '-m', 'advance'],
        ]) {
          final r = await testGit(args, workingDirectory: srcRepo.path);
          expect(r.exitCode, 0, reason: r.stderr.toString());
        }

        final refreshed = await pluginService.refresh(
          marker.id,
          allowInsecure: true,
        );
        expect(refreshed.signatureFingerprint, isNull);
        expect(refreshed.rev, isNot(marker.rev));
      },
    );

    test('refreshAll walks every active plugin', () async {
      final secondRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_second_',
      );
      try {
        await _seedPluginRepo(secondRepo.path, id: 'second', name: 'second');
        await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        await pluginService.install(
          'file://${secondRepo.path}',
          allowInsecure: true,
        );

        final result = await pluginService.refreshAll(allowInsecure: true);
        // Both plugins are at HEAD (just installed); refresh is a no-op.
        expect(result.advanced, isEmpty);
        expect(result.unchanged.length, 2);
        expect(result.failures, isEmpty);
        expect(result.skipped, isEmpty);
      } finally {
        secondRepo.deleteSync(recursive: true);
      }
    });

    test('pin flips autoUpdate to false; unpin flips it back', () async {
      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      expect(marker.autoUpdate, isTrue);

      final pinned = await pluginService.pin(marker.id);
      expect(pinned.autoUpdate, isFalse);

      // Persisted on disk.
      final reread = readMarker('${home.path}/plugins/${marker.id}')!;
      expect(reread.autoUpdate, isFalse);

      final unpinned = await pluginService.unpin(marker.id);
      expect(unpinned.autoUpdate, isTrue);
    });

    test('refreshAll skips pinned plugins when includePinned=false', () async {
      final secondRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_pinned_',
      );
      try {
        await _seedPluginRepo(secondRepo.path, id: 'second', name: 'second');
        final first = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        await pluginService.install(
          'file://${secondRepo.path}',
          allowInsecure: true,
        );

        await pluginService.pin(first.id);

        final result = await pluginService.refreshAll(
          allowInsecure: true,
          includePinned: false,
        );
        expect(result.advanced, isEmpty); // unchanged HEAD
        expect(result.unchanged.length, 1);
        expect(result.skipped.length, 1);
        expect(result.skipped.first.id, first.id);
      } finally {
        secondRepo.deleteSync(recursive: true);
      }
    });

    test('refreshAll keeps going when one plugin fails', () async {
      final secondRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_partial_',
      );
      final movedRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_moved_',
      );
      try {
        await _seedPluginRepo(secondRepo.path, id: 'good', name: 'good');
        final bad = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        await pluginService.install(
          'file://${secondRepo.path}',
          allowInsecure: true,
        );

        // Poison: move the first source repo so refresh's clone
        // fails for it.
        movedRepo.deleteSync(recursive: true);
        Directory(srcRepo.path).renameSync(movedRepo.path);

        final result = await pluginService.refreshAll(allowInsecure: true);
        expect(result.advanced, isEmpty); // unchanged HEAD on success
        expect(result.unchanged.length, 1);
        expect(result.failures.length, 1);
        expect(result.failures.first.plugin.id, bad.id);

        // Restore for setUp / tearDown's cleanup.
        movedRepo.renameSync(srcRepo.path);
      } finally {
        secondRepo.deleteSync(recursive: true);
        if (movedRepo.existsSync()) {
          movedRepo.deleteSync(recursive: true);
        }
      }
    });

    test('list hides disabled by default; surfaces them on flag', () async {
      final marker = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      await pluginService.disable(marker.id);

      final active = await pluginService.list();
      final all = await pluginService.list(includeDisabled: true);

      expect(active, isEmpty);
      expect(all.length, 1);
      expect(all.first.disabled, isTrue);
    });

    test(
      'install seeds app_configs.<id> from manifest config_schema defaults',
      () async {
        final withSchema = Directory.systemTemp.createTempSync(
          'nixblitz_plugin_schema_',
        );
        try {
          await _seedPluginRepo(
            withSchema.path,
            id: 'with-schema',
            name: 'with-schema',
            manifestOverride: {
              'manifest': {
                'schema_version': 2,
                'min_tui_version': 2,
                'name': 'with-schema',
              },
              'id': 'with-schema',
              'config_schema': {
                'id': 'with-schema',
                'label': 'With Schema',
                'fields': [
                  {
                    'type': 'bool',
                    'name': 'enabled',
                    'label': 'Enabled',
                    'default': true,
                  },
                  {
                    'type': 'string',
                    'name': 'alias',
                    'label': 'Alias',
                    'default': 'hello',
                  },
                ],
              },
            },
          );

          await pluginService.install(
            'file://${withSchema.path}',
            allowInsecure: true,
          );

          final cfg = await ConfigService(baseDir: home.path).readConfig();
          final block = cfg.appConfig('with-schema');
          expect(block['enabled'], true);
          expect(block['alias'], 'hello');
        } finally {
          withSchema.deleteSync(recursive: true);
        }
      },
    );

    test(
      'install forces enabled=true even when manifest defaults to false',
      () async {
        final disabledByDefault = Directory.systemTemp.createTempSync(
          'nixblitz_plugin_disabled_default_',
        );
        try {
          await _seedPluginRepo(
            disabledByDefault.path,
            id: 'opt-in',
            name: 'opt-in',
            manifestOverride: {
              'manifest': {
                'schema_version': 2,
                'min_tui_version': 2,
                'name': 'opt-in',
              },
              'id': 'opt-in',
              'config_schema': {
                'id': 'opt-in',
                'label': 'Opt-in plugin',
                'fields': [
                  {
                    'type': 'bool',
                    'name': 'enabled',
                    'label': 'Enabled',
                    // Plugin author defaulted to false for safety;
                    // the TUI's catalog "Install" action is the
                    // consent signal that overrides this.
                    'default': false,
                  },
                ],
              },
            },
          );

          await pluginService.install(
            'file://${disabledByDefault.path}',
            allowInsecure: true,
          );

          final cfg = await ConfigService(baseDir: home.path).readConfig();
          expect(cfg.appConfig('opt-in')['enabled'], true);
        } finally {
          disabledByDefault.deleteSync(recursive: true);
        }
      },
    );
  });

  group('PluginService.switchBranch', () {
    late Directory home;
    late Directory srcRepo;
    late PluginService pluginService;

    setUp(() async {
      home = Directory.systemTemp.createTempSync('nixblitz_switch_home_');
      srcRepo = Directory.systemTemp.createTempSync('nixblitz_switch_src_');
      await _seedBaseConfig(home.path);
      await _seedPluginRepo(srcRepo.path);
      pluginService = PluginService(baseDir: home.path);
    });

    tearDown(() {
      home.deleteSync(recursive: true);
      srcRepo.deleteSync(recursive: true);
    });

    /// Create a new branch in [repoPath]. If [manifestOverride] is
    /// provided, rewrites `plugin.json`; otherwise touches a `CHANNEL`
    /// file so the branch has a distinct rev. Always returns to `main`.
    Future<void> addBranch(
      String repoPath,
      String branch, {
      Map<String, dynamic>? manifestOverride,
      String? commitMessage,
    }) async {
      Future<void> run(List<String> args) async {
        final r = await testGit(args, workingDirectory: repoPath);
        if (r.exitCode != 0) {
          throw StateError('git ${args.join(" ")} failed: ${r.stderr}');
        }
      }

      await run(['checkout', '-b', branch]);
      if (manifestOverride != null) {
        File('$repoPath/plugin.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(manifestOverride),
        );
        await run(['add', 'plugin.json']);
        await run([
          'commit',
          '-m',
          commitMessage ?? 'manifest update on $branch',
        ]);
      } else {
        File('$repoPath/CHANNEL').writeAsStringSync(branch);
        await run(['add', 'CHANNEL']);
        await run(['commit', '-m', commitMessage ?? 'on $branch']);
      }
      await run(['checkout', 'main']);
    }

    test('happy path: switches from main to beta', () async {
      final initial = await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      await addBranch(srcRepo.path, 'beta');

      var confirmCalled = false;
      final switched = await pluginService.switchBranch(
        'tailscale',
        'beta',
        allowInsecure: true,
        confirm: (preview) async {
          confirmCalled = true;
          expect(preview.branch, 'beta');
          return true;
        },
      );

      expect(switched.branch, 'beta');
      expect(switched.rev, isNot(initial.rev));
      expect(confirmCalled, isTrue);

      // Marker on disk reflects new branch + rev.
      final reread = readMarker('${home.path}/plugins/tailscale')!;
      expect(reread.branch, 'beta');
      expect(reread.rev, switched.rev);

      // Canonical plugin files are present (the beta branch carries the
      // same plugin.json / plugin.nix, but a distinct rev proves the
      // re-clone happened).
      expect(
        File('${home.path}/plugins/tailscale/plugin.nix').existsSync(),
        isTrue,
      );
      expect(
        File('${home.path}/plugins/tailscale/plugin.json').existsSync(),
        isTrue,
      );
    });

    test(
      'no-op: same branch returns existing marker without consent call',
      () async {
        final initial = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );

        var confirmCalled = false;
        final result = await pluginService.switchBranch(
          'tailscale',
          'main',
          allowInsecure: true,
          confirm: (_) async {
            confirmCalled = true;
            return true;
          },
        );

        expect(result.rev, initial.rev);
        expect(result.branch, 'main');
        expect(confirmCalled, isFalse);
      },
    );

    test('pinned refusal: throws PluginPinnedException', () async {
      await pluginService.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      await pluginService.pin('tailscale');
      await addBranch(srcRepo.path, 'beta');

      await expectLater(
        () => pluginService.switchBranch(
          'tailscale',
          'beta',
          allowInsecure: true,
        ),
        throwsA(
          isA<PluginPinnedException>().having(
            (e) => e.pluginId,
            'pluginId',
            'tailscale',
          ),
        ),
      );
    });

    test(
      'consent cancel: throws PluginInstallCancelled; marker unchanged',
      () async {
        final initial = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        await addBranch(srcRepo.path, 'beta');

        await expectLater(
          () => pluginService.switchBranch(
            'tailscale',
            'beta',
            allowInsecure: true,
            confirm: (_) async => false,
          ),
          throwsA(isA<PluginInstallCancelled>()),
        );

        // Marker is unchanged — still on main at original rev.
        final after = readMarker('${home.path}/plugins/tailscale')!;
        expect(after.branch, 'main');
        expect(after.rev, initial.rev);
      },
    );

    test(
      'signature change accepted: operator confirmation clears old fingerprint',
      () async {
        final initial = await pluginService.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        expect(initial.signatureFingerprint, isNull);

        // Forge a pinned fingerprint to simulate a previously-signed
        // install, so the path through "existing fp set but new commit
        // is unsigned" is exercised.
        writeMarker(
          '${home.path}/plugins/${initial.id}',
          initial.copyWith(signatureFingerprint: 'SHA256:fake-stable-key'),
        );

        await addBranch(srcRepo.path, 'beta');

        // Confirm accepts the new (unsigned) commit.
        final switched = await pluginService.switchBranch(
          'tailscale',
          'beta',
          allowInsecure: true,
          confirm: (_) async => true,
        );

        // Unlike refresh (which would throw), the confirmed switch
        // clears the old fingerprint and adopts the new (null) one.
        expect(switched.signatureFingerprint, isNull);
        expect(switched.branch, 'beta');

        final reread = readMarker('${home.path}/plugins/tailscale')!;
        expect(reread.signatureFingerprint, isNull);
      },
    );
  });

  group('PluginService.install default-branch resolution (T8)', () {
    late Directory home;
    late PluginService pluginService;

    setUp(() async {
      home = Directory.systemTemp.createTempSync('nixblitz_install_default_');
      await _seedBaseConfig(home.path);
      pluginService = PluginService(baseDir: home.path);
    });

    tearDown(() {
      home.deleteSync(recursive: true);
    });

    /// Seed a plugin repo whose `main` HEAD carries a v5 manifest
    /// declaring `stable:default` (ref: stable) + `next` (ref:
    /// develop). The repo also creates `stable` and `develop` as
    /// real branches so a re-clone at either lands successfully.
    /// Callers can distinguish which ref the install pinned to by
    /// inspecting `marker.branch`.
    Future<Directory> seedRepoWithBranchesManifest({required String id}) async {
      final repo = Directory.systemTemp.createTempSync(
        'nixblitz_branch_manifest_',
      );
      final v5Manifest = {
        'manifest': {'schema_version': 5, 'min_tui_version': 2, 'name': id},
        'id': id,
        'branches': {
          'stable': {'ref': 'stable', 'default': true},
          'next': {'ref': 'develop'},
        },
      };
      // Initial seed on `main` — v5 manifest WITH a branches block.
      // The remote's HEAD is `main`. The resolution path reads this
      // manifest, sees the default points at `stable`, and re-clones
      // there.
      await _seedPluginRepo(
        repo.path,
        id: id,
        name: id,
        manifestOverride: v5Manifest,
      );

      Future<void> run(List<String> args) async {
        final r = await testGit(args, workingDirectory: repo.path);
        if (r.exitCode != 0) {
          throw StateError('git ${args.join(" ")} failed: ${r.stderr}');
        }
      }

      // Create `stable` and `develop` as real refs, each with the
      // same manifest but a distinct extra file so the resolved
      // pin-revs differ from `main`.
      await run(['checkout', '-b', 'stable']);
      File('${repo.path}/CHANNEL').writeAsStringSync('stable');
      await run(['add', 'CHANNEL']);
      await run(['commit', '-m', 'stable ref']);

      await run(['checkout', 'main']);
      await run(['checkout', '-b', 'develop']);
      File('${repo.path}/CHANNEL').writeAsStringSync('develop');
      await run(['add', 'CHANNEL']);
      await run(['commit', '-m', 'develop ref']);

      await run(['checkout', 'main']);
      return repo;
    }

    test(
      'install without --branch uses manifest.branches default:true',
      () async {
        final repo = await seedRepoWithBranchesManifest(id: 'with-default');
        try {
          final marker = await pluginService.install(
            'file://${repo.path}',
            allowInsecure: true,
          );
          // No --branch on the call → resolution consults the
          // manifest on the remote's HEAD. The default:true entry
          // points at ref `stable`, so the install re-clones there
          // and the marker pins `stable`.
          expect(marker.branch, 'stable');
          expect(marker.id, 'with-default');
        } finally {
          repo.deleteSync(recursive: true);
        }
      },
    );

    test('install with explicit branch overrides manifest default', () async {
      final repo = await seedRepoWithBranchesManifest(
        id: 'with-default-override',
      );
      try {
        final marker = await pluginService.install(
          'file://${repo.path}',
          branch: 'develop',
          allowInsecure: true,
        );
        expect(marker.branch, 'develop');
      } finally {
        repo.deleteSync(recursive: true);
      }
    });

    test(
      'install of plugin without branches block keeps existing behaviour',
      () async {
        final repo = Directory.systemTemp.createTempSync(
          'nixblitz_no_branches_',
        );
        try {
          // Plain schema_version 2 manifest — no branches block at all.
          await _seedPluginRepo(repo.path, id: 'no-branches', name: 'plain');
          final marker = await pluginService.install(
            'file://${repo.path}',
            allowInsecure: true,
          );
          // No branches block → fall through to remote's default
          // (the seed creates `main`).
          expect(marker.branch, 'main');
        } finally {
          repo.deleteSync(recursive: true);
        }
      },
    );
  });

  group('PluginUrl.parse', () {
    test('parses github: with owner/repo', () {
      final p = PluginUrl.parse('github:fusion44/nixblitz-tailscale');
      expect(p.canonical, 'github:fusion44/nixblitz-tailscale');
      expect(p.cloneUrl, 'https://github.com/fusion44/nixblitz-tailscale');
      expect(p.subdir, isNull);
      expect(p.insecure, isFalse);
    });

    test('parses github: with subdir', () {
      final p = PluginUrl.parse('github:fusion44/nixblitz-plugins/tailscale');
      expect(p.canonical, 'github:fusion44/nixblitz-plugins/tailscale');
      expect(p.cloneUrl, 'https://github.com/fusion44/nixblitz-plugins');
      expect(p.subdir, 'tailscale');
    });

    test('rejects github: missing repo', () {
      expect(
        () => PluginUrl.parse('github:fusion44'),
        throwsA(isA<FormatException>()),
      );
    });

    test('accepts explicit https://', () {
      final p = PluginUrl.parse(
        'https://forge.f44.fyi/f44/nixblitz-tailscale.git',
      );
      expect(p.cloneUrl, 'https://forge.f44.fyi/f44/nixblitz-tailscale.git');
    });

    test('refuses file:// without allowInsecure', () {
      expect(
        () => PluginUrl.parse('file:///tmp/plugin'),
        throwsA(isA<FormatException>()),
      );
    });

    test('accepts file:// with allowInsecure', () {
      final p = PluginUrl.parse('file:///tmp/plugin', allowInsecure: true);
      expect(p.insecure, isTrue);
    });

    test('accepts bare absolute path with --insecure', () {
      final p = PluginUrl.parse('/home/user/plugin', allowInsecure: true);
      expect(p.cloneUrl, 'file:///home/user/plugin');
      expect(p.insecure, isTrue);
    });

    test('refuses bare absolute path without --insecure', () {
      expect(
        () => PluginUrl.parse('/home/user/plugin'),
        throwsA(isA<FormatException>()),
      );
    });

    test('hints when file://~/... is used literally', () {
      expect(
        () => PluginUrl.parse('file://~/plugin', allowInsecure: true),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('did not expand'),
          ),
        ),
      );
    });

    test('deriveDirName strips .git from https URL', () {
      final p = PluginUrl.parse('https://forge.example/org/nixblitz-foo.git');
      expect(p.deriveDirName(), 'nixblitz-foo');
    });

    test('deriveDirName joins github subdir', () {
      final p = PluginUrl.parse('github:a/b/c');
      expect(p.deriveDirName(), 'a-b-c');
    });

    test('parses forgejo: with host/owner/repo', () {
      final p = PluginUrl.parse(
        'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins',
      );
      expect(
        p.canonical,
        'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins',
      );
      expect(p.cloneUrl, 'https://forge.f44.fyi/f44/nixblitz_official_plugins');
      expect(p.subdir, isNull);
      expect(p.deriveDirName(), 'f44-nixblitz_official_plugins');
    });

    test('parses forgejo: with subdir', () {
      final p = PluginUrl.parse(
        'forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/tailscale',
      );
      expect(p.subdir, 'tailscale');
      expect(p.deriveDirName(), 'f44-nixblitz_official_plugins-tailscale');
    });

    test('parses gitea: with host/owner/repo/subdir', () {
      final p = PluginUrl.parse('gitea:git.example.com/org/plugins/foo');
      expect(p.cloneUrl, 'https://git.example.com/org/plugins');
      expect(p.subdir, 'foo');
    });

    test('rejects forgejo: missing host', () {
      expect(
        () => PluginUrl.parse('forgejo:f44/nixblitz_official_plugins'),
        throwsA(isA<FormatException>()),
      );
    });

    test('applies --subdir on file:// URL', () {
      final p = PluginUrl.parse(
        'file:///tmp/plugins',
        allowInsecure: true,
        subdir: 'tailscale',
      );
      expect(p.canonical, 'file:///tmp/plugins?dir=tailscale');
      expect(p.cloneUrl, 'file:///tmp/plugins');
      expect(p.subdir, 'tailscale');
      expect(p.deriveDirName(), 'plugins-tailscale');
    });

    test('applies --subdir on github: URL without embedded subdir', () {
      final p = PluginUrl.parse(
        'github:fusion44/nixblitz_official_plugins',
        subdir: 'tailscale',
      );
      expect(
        p.canonical,
        'github:fusion44/nixblitz_official_plugins/tailscale',
      );
      expect(p.subdir, 'tailscale');
    });

    test('conflicting URL subdir + --subdir is an error', () {
      expect(
        () => PluginUrl.parse('github:a/b/c', subdir: 'd'),
        throwsA(isA<FormatException>()),
      );
    });

    test('--subdir matching URL subdir is a no-op', () {
      final p = PluginUrl.parse('github:a/b/c', subdir: 'c');
      expect(p.canonical, 'github:a/b/c');
      expect(p.subdir, 'c');
    });

    test('round-trips canonical URL with embedded ?dir=', () {
      final original = PluginUrl.parse(
        '/home/user/plugins',
        allowInsecure: true,
        subdir: 'tailscale',
      );
      expect(original.canonical, 'file:///home/user/plugins?dir=tailscale');

      final roundTripped = PluginUrl.parse(
        original.canonical,
        allowInsecure: true,
      );
      expect(roundTripped.canonical, original.canonical);
      expect(roundTripped.cloneUrl, 'file:///home/user/plugins');
      expect(roundTripped.subdir, 'tailscale');
    });
  });
}
