import 'dart:io';

import 'embedded_templates.dart';

/// Result of comparing the binary's embedded templates against
/// the operator's on-disk copy at `~/nixblitz/`. Aggregates which
/// keys went missing entirely and which keys exist on disk but
/// have different content from what the binary embeds. Both
/// lists are sorted ascending so log output and UI surfacing
/// are deterministic across runs.
///
/// Operator-managed files outside the embedded set
/// (`config.json`, `hardware-configuration.nix`, `flake.lock`,
/// the plugins tree, …) are deliberately ignored — drift here
/// is about whether the shipped template content matches, not
/// whether the operator's home dir has anything else in it.
class TemplatesDrift {
  /// Templates whose embedded path doesn't exist on disk at
  /// all. Either the operator deleted them or this is the
  /// first time a newly-added template ships in the binary.
  final List<String> missing;

  /// Templates that exist on disk but whose content differs
  /// from what's embedded. Either the operator hand-edited
  /// the file, OR a newer binary shipped a content update
  /// without bumping the config schema version (the case this
  /// whole module exists to detect).
  final List<String> modified;

  const TemplatesDrift({required this.missing, required this.modified});

  /// Convenience: the pre-built "everything matches" result.
  static const TemplatesDrift inSync = TemplatesDrift(
    missing: [],
    modified: [],
  );

  bool get hasDrift => missing.isNotEmpty || modified.isNotEmpty;

  /// Total count of templates that either went missing OR
  /// have updated content. Used for the dashboard banner copy.
  int get totalChanged => missing.length + modified.length;
}

/// Diff the binary's [EmbeddedTemplates] against [targetDir]'s
/// on-disk copy. Iterates the embedded keys (canonical source
/// of truth), reads each corresponding file from disk, and bins
/// any difference into [TemplatesDrift.missing] (file absent)
/// or [TemplatesDrift.modified] (content mismatch).
TemplatesDrift detectTemplatesDrift(String targetDir) {
  final missing = <String>[];
  final modified = <String>[];
  final embedded = EmbeddedTemplates.getAll();
  final keys = embedded.keys.toList()..sort();
  for (final key in keys) {
    final file = File('$targetDir/$key');
    if (!file.existsSync()) {
      missing.add(key);
      continue;
    }
    if (file.readAsStringSync() != embedded[key]) {
      modified.add(key);
    }
  }
  return TemplatesDrift(missing: missing, modified: modified);
}
