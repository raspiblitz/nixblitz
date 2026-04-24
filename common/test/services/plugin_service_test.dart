import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/plugin_service.dart';

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
    File('$path/plugin.nix').writeAsStringSync(
      '{ services.tailscale.enable = true; }\n',
    );
  }

  if (includeManifest) {
    final manifest = manifestOverride ??
        {
          'manifest': {
            'schema_version': 1,
            'min_tui_version': 1,
            'name': manifestName,
            'description': 'test plugin',
          },
        };
    File('$path/manifest.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  File('$path/README.md').writeAsStringSync('# $manifestName\n');

  // git init + commit so `git clone --depth 1 --branch main` works.
  Future<void> run(List<String> args) async {
    final r = await Process.run(
      'git',
      args,
      workingDirectory: path,
      environment: {
        'GIT_AUTHOR_NAME': 'test',
        'GIT_AUTHOR_EMAIL': 'test@example.com',
        'GIT_COMMITTER_NAME': 'test',
        'GIT_COMMITTER_EMAIL': 'test@example.com',
      },
    );
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
      expect(File('${pluginDir.path}/.plugin-metadata.json').existsSync(), isTrue);

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

    test('install with malformed manifest leaves nothing behind', () async {
      final bad = Directory.systemTemp.createTempSync('nixblitz_plugin_bad_');
      await _seedPluginRepo(
        bad.path,
        manifestOverride: {'not': 'a manifest'},
      );

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
        () => svc.install(
          'file://${noPluginNix.path}',
          allowInsecure: true,
        ),
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
        final env = {
          'GIT_AUTHOR_NAME': 't',
          'GIT_AUTHOR_EMAIL': 't@t',
          'GIT_COMMITTER_NAME': 't',
          'GIT_COMMITTER_EMAIL': 't@t',
        };
        final addRes = await Process.run(
          'git',
          ['add', '-A'],
          workingDirectory: malicious.path,
          environment: env,
        );
        expect(addRes.exitCode, 0, reason: 'git add failed: ${addRes.stderr}');
        final commitRes = await Process.run(
          'git',
          ['commit', '-m', 'add symlink'],
          workingDirectory: malicious.path,
          environment: env,
        );
        expect(
          commitRes.exitCode,
          0,
          reason: 'git commit failed: ${commitRes.stderr}',
        );

        // expectLater because the closure is async — expect + cleanup
        // would race on `malicious.deleteSync` completing before the
        // install's git clone actually runs.
        await expectLater(
          () => svc.install(
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
      final p = PluginUrl.parse(
        'github:fusion44/nixblitz-plugins/tailscale',
      );
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
      final p = PluginUrl.parse(
        'file:///tmp/plugin',
        allowInsecure: true,
      );
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
        () => PluginUrl.parse(
          'file://~/plugin',
          allowInsecure: true,
        ),
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
      final p = PluginUrl.parse(
        'https://forge.example/org/nixblitz-foo.git',
      );
      expect(p.deriveDirName(), 'nixblitz-foo');
    });

    test('deriveDirName joins github subdir', () {
      final p = PluginUrl.parse('github:a/b/c');
      expect(p.deriveDirName(), 'a-b-c');
    });
  });
}
