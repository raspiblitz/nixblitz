import 'dart:io';
import 'package:common/src/models/branch/branch_manifest.dart';
import 'package:common/src/services/embedded_templates.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/process_runner.dart';

class ScaffoldService {
  final String targetDir;

  ScaffoldService({required this.targetDir});

  /// Default on-disk location of the installer ISO's offline flake.lock.
  static const kOfflineLockPath = '/etc/nixblitz/offline-flake.lock';

  /// After scaffolding, copy the offline lock (present only on installer
  /// media) so the first eval resolves path-locked inputs offline.
  /// [offlineLockPath] is injectable for tests. Missing file → no-op.
  void copyOfflineLockIfPresent(
    String baseDir, {
    String offlineLockPath = kOfflineLockPath,
  }) {
    try {
      final src = File(offlineLockPath);
      if (!src.existsSync()) return;
      // NOT copySync: the source is nix-store-backed (mode 444) and Dart's
      // copySync preserves mode bits, leaving a read-only flake.lock that
      // every later re-lock (`nix flake update` in the update check, lock
      // promotion on apply) fails to rewrite with EACCES. Delete + write
      // fresh so the lock gets normal umask permissions.
      final dest = File('$baseDir/flake.lock');
      if (dest.existsSync()) dest.deleteSync();
      dest.writeAsBytesSync(src.readAsBytesSync());
      LogService.info(
        'scaffold: offline flake.lock copied from $offlineLockPath',
      );
    } catch (e, st) {
      LogService.error(
        'scaffold: offline lock copy failed (continuing)',
        e,
        st,
      );
    }
  }

  bool needsScaffold() => !Directory(targetDir).existsSync();

  /// Write all embedded templates to the target directory.
  ///
  /// If [manifest] is supplied, the `flake.nix` template is rewritten to
  /// pin the `nixblitz` input's URL to a ref resolved from
  /// [nixblitzBranchField] against the manifest (see [resolveNixblitzRef]).
  /// When [manifest] is null, the embedded `flake.nix` is written
  /// verbatim — kept for callers that don't yet have the manifest
  /// available.
  Future<void> scaffold({
    BranchManifest? manifest,
    String? nixblitzBranchField,
  }) async {
    if (!needsScaffold()) {
      LogService.info('Scaffold skipped: $targetDir already exists');
      return;
    }

    LogService.info('Scaffolding $targetDir from embedded templates');
    final templates = _resolveTemplates(
      manifest: manifest,
      nixblitzBranchField: nixblitzBranchField,
    );

    for (final entry in templates.entries) {
      final filePath = '$targetDir/${entry.key}';
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }

    LogService.info('Scaffold complete: ${templates.length} files written');
  }

