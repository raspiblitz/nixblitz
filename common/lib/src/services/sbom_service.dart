import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/sbom_change.dart';
import 'package:common/src/services/log_service.dart';

/// Generates + reads + diffs CycloneDX SBOMs for the node's system closure.
/// Generation shells out to `sbomnix`; reading/diffing are pure so they unit-
/// test without the tool. See
/// docs/superpowers/specs/2026-06-28-sbom-version-tracking-design.md.
class SbomService {
  const SbomService();

  /// Generate a volatile-stripped CycloneDX SBOM for [closure] (a realized
  /// store path like `/run/current-system`, or a candidate toplevel) into
  /// [outPath]. Best-effort: returns false (logged) on any failure.
  Future<bool> generate({
    required String closure,
    required String outPath,
  }) async {
    final tmp = '$outPath.tmp';
    try {
      // `sbomnix` is baked into the node closure (templates base.nix) so it's
      // on PATH and works offline — required because a failed SBOM now blocks
      // the Apply commit (strict commit-on-success), so it must be reliable.
      final gen = await Process.run('sbomnix', [
        closure,
        '--cdx',
        tmp,
        '--csv',
        '/dev/null',
        '--spdx',
        '/dev/null',
        '--impure',
      ]);
      if (gen.exitCode != 0) {
        LogService.warn('sbom: sbomnix exited ${gen.exitCode}: ${gen.stderr}');
        return false;
      }
      // Strip the random serialNumber + generation timestamp so the file only
      // diffs when packages actually change (no per-run churn).
      final strip = await Process.run('jq', [
        'del(.serialNumber) | del(.metadata.timestamp)',
        tmp,
      ]);
      if (strip.exitCode != 0) {
        LogService.warn(
          'sbom: jq strip exited ${strip.exitCode}: ${strip.stderr}',
        );
        return false;
      }
      File(outPath).writeAsStringSync(strip.stdout as String);
      return true;
    } catch (e, st) {
      LogService.error('sbom: generate failed', e, st);
      return false;
    } finally {
      try {
        final t = File(tmp);
        if (t.existsSync()) t.deleteSync();
      } catch (_) {}
    }
  }

  /// Parse a CycloneDX file's `components[]` into `name → version`. Returns an
  /// empty map for a missing / empty / unparseable file (best-effort).
  Map<String, String> readComponents(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return const {};
      final raw = f.readAsStringSync().trim();
      if (raw.isEmpty) return const {};
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final comps = json['components'] as List<dynamic>? ?? const [];
      final out = <String, String>{};
      for (final c in comps) {
        if (c is Map<String, dynamic>) {
          final name = c['name'];
          if (name is String) out[name] = (c['version'] as String?) ?? '';
        }
      }
      return out;
    } catch (e) {
      LogService.warn('sbom: readComponents($path) failed: $e');
      return const {};
    }
  }

  /// Diff two component maps → added / removed / changed, sorted by name.
  List<SbomChange> diffComponents(
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final names = {...before.keys, ...after.keys}.toList()..sort();
    final out = <SbomChange>[];
    for (final name in names) {
      final b = before[name];
      final a = after[name];
      if (b == null && a != null) {
        out.add(
          SbomChange(name: name, from: null, to: a, kind: SbomChangeKind.added),
        );
      } else if (b != null && a == null) {
        out.add(
          SbomChange(
            name: name,
            from: b,
            to: null,
            kind: SbomChangeKind.removed,
          ),
        );
      } else if (b != null && a != null && b != a) {
        out.add(
          SbomChange(name: name, from: b, to: a, kind: SbomChangeKind.changed),
        );
      }
    }
    return out;
  }
}
