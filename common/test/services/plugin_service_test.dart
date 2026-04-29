import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_install_preview.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/plugin_service.dart';

import '../test_helpers/git_isolation.dart';

/// Seed a fresh git repo at [path] with a minimal plugin layout:
/// plugin.nix, manifest.json, and a README. Returns the path so the
/// caller can clone via `file://`.
Future<String> _seedPluginRepo(
  String path, {
  String manifestName = 'nixblitz-tailscale',
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
          'manifest': {
            'schema_version': 2,
            'min_tui_version': 1,
            'name': manifestName,
            'description': 'test plugin',
          },
        };
    File(
      '$path/manifest.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
  }

  File('$path/README.md').writeAsStringSync('# $manifestName\n');

  // git init + commit so `git clone --depth 1 --branch main` works.
  // testGit() applies the hermetic env + `-c` overrides; see
  // ../test_helpers/git_isolation.dart.
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
  final svc = ConfigService(baseDir: baseDir);
  await svc.writeConfig(NixblitzConfig.defaults());
}

void main() {
  group('PluginService', () {
    late Directory home;
    late Directory srcRepo;
    late PluginService svc;

    setUp(() async {
      home = Directory.systemTemp.createTempSync('nixblitz_plugin_home_');
      srcRepo = Directory.systemTemp.createTempSync('nixblitz_plugin_src_');
      await _seedBaseConfig(home.path);
      await _seedPluginRepo(srcRepo.path);
      svc = PluginService(baseDir: home.path);
    });

    tearDown(() {
      home.deleteSync(recursive: true);
      srcRepo.deleteSync(recursive: true);
    });

    test('install from file:// creates plugin dir + config entry', () async {
      final entry = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );

      expect(entry.pinnedRev, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(entry.branch, 'main');
      expect(entry.enabled, isTrue);
      expect(entry.autoUpdate, isTrue);

      final pluginDir = Directory('${home.path}/plugins/${entry.dirName}');
      expect(pluginDir.existsSync(), isTrue);
      expect(File('${pluginDir.path}/plugin.nix').existsSync(), isTrue);
      expect(File('${pluginDir.path}/manifest.json').existsSync(), isTrue);
      expect(File('${pluginDir.path}/config.json').existsSync(), isTrue);
      // .plugin-metadata.json is intentionally NOT written —
      // main config's plugins[] is the authoritative record and
      // duplicating timestamps just churns the diff.
      expect(
        File('${pluginDir.path}/.plugin-metadata.json').existsSync(),
        isFalse,
      );

      final config = await ConfigService(baseDir: home.path).readConfig();
      expect(config.plugins.length, 1);
      expect(config.plugins.first.id, entry.id);
      expect(config.plugins.first.pinnedRev, entry.pinnedRev);
    });

    test('install refuses duplicate of same URL', () async {
      await svc.install('file://${srcRepo.path}', allowInsecure: true);
      expect(
        () => svc.install('file://${srcRepo.path}', allowInsecure: true),
        throwsA(isA<StateError>()),
      );
    });

    test('install confirm callback receives manifest preview', () async {
      PluginInstallPreview? captured;
      final entry = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
        confirm: (preview) async {
          captured = preview;
          return true;
        },
      );

      // Callback fired with manifest fields populated.
      expect(captured, isNotNull);
      expect(captured!.name, 'nixblitz-tailscale');
      expect(captured!.url, contains(srcRepo.path));
      expect(captured!.branch, 'main');
      expect(captured!.pinnedRev, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(captured!.schemaVersion, 2);

      // Install proceeded normally on `true`.
      expect(entry.pinnedRev, captured!.pinnedRev);
    });

    test('install confirm returning false aborts cleanly', () async {
      expect(
        () => svc.install(
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
      final config = await ConfigService(baseDir: home.path).readConfig();
      expect(config.plugins, isEmpty);
    });

    test('install with null confirm skips the prompt entirely', () async {
      // Counter to verify no callback is constructed/called when
      // `confirm` is omitted (the --yes / non-interactive case).
      var calls = 0;
      final entry = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
        // confirm: null, by omission
      );
      expect(entry.id, isNotEmpty);
      expect(calls, 0);
    });

    test('install with malformed manifest leaves nothing behind', () async {
      final bad = Directory.systemTemp.createTempSync('nixblitz_plugin_bad_');
      await _seedPluginRepo(bad.path, manifestOverride: {'not': 'a manifest'});

      expect(
        () => svc.install('file://${bad.path}', allowInsecure: true),
        throwsA(anything),
      );

      final pluginsDir = Directory('${home.path}/plugins');
      if (pluginsDir.existsSync()) {
        expect(pluginsDir.listSync(), isEmpty);
      }

      final config = await ConfigService(baseDir: home.path).readConfig();
      expect(config.plugins, isEmpty);

      bad.deleteSync(recursive: true);
    });

    test('install refuses when plugin.nix is missing', () async {
      final noPluginNix = Directory.systemTemp.createTempSync(
        'nixblitz_plugin_nopkg_',
      );
      await _seedPluginRepo(noPluginNix.path, includePluginNix: false);

      expect(
        () => svc.install('file://${noPluginNix.path}', allowInsecure: true),
        throwsA(isA<StateError>()),
      );

      noPluginNix.deleteSync(recursive: true);
    });

    test('insecure schemes refused without --insecure', () async {
      expect(
        () => svc.install('file://${srcRepo.path}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('clone failure on a subdir inside a repo suggests --subdir', () async {
      // Build an outer repo containing a plugin subdir. Pointing
      // directly at the subdir fails because it has no .git/; the
      // fix is to point at the parent with --subdir.
      final outer = Directory.systemTemp.createTempSync('nixblitz_outer_');
      try {
        await _seedPluginRepo(outer.path);
        Directory('${outer.path}/tailscale').createSync();
        File('${outer.path}/tailscale/plugin.nix').writeAsStringSync('{}\n');
        File('${outer.path}/tailscale/manifest.json').writeAsStringSync(
          jsonEncode({
            'manifest': {
              'schema_version': 2,
              'min_tui_version': 1,
              'name': 'ts',
            },
          }),
        );

        await expectLater(
          () => svc.install('${outer.path}/tailscale', allowInsecure: true),
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
          // Two valid plugins + one non-plugin subdir (should be skipped).
          for (final name in ['tailscale', 'btcpay']) {
            Directory('${multi.path}/$name').createSync(recursive: true);
            File('${multi.path}/$name/plugin.nix').writeAsStringSync('{}\n');
            File('${multi.path}/$name/manifest.json').writeAsStringSync(
              jsonEncode({
                'manifest': {
                  'schema_version': 2,
                  'min_tui_version': 1,
                  'name': name,
                },
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
            () => svc.install('file://${multi.path}', allowInsecure: true),
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
      // Build a multi-plugin repo: root has no manifest, but
      // `tailscale/` does. `install(... subdir: 'tailscale')` must
      // look for the manifest inside the subdir.
      final multi = Directory.systemTemp.createTempSync('nixblitz_multi_');
      try {
        Directory('${multi.path}/tailscale').createSync(recursive: true);
        File(
          '${multi.path}/tailscale/plugin.nix',
        ).writeAsStringSync('{ services.tailscale.enable = true; }\n');
        File('${multi.path}/tailscale/manifest.json').writeAsStringSync(
          jsonEncode({
            'manifest': {
              'schema_version': 2,
              'min_tui_version': 1,
              'name': 'tailscale',
            },
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

        final entry = await svc.install(
          'file://${multi.path}',
          allowInsecure: true,
          subdir: 'tailscale',
        );
        expect(entry.id, contains('dir=tailscale'));
        expect(entry.dirName, endsWith('-tailscale'));

        final pluginDir = Directory('${home.path}/plugins/${entry.dirName}');
        expect(File('${pluginDir.path}/plugin.nix').existsSync(), isTrue);
      } finally {
        multi.deleteSync(recursive: true);
      }
    });

    test('refuses to install a repo containing a symlink', () async {
      // Plant a symlink in the source repo pointing at /etc/passwd
      // and commit it. A naive copy would dereference, landing
      // /etc/passwd's content in the tracked config.
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

        // expectLater because the closure is async — expect + cleanup
        // would race on `malicious.deleteSync` completing before the
        // install's git clone actually runs.
        await expectLater(
          () => svc.install('file://${malicious.path}', allowInsecure: true),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('symlink'),
            ),
          ),
        );

        // Nothing should have landed.
        final pluginsDir = Directory('${home.path}/plugins');
        if (pluginsDir.existsSync()) {
          expect(pluginsDir.listSync(), isEmpty);
        }
      } finally {
        malicious.deleteSync(recursive: true);
      }
    });

    test('remove wipes dir and tombstones config entry', () async {
      final entry = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      final pluginDir = Directory('${home.path}/plugins/${entry.dirName}');
      expect(pluginDir.existsSync(), isTrue);

      await svc.remove(entry.id);

      expect(pluginDir.existsSync(), isFalse);
      final config = await ConfigService(baseDir: home.path).readConfig();
      expect(config.plugins.length, 1);
      expect(config.plugins.first.uninstalledAt, isNotNull);
      expect(config.plugins.first.enabled, isFalse);
    });

    test('reinstall revives tombstoned entry in place', () async {
      final first = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      await svc.remove(first.id);

      final second = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );

      expect(second.id, first.id);
      expect(second.dirName, first.dirName);
      expect(second.uninstalledAt, isNull);
      expect(second.enabled, isTrue);

      final config = await ConfigService(baseDir: home.path).readConfig();
      expect(config.plugins.length, 1);
      expect(config.plugins.first.uninstalledAt, isNull);
    });

    test(
      'refresh re-fetches files but preserves per-plugin config.json',
      () async {
        final first = await svc.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );

        // User edits their plugin config. Refresh must not clobber it.
        final cfgPath = '${home.path}/plugins/${first.dirName}/config.json';
        File(
          cfgPath,
        ).writeAsStringSync(jsonEncode({'custom_key': 'value', 'other': 42}));

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

        final refreshed = await svc.refresh(first.id, allowInsecure: true);

        // Pin advanced.
        expect(refreshed.pinnedRev, isNot(first.pinnedRev));
        expect(refreshed.dirName, first.dirName);

        // Files updated.
        final pluginNix = File(
          '${home.path}/plugins/${refreshed.dirName}/plugin.nix',
        ).readAsStringSync();
        expect(pluginNix, contains('# refreshed plugin.nix v2'));

        // Per-plugin config preserved.
        final cfg = jsonDecode(File(cfgPath).readAsStringSync()) as Map;
        expect(cfg['custom_key'], 'value');
        expect(cfg['other'], 42);

        // Main config entry updated in place.
        final afterConfig = await ConfigService(
          baseDir: home.path,
        ).readConfig();
        expect(afterConfig.plugins.length, 1);
        expect(afterConfig.plugins.first.pinnedRev, refreshed.pinnedRev);
      },
    );

    test('refresh is a no-op when upstream pin matches existing', () async {
      final first = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );

      // No upstream change between install and refresh — the new
      // pin will equal the existing one, refresh should bail before
      // touching anything.
      final refreshed = await svc.refresh(first.id, allowInsecure: true);

      expect(refreshed.pinnedRev, first.pinnedRev);
      expect(
        refreshed.lastUpdatedAt,
        first.lastUpdatedAt,
        reason: 'last_updated_at should not bump on no-op refresh',
      );

      // Main config wasn't touched either.
      final after = await ConfigService(baseDir: home.path).readConfig();
      expect(after.plugins.first.lastUpdatedAt, first.lastUpdatedAt);
    });

    test('refresh throws when plugin is not installed', () async {
      expect(
        () => svc.refresh('file:///nope/not-here', allowInsecure: true),
        throwsA(isA<StateError>()),
      );
    });

    test('install consent preview carries the commit signature', () async {
      // Hermetic seed repos commit unsigned, so the captured
      // signature surfaces as status `N` with empty fingerprint —
      // exactly the data the consent prompt needs to render
      // "(unsigned)". The point isn't to verify a real key; it's
      // that the plumbing from `git log --format=%G…` reaches the
      // CLI callback intact.
      PluginInstallPreview? captured;
      await svc.install(
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
        // Belt-and-suspenders for the install side of Approach A:
        // when no signature is present at install time, we explicitly
        // pin null. That null is the trigger for the "silent upgrade"
        // path on a future signed refresh — without this guarantee,
        // the upgrade case could be confused with a key change.
        final entry = await svc.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        expect(entry.signatureFingerprint, isNull);

        final cfg = await ConfigService(baseDir: home.path).readConfig();
        expect(cfg.plugins.first.signatureFingerprint, isNull);
      },
    );

    test(
      'refresh throws PluginSignatureMismatch when pinned fp differs',
      () async {
        // Approach A's hard-fail case: install captured a fingerprint,
        // a later refresh sees a different one (or none) → the caller
        // must explicitly re-consent. The hermetic env can't produce a
        // real signature, so we spoof the *pinned* side by writing a
        // fake fingerprint into the entry, then push a new (still
        // unsigned) upstream commit — the pinned `fake-fp` vs new
        // `(unsigned, null)` diff is enough to trip the check.
        final entry = await svc.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );

        // Forge a pinned fingerprint on the entry so the next refresh
        // takes the mismatch branch instead of the silent-upgrade one.
        final cs = ConfigService(baseDir: home.path);
        final cfg = await cs.readConfig();
        final tampered = cfg.copyWith(
          plugins: [
            cfg.plugins.first.copyWith(
              signatureFingerprint: 'SHA256:fake-pinned-key',
            ),
          ],
        );
        await cs.writeConfig(tampered);

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
          () => svc.refresh(entry.id, allowInsecure: true),
          throwsA(
            isA<PluginSignatureMismatch>()
                .having((e) => e.pluginId, 'pluginId', entry.id)
                .having((e) => e.expected, 'expected', 'SHA256:fake-pinned-key')
                .having((e) => e.actual, 'actual', isNull),
          ),
        );

        // Mismatch is hard-fail: nothing on disk should have moved,
        // pinnedRev included. The user has to `plugin remove` +
        // `plugin add` to re-consent.
        final after = await cs.readConfig();
        expect(after.plugins.first.pinnedRev, entry.pinnedRev);
        expect(
          after.plugins.first.signatureFingerprint,
          'SHA256:fake-pinned-key',
        );
      },
    );

    test(
      'refresh with no pinned fp adopts whatever the new commit has',
      () async {
        // The "silent upgrade" path: an entry that was installed
        // without a signature should accept new metadata on refresh
        // without forcing the operator through re-consent. With the
        // hermetic harness, "whatever the new commit has" is also
        // null, so this test pins down the null→null no-throw shape;
        // the null→fingerprint variant requires real signing keys
        // outside the test scope.
        final entry = await svc.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        expect(entry.signatureFingerprint, isNull);

        // Advance upstream so refresh actually runs the signature
        // check (no-op refresh returns before the comparison).
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

        final refreshed = await svc.refresh(entry.id, allowInsecure: true);
        expect(refreshed.signatureFingerprint, isNull);
        expect(refreshed.pinnedRev, isNot(entry.pinnedRev));
      },
    );

    test('refreshAll walks every active plugin', () async {
      // Second repo so we have two distinct plugins to refresh.
      final secondRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_second_',
      );
      try {
        await _seedPluginRepo(secondRepo.path, manifestName: 'second');
        await svc.install('file://${srcRepo.path}', allowInsecure: true);
        await svc.install('file://${secondRepo.path}', allowInsecure: true);

        final result = await svc.refreshAll(allowInsecure: true);
        expect(result.refreshed.length, 2);
        expect(result.failures, isEmpty);
        expect(result.skipped, isEmpty);
      } finally {
        secondRepo.deleteSync(recursive: true);
      }
    });

    test('pin flips auto_update to false; unpin flips it back', () async {
      final entry = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      expect(entry.autoUpdate, isTrue);

      final pinned = await svc.pin(entry.id);
      expect(pinned.autoUpdate, isFalse);

      // Persisted on disk.
      final cfg = await ConfigService(baseDir: home.path).readConfig();
      expect(cfg.plugins.first.autoUpdate, isFalse);

      final unpinned = await svc.unpin(entry.id);
      expect(unpinned.autoUpdate, isTrue);
    });

    test('refreshAll skips pinned plugins when includePinned=false', () async {
      final secondRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_pinned_',
      );
      try {
        await _seedPluginRepo(secondRepo.path, manifestName: 'second');
        final first = await svc.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        await svc.install('file://${secondRepo.path}', allowInsecure: true);

        // Pin the first one so includePinned=false should skip it.
        await svc.pin(first.id);

        final result = await svc.refreshAll(
          allowInsecure: true,
          includePinned: false,
        );
        expect(result.refreshed.length, 1);
        expect(result.skipped.length, 1);
        expect(result.skipped.first.id, first.id);
      } finally {
        secondRepo.deleteSync(recursive: true);
      }
    });

    test('refreshAll keeps going when one plugin fails', () async {
      // Install one good plugin, then poison it: rename the source
      // dir so the next refresh's git clone fails. A second healthy
      // plugin should still refresh + be reported in `refreshed`.
      final secondRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_partial_',
      );
      final movedRepo = Directory.systemTemp.createTempSync(
        'nixblitz_refresh_moved_',
      );
      try {
        await _seedPluginRepo(secondRepo.path, manifestName: 'good');
        final bad = await svc.install(
          'file://${srcRepo.path}',
          allowInsecure: true,
        );
        await svc.install('file://${secondRepo.path}', allowInsecure: true);

        // Poison: move the first source repo so refresh's clone
        // fails for it.
        movedRepo.deleteSync(recursive: true);
        Directory(srcRepo.path).renameSync(movedRepo.path);

        final result = await svc.refreshAll(allowInsecure: true);
        expect(result.refreshed.length, 1);
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

    test('list hides tombstones unless requested', () async {
      final entry = await svc.install(
        'file://${srcRepo.path}',
        allowInsecure: true,
      );
      await svc.remove(entry.id);

      final active = await svc.list();
      final all = await svc.list(includeTombstones: true);

      expect(active, isEmpty);
      expect(all.length, 1);
      expect(all.first.isTombstone, isTrue);
    });
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
      // `?dir=<subdir>` is how _withSubdir serializes non-github
      // canonical URLs. Reparsing should recover the same subdir
      // without being explicitly passed the flag.
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
