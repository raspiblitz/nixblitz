import 'package:meta/meta.dart';

/// A single branch declared by a publisher in their `branches.json`
/// (for nixblitz-self) or in the `branches` block of a plugin's
/// `plugin.json`. Operator-facing label is the map key; this class
/// is the value.
///
/// `ref` is the git ref (branch, tag, or commit) the chosen
/// channel resolves to.
@immutable
class DeclaredBranch {
  const DeclaredBranch({
    required this.ref,
    this.description,
    this.isDefault = false,
  });

  final String ref;
  final String? description;
  final bool isDefault;

  factory DeclaredBranch.fromJson(Map<String, dynamic> json) {
    final ref = json['ref'];
    if (ref is! String || ref.isEmpty) {
      throw const FormatException('branch: ref is required and non-empty');
    }
    if (!_isValidRef(ref)) {
      throw FormatException(
        'branch: ref "$ref" is not a valid git ref '
        '(no whitespace, no control characters, no "..")',
      );
    }
    final description = json['description'];
    if (description != null && description is! String) {
      throw const FormatException('branch: description must be a string');
    }
    final isDefault = json['default'];
    if (isDefault != null && isDefault is! bool) {
      throw const FormatException('branch: default must be a boolean');
    }
    return DeclaredBranch(
      ref: ref,
      description: description as String?,
      isDefault: (isDefault as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ref': ref,
      if (description != null) 'description': description,
      if (isDefault) 'default': true,
    };
  }

  /// Subset of git's check-ref-format rules sufficient for our use:
  /// reject whitespace, control characters, and ".." anywhere.
  static bool _isValidRef(String ref) {
    if (ref.contains('..')) return false;
    for (final cu in ref.codeUnits) {
      if (cu <= 0x20 || cu == 0x7f) return false;
    }
    return true;
  }
}
