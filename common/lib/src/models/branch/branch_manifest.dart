import 'package:meta/meta.dart';
import 'declared_branch.dart';

/// A publisher's declared branch set — keys are operator-facing
/// labels, values describe the git ref + metadata. Used by both
/// the plugin manifest schema (v5 `branches` field) and nixblitz's
/// own `branches.json`.
@immutable
class BranchManifest {
  BranchManifest({required this.branches})
    : defaultKey = _findDefault(branches);

  final Map<String, DeclaredBranch> branches;

  /// The map key whose entry has default:true, or null if none.
  /// Parser enforces "at most one" — multiple default:true entries
  /// throw on fromJson.
  final String? defaultKey;

  factory BranchManifest.fromJson(Map<String, dynamic> json) {
    if (json.isEmpty) {
      throw const FormatException(
        'branches: manifest must declare at least one branch',
      );
    }
    final branches = <String, DeclaredBranch>{};
    int defaultCount = 0;
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        throw FormatException(
          'branches: entry "${entry.key}" must be a JSON object',
        );
      }
      final branch = DeclaredBranch.fromJson(value);
      if (branch.isDefault) defaultCount++;
      branches[entry.key] = branch;
    }
    if (defaultCount > 1) {
      throw const FormatException(
        'branches: exactly one entry may have default:true '
        '(found multiple)',
      );
    }
    return BranchManifest(branches: branches);
  }

  Map<String, dynamic> toJson() {
    return {for (final e in branches.entries) e.key: e.value.toJson()};
  }

  static String? _findDefault(Map<String, DeclaredBranch> branches) {
    for (final e in branches.entries) {
      if (e.value.isDefault) return e.key;
    }
    return null;
  }
}