  /// Rewrite all embedded templates into the target directory, overwriting
  /// existing files. Intended for template refresh after a TUI upgrade or
  /// from the Update view's "Refresh Nix templates" action. Synchronous —
  /// safe to call from TUI startup without awaiting. Returns the number of
  /// files written.
  ///
  /// Accepts the same optional [manifest] + [nixblitzBranchField] pair as
  /// [scaffold]; supplying them keeps the operator's nixblitz-branch pin
  /// on disk through template refreshes.
  ///
  /// [offlineLockPath] overrides [kOfflineLockPath] for the post-write
  /// offline-lock copy; injectable for tests.
  int refreshTemplatesSync({
    BranchManifest? manifest,
    String? nixblitzBranchField,
    String offlineLockPath = kOfflineLockPath,
  }) {
    final templates = _resolveTemplates(
      manifest: manifest,
      nixblitzBranchField: nixblitzBranchField,
    );
    for (final entry in templates.entries) {
      final file = File('$targetDir/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    LogService.info(
      'refreshTemplates: wrote ${templates.length} files to $targetDir',
    );
    copyOfflineLockIfPresent(targetDir, offlineLockPath: offlineLockPath);
    return templates.length;
  }

  /// Remove [targetDir] entirely, so the installer can re-scaffold onto
  /// a freshly-picked disk/platform profile without stale files from a
  /// previous run. Falls back to `sudo -n rm -rf` because a prior
  /// generation may have left read-only files (e.g. nix-store-backed)
  /// that a plain `rm` can't remove. No-op when the directory is absent.
  void clearTargetSync() {
    if (!Directory(targetDir).existsSync()) return;
    final r = runCheckedSync('rm', ['-rf', targetDir]);
    if (!r.ok) {
      LogService.warn('clearTarget: rm -rf failed, retrying with sudo');
      runCheckedSync('sudo', ['-n', 'rm', '-rf', targetDir]);
    }
  }

  /// Generate `hardware-configuration.nix` from the live system and
  /// write it into [targetDir], stripped of its `fileSystems` /
  /// `swapDevices` blocks (disko owns those on a NixBlitz node). Returns
  /// true on success; false when `nixos-generate-config` failed (the
  /// error is logged by the caller's context).
  bool writeStrippedHardwareConfigSync() {
    final r = runCheckedSync('nixos-generate-config', [
      '--show-hardware-config',
    ]);
    if (!r.ok) return false;
    final stripped = stripHardwareConfigMounts(r.stdout);
    File('$targetDir/hardware-configuration.nix').writeAsStringSync(stripped);
    return true;
  }

  /// Returns the embedded template map with `flake.nix` optionally
  /// rewritten so the `nixblitz` input pins the operator's chosen branch.
  Map<String, String> _resolveTemplates({
    required BranchManifest? manifest,
    required String? nixblitzBranchField,
  }) {
    final templates = Map<String, String>.from(EmbeddedTemplates.getAll());
    if (manifest == null) return templates;

    final flake = templates['flake.nix'];
    if (flake == null) {
      LogService.warn(
        'scaffold: flake.nix missing from embedded templates; '
        'skipping nixblitz ref substitution',
      );
      return templates;
    }

    final (resolvedRef, warning) = resolveNixblitzRef(
      nixblitzBranchField,
      manifest,
    );
    if (warning != null) {
      LogService.warn('scaffold: $warning');
    }
    templates['flake.nix'] = substituteNixblitzRef(flake, resolvedRef);
    return templates;
  }
}

/// Resolves the operator's `nixblitz_branch` config field against the
/// embedded [BranchManifest]. Returns a record of `(ref, warning)`.
///
/// - `null` field → manifest's `default:true` entry's ref
/// - declared key (e.g. `stable`) → that entry's ref
/// - `custom:<ref>` → literal `<ref>`
/// - unknown declared key → fall back to default, return warning so the
///   caller can surface the drift (operator pinned to a branch the
///   current `branches.json` no longer declares)
///
/// Throws [StateError] when the operator's pick can't be resolved and
/// the manifest has no `default:true` entry — the operator-flake can't
/// be scaffolded without a ref, so the caller must surface this.
(String, String?) resolveNixblitzRef(
  String? configField,
  BranchManifest manifest,
) {
  if (configField == null) {
    final dk = manifest.defaultKey;
    if (dk == null) {
      throw StateError(
        'branches.json declares no default:true entry; cannot resolve '
        'null nixblitz_branch config field',
      );
    }
    return (manifest.branches[dk]!.ref, null);
  }
  if (configField.startsWith('custom:')) {
    return (configField.substring('custom:'.length), null);
  }
  final entry = manifest.branches[configField];
  if (entry != null) {
    return (entry.ref, null);
  }
  // Operator's chosen key no longer exists in the current manifest.
  final dk = manifest.defaultKey;
  if (dk == null) {
    throw StateError(
      'operator pinned to "$configField" which no longer exists, '
      'and the current branches.json declares no default — manual '
      'flake.nix edit required',
    );
  }
  return (
    manifest.branches[dk]!.ref,
    'operator-pinned branch "$configField" is no longer declared; '
        'falling back to default "$dk"',
  );
}

/// Rewrites the `nixblitz` input's `url` attribute in a `flake.nix`
/// template to include `?ref=<ref>`. Replaces any existing `?ref=`
/// in place; appends if absent. Throws [StateError] if the url is
/// not found.
///
/// Handles the nested-block style used in `templates/flake.nix`:
///
///     nixblitz = {
///       url = "git+https://forge.f44.fyi/f44/nixblitz_ng";
///       inputs.nixpkgs.follows = "nixpkgs";
///     };
String substituteNixblitzRef(String template, String ref) {
  // Group 1: `nixblitz = { ... url = "`
  // Group 2: url value (no quotes)
  // Group 3: closing `"`
  final urlPattern = RegExp(
    r'(nixblitz\s*=\s*\{[\s\S]*?url\s*=\s*")([^"]*?)(")',
    multiLine: true,
  );
  final match = urlPattern.firstMatch(template);
  if (match == null) {
    throw StateError(
      'nixblitz input url attribute not found in flake.nix template',
    );
  }
  final url = match.group(2)!;
  // Strip any existing ?ref=… or &ref=… (preserve other query params).
  var cleanUrl = url.replaceAll(RegExp(r'\?ref=[^&"]*&?'), '?');
  cleanUrl = cleanUrl.replaceAll(RegExp(r'&ref=[^&"]*'), '');
  // Tidy a trailing `?` or `&` from the strip.
  cleanUrl = cleanUrl.replaceAll(RegExp(r'[?&]$'), '');
  final newUrl = cleanUrl.contains('?')
      ? '$cleanUrl&ref=$ref'
      : '$cleanUrl?ref=$ref';
  return template.replaceRange(
    match.start,
    match.end,
    '${match.group(1)}$newUrl${match.group(3)}',
  );
}

/// Strip the `fileSystems.*` and `swapDevices` blocks out of a
/// `nixos-generate-config --show-hardware-config` dump. disko manages
/// mounts + swap on a NixBlitz node, so leaving the generated ones in
/// would double-declare them. Pure string transform — unit-testable
/// without touching the system.
String stripHardwareConfigMounts(String hwConfig) {
  final lines = hwConfig.split('\n');
  final result = <String>[];
  var skipping = false;
  var braceDepth = 0;

  for (final line in lines) {
    final trimmed = line.trimLeft();

    if (!skipping) {
      // Detect start of blocks to skip
      if (trimmed.startsWith('fileSystems.') ||
          trimmed.startsWith('fileSystems ') ||
          trimmed.startsWith('swapDevices')) {
        skipping = true;
        braceDepth = 0;

        // Track braces/brackets on this line
        for (final c in line.codeUnits) {
          if (c == 123 || c == 91) braceDepth++; // { or [
          if (c == 125 || c == 93) braceDepth--; // } or ]
        }

        // Check if the statement ends with ;
        if (trimmed.endsWith(';')) {
          skipping = false;
        }
        continue;
      }
      result.add(line);
    } else {
      // We're inside a block — track depth
      for (final c in line.codeUnits) {
        if (c == 123 || c == 91) braceDepth++;
        if (c == 125 || c == 93) braceDepth--;
      }

      // Block ends when we hit the closing ; at depth 0
      if (trimmed.endsWith(';') && braceDepth <= 0) {
        skipping = false;
      }
    }
  }

  return result.join('\n');
}
