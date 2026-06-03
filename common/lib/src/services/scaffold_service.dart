import 'dart:io';
import 'package:common/src/models/branch/branch_manifest.dart';
import 'package:common/src/services/embedded_templates.dart';
import 'package:common/src/services/log_service.dart';

class ScaffoldService {
  final String targetDir;

  ScaffoldService({required this.targetDir});

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
  int refreshTemplatesSync({
    BranchManifest? manifest,
    String? nixblitzBranchField,
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
    return templates.length;
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
