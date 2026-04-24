import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/models/plugin/plugin_entry.dart';
import 'package:common/src/models/plugin/plugin_manifest.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/log_service.dart';

/// Manages installed plugins under `~/nixblitz/plugins/<dirName>/`
/// and the matching `plugins[]` entries in `~/nixblitz/config.json`.
///
/// Phase 1 surface: URL parsing, clone-to-tmpdir, manifest
/// validation, install (with collision-resolved dirName, D5), soft
/// delete (D4), list. No update / pin / unpin yet (Phase 5).
///
/// Side effects land in the working tree — no git commits here.
/// The user's next Apply captures every change via `git add -A`.
class PluginService {
  final String baseDir;
  final ConfigService configService;

  /// Fixed clone timeout. Remote repos that misbehave shouldn't hang
  /// the TUI — 60 s is generous for a shallow clone.
  static const _cloneTimeout = Duration(seconds: 60);

  PluginService({required this.baseDir})
      : configService = ConfigService(baseDir: baseDir);

  String get pluginsDir => '$baseDir/plugins';

  /// Install a plugin from [rawUrl] (D5 schemes). Clones to a
  /// tmpdir, validates the manifest, then copies plugin files into
  /// `plugins/<dirName>/` and appends a [PluginEntry] to the main
  /// config. Reviving a tombstoned entry (D4) is idempotent.
  ///
  /// [allowInsecure] must be true for `file://`, `http://`, or
  /// `ssh://` URLs (D9).
  Future<PluginEntry> install(
    String rawUrl, {
    String branch = 'main',
    bool allowInsecure = false,
  }) async {
    final parsed = PluginUrl.parse(rawUrl, allowInsecure: allowInsecure);

    final config = configService.configExists()
        ? await configService.readConfig()
        : NixblitzConfig.defaults();

    final activeExisting = config.plugins.firstWhereOrNull(
      (p) => p.id == parsed.canonical && p.uninstalledAt == null,
    );
    if (activeExisting != null) {
      throw StateError('Plugin already installed: ${parsed.canonical}');
    }

    final tmpDir = await Directory.systemTemp.createTemp('nixblitz-plugin-');
    Directory? targetDir;
    try {
      await _gitClone(parsed.cloneUrl, branch, tmpDir.path);
      final pinnedRev = await _gitRevParseHead(tmpDir.path);

      // Safety: the source repo must not contain symlinks. A
      // malicious plugin could ship plugin.nix as a symlink to e.g.
      // /etc/shadow; `File.copySync` follows links, which would
      // land sensitive content in the tracked config repo. Phase 1
      // plugins have no legitimate need for symlinks, so reject
      // outright with a clear error.
      _rejectSymlinks(tmpDir.path);

      final pluginSourceDir = parsed.subdir == null
          ? tmpDir.path
          : '${tmpDir.path}/${parsed.subdir}';

      final manifest = _readManifest(pluginSourceDir);
      _requirePluginNix(pluginSourceDir);

      // Revival of a tombstoned entry (D4) reuses the original
      // dirName; only fresh installs collision-resolve against the
      // existing set.
      final tombstone = config.plugins.firstWhereOrNull(
        (p) => p.id == parsed.canonical && p.uninstalledAt != null,
      );
      final dirName = tombstone?.dirName ??
          _resolveDirName(config.plugins, parsed.deriveDirName());

      final pluginsDirObj = Directory(pluginsDir);
      if (!pluginsDirObj.existsSync()) {
        pluginsDirObj.createSync(recursive: true);
      }
      targetDir = Directory('$pluginsDir/$dirName');
      if (targetDir.existsSync()) {
        // Should not happen after _resolveDirName; defend anyway.
        throw StateError('target dir exists: ${targetDir.path}');
      }
      targetDir.createSync();

      for (final name in const [
        'plugin.nix',
        'manifest.json',
        'README.md',
        'LICENSE',
      ]) {
        final src = File('$pluginSourceDir/$name');
        if (src.existsSync()) {
          src.copySync('${targetDir.path}/$name');
        }
      }

      File('${targetDir.path}/config.json').writeAsStringSync('{}\n');

      final now = DateTime.now().toUtc();
      final entry = PluginEntry(
        id: parsed.canonical,
        url: parsed.canonical,
        branch: branch,
        pinnedRev: pinnedRev,
        dirName: dirName,
        installedAt: now,
        lastUpdatedAt: now,
      );

      File('${targetDir.path}/.plugin-metadata.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(entry.toJson())}\n',
      );

      // Mark the new plugin files as intent-to-add (git add -N) so
      // the Apply view's `git diff` renders them as new-file
      // additions instead of hiding them as untracked. The files
      // remain unstaged in content; Apply's later `git add -A` still
      // stages them properly. Best-effort — a git-less baseDir
      // (shouldn't happen in practice) doesn't block install.
      await _gitIntentToAdd(targetDir.path);

      final updatedPlugins = List<PluginEntry>.from(config.plugins);
      final tombstoneIdx = updatedPlugins.indexWhere(
        (p) => p.id == parsed.canonical,
      );
      if (tombstoneIdx >= 0) {
        updatedPlugins[tombstoneIdx] = entry;
      } else {
        updatedPlugins.add(entry);
      }
      await configService.writeConfig(
        config.copyWith(plugins: updatedPlugins),
      );

      LogService.info(
        'PluginService: installed ${parsed.canonical} '
        '($pinnedRev, dir=$dirName, schema=${manifest.schemaVersion})',
      );
      return entry;
    } catch (e, st) {
      // Roll back a half-created target dir so the user's next
      // Apply review isn't littered with partial state.
      if (targetDir != null && targetDir.existsSync()) {
        try {
          targetDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      LogService.error('PluginService.install failed for $rawUrl', e, st);
      rethrow;
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Soft-delete: wipe the plugin directory and mark the row as
  /// tombstoned (D4). Reinstall later with [install] revives it.
  Future<void> remove(String id) async {
    final config = await configService.readConfig();
    final idx = config.plugins.indexWhere(
      (p) => p.id == id && p.uninstalledAt == null,
    );
    if (idx < 0) {
      throw StateError('Plugin not installed: $id');
    }
    final entry = config.plugins[idx];

    final dir = Directory('$pluginsDir/${entry.dirName}');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }

    final updated = List<PluginEntry>.from(config.plugins);
    updated[idx] = entry.copyWith(
      enabled: false,
      uninstalledAt: DateTime.now().toUtc(),
    );
    await configService.writeConfig(config.copyWith(plugins: updated));
    LogService.info('PluginService: removed $id (tombstoned)');
  }

  /// Active plugins by default; pass [includeTombstones] for the full
  /// audit trail.
  Future<List<PluginEntry>> list({bool includeTombstones = false}) async {
    if (!configService.configExists()) return const [];
    final config = await configService.readConfig();
    if (includeTombstones) return config.plugins;
    return config.plugins.where((p) => p.uninstalledAt == null).toList();
  }

  // ── private ──────────────────────────────────────────────────

  Future<void> _gitClone(String url, String branch, String target) async {
    final r = await Process.run(
      'git',
      [
        'clone',
        '--depth', '1',
        '--branch', branch,
        '--no-recurse-submodules',
        url,
        target,
      ],
      environment: const {'GIT_TERMINAL_PROMPT': '0'},
    ).timeout(_cloneTimeout);
    if (r.exitCode != 0) {
      throw StateError(
        'git clone failed (exit ${r.exitCode}): ${(r.stderr as String).trim()}',
      );
    }
  }

  /// `git add -N` (intent-to-add) on everything under [path]. Makes
  /// brand-new files visible in `git diff` as additions. Non-fatal:
  /// a non-git baseDir just logs a warning.
  Future<void> _gitIntentToAdd(String path) async {
    try {
      final r = await Process.run(
        'git',
        ['add', '-N', path],
        workingDirectory: baseDir,
      );
      if (r.exitCode != 0) {
        LogService.warn(
          'PluginService: git add -N failed '
          '(${r.exitCode}): ${(r.stderr as String).trim()}',
        );
      }
    } catch (e) {
      LogService.warn('PluginService: git add -N threw: $e');
    }
  }

  /// Walk the cloned tree and throw if any entry is a symlink.
  /// Uses `followLinks: false` so symlinks come back as `Link`
  /// entities instead of being transparently resolved.
  void _rejectSymlinks(String dir) {
    for (final entity in Directory(dir).listSync(
      recursive: true,
      followLinks: false,
    )) {
      // Skip the .git internals — Dart doesn't descend into them
      // automatically because of the default list behavior; we
      // check anyway to avoid flagging any internal link git uses.
      if (entity.path.contains('${Platform.pathSeparator}.git${Platform.pathSeparator}')) {
        continue;
      }
      if (entity is Link) {
        final rel = entity.path.substring(dir.length);
        throw StateError(
          'Plugin repo contains a symlink at `$rel`; refusing to install. '
          'Plugins must contain only regular files (no symlinks).',
        );
      }
    }
  }

  Future<String> _gitRevParseHead(String repoDir) async {
    final r = await Process.run(
      'git',
      ['rev-parse', 'HEAD'],
      workingDirectory: repoDir,
    );
    if (r.exitCode != 0) {
      throw StateError(
        'git rev-parse failed: ${(r.stderr as String).trim()}',
      );
    }
    return (r.stdout as String).trim();
  }

  PluginManifest _readManifest(String dir) {
    final f = File('$dir/manifest.json');
    if (!f.existsSync()) {
      throw StateError('manifest.json not found at $dir');
    }
    return PluginManifest.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    );
  }

  void _requirePluginNix(String dir) {
    if (!File('$dir/plugin.nix').existsSync()) {
      throw StateError('plugin.nix not found at $dir');
    }
  }

  /// Ensure dirName uniqueness across active + tombstoned entries
  /// (tombstones still occupy their slot conceptually — reinstall
  /// reuses it).
  String _resolveDirName(List<PluginEntry> existing, String base) {
    final claimed = existing.map((p) => p.dirName).toSet();
    if (!claimed.contains(base)) return base;
    var i = 2;
    while (claimed.contains('$base-$i')) {
      i++;
    }
    return '$base-$i';
  }
}

/// Parsed plugin URL. Handles the D9 accepted schemes and the D8
/// subdirectory convention.
class PluginUrl {
  /// Normalized URL used as the D5 canonical ID.
  final String canonical;

  /// Real URL to pass to `git clone`.
  final String cloneUrl;

  /// Subdirectory inside the cloned repo that holds the plugin
  /// (manifest.json + plugin.nix). Null means the repo root is the
  /// plugin root.
  final String? subdir;

  /// True for schemes that bypass the default HTTPS-only posture.
  final bool insecure;

  const PluginUrl({
    required this.canonical,
    required this.cloneUrl,
    this.subdir,
    required this.insecure,
  });

  static PluginUrl parse(String raw, {bool allowInsecure = false}) {
    if (raw.startsWith('github:')) {
      return _parseGithub(raw);
    }
    if (raw.startsWith('https://')) {
      return PluginUrl(canonical: raw, cloneUrl: raw, insecure: false);
    }
    // Bare absolute local path — equivalent to file:// but saves the
    // user from worrying about URL syntax. Shell-expanded `~/...`
    // lands here.
    if (raw.startsWith('/')) {
      if (!allowInsecure) {
        throw FormatException(
          '`$raw` is a local path. Pass --insecure to opt in.',
        );
      }
      return PluginUrl(
        canonical: 'file://$raw',
        cloneUrl: 'file://$raw',
        insecure: true,
      );
    }
    if (raw.startsWith('file://') ||
        raw.startsWith('http://') ||
        raw.startsWith('ssh://')) {
      // `file://~/...` is a common footgun: the shell doesn't expand
      // `~` when it's inside a URL, so git reads `~` as the hostname
      // and fails with a confusing "does not appear to be a git
      // repository" message. Catch it here with a clearer hint.
      if (raw.startsWith('file://~')) {
        throw FormatException(
          '`$raw` contains `~` that the shell did not expand '
          '(because it sits inside a URL). Either drop the `file://` '
          'prefix so the shell expands `~/...`, or substitute your '
          'home path explicitly (e.g. file:///home/you/...).',
        );
      }
      if (!allowInsecure) {
        throw FormatException(
          '`$raw` uses an insecure scheme. Pass --insecure to override.',
        );
      }
      return PluginUrl(canonical: raw, cloneUrl: raw, insecure: true);
    }
    throw FormatException(
      'Unsupported URL in `$raw`. '
      'Accepted: github:owner/repo, https://host/repo, or a bare '
      'absolute path (/home/you/...). '
      'file://, http://, ssh:// require --insecure.',
    );
  }

  static PluginUrl _parseGithub(String raw) {
    final path = raw.substring('github:'.length);
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) {
      throw FormatException(
        'Invalid github URL `$raw`. Expected `github:owner/repo[/subdir]`.',
      );
    }
    final owner = segments[0];
    final repo = segments[1];
    final subdirParts = segments.sublist(2);
    final subdir = subdirParts.isEmpty ? null : subdirParts.join('/');
    final canonical = subdir == null
        ? 'github:$owner/$repo'
        : 'github:$owner/$repo/$subdir';
    return PluginUrl(
      canonical: canonical,
      cloneUrl: 'https://github.com/$owner/$repo',
      subdir: subdir,
      insecure: false,
    );
  }

  /// Directory name for this plugin under `~/nixblitz/plugins/`.
  /// Not guaranteed unique — [PluginService] resolves collisions by
  /// appending a numeric suffix.
  String deriveDirName() {
    if (canonical.startsWith('github:')) {
      return canonical.substring('github:'.length).replaceAll('/', '-');
    }
    final uri = Uri.tryParse(canonical);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      var last = uri.pathSegments.last;
      if (last.endsWith('.git')) {
        last = last.substring(0, last.length - 4);
      }
      if (last.isNotEmpty) return _sanitize(last);
    }
    return 'plugin';
  }

  static String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
