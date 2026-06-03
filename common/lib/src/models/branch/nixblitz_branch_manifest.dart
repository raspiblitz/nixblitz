import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:common/src/models/branch/branch_manifest.dart';
import 'package:common/src/services/embedded_templates.dart';

/// Parses the embedded `branches.json` from `EmbeddedTemplates` once
/// per ProviderContainer. The TUI reads this on startup; new
/// nixblitz binaries on the operator's flake (after rebuild) bring
/// their own snapshot of branches.json.
final nixblitzBranchManifestProvider = Provider<BranchManifest>((ref) {
  final raw = EmbeddedTemplates.nixblitzBranchesJson;
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return BranchManifest.fromJson(json);
});
