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
    String? subdir,
  }) async {
    final parsed = PluginUrl.parse(
      rawUrl,
      allowInsecure: allowInsecure,
      subdir: subdir,
    );

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

      // If there's no manifest where we expected one, the repo is
      // likely a multi-plugin bundle — scan for candidates and list
      // them so the user can re-run with --subdir.
      if (!File('$pluginSourceDir/manifest.json').existsSync()) {
        if (parsed.subdir == null) {
          final candidates = _listPluginSubdirs(tmpDir.path);
          if (candidates.isEmpty) {
            throw StateError(
              'No plugin found in this repo: no manifest.json at the root '
              'and no immediate subdirectory contains one. '
              'Is this a NixBlitz plugin repo?',
            );
          }
          throw StateError(
            'Repo has no plugin at its root but contains '
            '${candidates.length} plugin${candidates.length == 1 ? '' : 's'} '
            'in subdirectories:\n'
            '${candidates.map((s) => '  - $s').join('\n')}\n'
            'Pick one with `--subdir <name>`.',
          );
        } else {
          throw StateError(
            'manifest.json not found at subdir `${parsed.subdir}` in the '
            'cloned repo.',
          );
        }
      }

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
      final stderr = (r.stderr as String).trim();
      final hint = _suggestLocalSubdir(url);
      throw StateError(
        'git clone failed (exit ${r.exitCode}): $stderr'
        '${hint == null ? '' : '\n\n$hint'}',
      );
    }
  }

  /// If [url] points at a local path that lives *inside* a git repo
  /// (rather than being the repo root itself), build a friendly hint
  /// showing the correct form. The common case: user runs
  /// `plugin add /path/to/repo/plugin-a --insecure`, which fails
  /// because /path/to/repo/plugin-a has no .git/. We walk up to
  /// /path/to/repo, find .git/, and suggest
  /// `/path/to/repo --subdir plugin-a`.
  String? _suggestLocalSubdir(String url) {
    String? fsPath;
    if (url.startsWith('file://')) {
      fsPath = url.substring('file://'.length);
    } else if (url.startsWith('/')) {
      fsPath = url;
    }
    if (fsPath == null) return null;
    // Strip any ?dir= we appended when subdir was set via flag.
    final q = fsPath.indexOf('?');
    if (q >= 0) fsPath = fsPath.substring(0, q);

    final segments = fsPath.split(Platform.pathSeparator);
    for (var i = segments.length - 1; i > 0; i--) {
      final candidate = segments.sublist(0, i).join(Platform.pathSeparator);
      if (candidate.isEmpty) continue;
      // `.git` is usually a directory but can be a file (worktrees, submodules).
      if (Directory('$candidate/.git').existsSync() ||
          File('$candidate/.git').existsSync()) {
        final subdir = segments.sublist(i).join('/');
        return 'hint: `$fsPath` sits inside the git repo at `$candidate`. '
            'Try: `plugin add $candidate --subdir $subdir --insecure`';
      }
    }
    return null;
  }

  /// List immediate subdirectory names of [repoDir] that look like
  /// NixBlitz plugins (contain both manifest.json and plugin.nix).
  /// Used to build a helpful "pick one with --subdir" error when a
  /// user points at a multi-plugin repo without specifying which
  /// plugin they want. Sorted for stable output.
  List<String> _listPluginSubdirs(String repoDir) {
    final result = <String>[];
    for (final entity in Directory(repoDir).listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      final hasManifest =
          File('${entity.path}/manifest.json').existsSync();
      final hasPluginNix =
          File('${entity.path}/plugin.nix').existsSync();
      if (hasManifest && hasPluginNix) {
        result.add(name);
      }
    }
    result.sort();
    return result;
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

  static PluginUrl parse(
    String raw, {
    bool allowInsecure = false,
    String? subdir,
  }) {
    final base = _parseBase(raw, allowInsecure: allowInsecure);
    if (subdir == null || subdir.isEmpty) return base;
    final normalized = subdir.replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return base;
    if (base.subdir != null) {
      if (base.subdir == normalized) return base;
      throw FormatException(
        'URL `$raw` already specifies subdir `${base.subdir}`; '
        'cannot combine with --subdir=$normalized.',
      );
    }
    return base._withSubdir(normalized);
  }

  static PluginUrl _parseBase(String raw, {required bool allowInsecure}) {
    if (raw.startsWith('github:')) {
      return _parseGithub(raw);
    }
    if (raw.startsWith('forgejo:')) {
      return _parseHostedGit(raw, 'forgejo:');
    }
    if (raw.startsWith('gitea:')) {
      return _parseHostedGit(raw, 'gitea:');
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
      'Accepted: github:owner/repo, forgejo:host/owner/repo, '
      'gitea:host/owner/repo, https://host/repo, or a bare '
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

  /// Shared parser for self-hosted shortcut schemes (forgejo:, gitea:)
  /// where the host must be specified because the instance isn't
  /// implicit. Shape: `<scheme>host/owner/repo[/subdir]`.
  static PluginUrl _parseHostedGit(String raw, String schemePrefix) {
    final path = raw.substring(schemePrefix.length);
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length < 3) {
      throw FormatException(
        'Invalid $schemePrefix URL `$raw`. '
        'Expected `${schemePrefix}host/owner/repo[/subdir]`.',
      );
    }
    final host = segments[0];
    final owner = segments[1];
    final repo = segments[2];
    final subdirParts = segments.sublist(3);
    final subdir = subdirParts.isEmpty ? null : subdirParts.join('/');
    final canonical = subdir == null
        ? '$schemePrefix$host/$owner/$repo'
        : '$schemePrefix$host/$owner/$repo/$subdir';
    return PluginUrl(
      canonical: canonical,
      cloneUrl: 'https://$host/$owner/$repo',
      subdir: subdir,
      insecure: false,
    );
  }

  /// Return a copy with the subdir set. Updates [canonical] using
  /// the scheme's native convention — path-form for `github:`
  /// (matches Nix flake URI syntax), `?dir=<subdir>` query-form
  /// otherwise. Precondition: this PluginUrl has no subdir set.
  PluginUrl _withSubdir(String sub) {
    final newCanonical = canonical.startsWith('github:')
        ? '$canonical/$sub'
        : '$canonical?dir=$sub';
    return PluginUrl(
      canonical: newCanonical,
      cloneUrl: cloneUrl,
      subdir: sub,
      insecure: insecure,
    );
  }

  /// Directory name for this plugin under `~/nixblitz/plugins/`.
  /// Not guaranteed unique — [PluginService] resolves collisions by
  /// appending a numeric suffix.
  String deriveDirName() {
    final base = _deriveRepoBaseName();
    if (subdir == null || subdir!.isEmpty) return base;
    return '$base-${subdir!.replaceAll("/", "-")}';
  }

  String _deriveRepoBaseName() {
    // Shortcut schemes: pull owner/repo out of the canonical path,
    // skipping the scheme and (for self-hosted) the host segment.
    for (final entry in const {
      'github:': 0, // owner at index 0 after scheme
      'forgejo:': 1, // host owns index 0, owner at index 1
      'gitea:': 1,
    }.entries) {
      final scheme = entry.key;
      final ownerIdx = entry.value;
      if (!canonical.startsWith(scheme)) continue;
      final rest = canonical.substring(scheme.length);
      final stripped = rest.contains('?')
          ? rest.substring(0, rest.indexOf('?'))
          : rest;
      final segs = stripped.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.length >= ownerIdx + 2) {
        return '${segs[ownerIdx]}-${segs[ownerIdx + 1]}';
      }
      return segs.join('-');
    }
    final uri = Uri.tryParse(cloneUrl);
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
