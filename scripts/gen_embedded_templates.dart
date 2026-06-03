// Generates common/lib/src/services/embedded_templates.g.dart
// from the template files in templates/ and the repo-root
// branches.json.
//
// Run: dart run scripts/gen_embedded_templates.dart
// Or:  just gen-templates

import 'dart:io';

void main() {
  final templateDir = Directory('templates');
  final branchesFile = File('branches.json');
  final outputFile = File('common/lib/src/services/embedded_templates.g.dart');

  if (!templateDir.existsSync()) {
    stderr.writeln('Error: templates/ directory not found. Run from repo root.');
    exit(1);
  }

  if (!branchesFile.existsSync()) {
    stderr.writeln('Error: branches.json not found at repo root.');
    exit(1);
  }

  // Find all files, sort for deterministic output.
  final files = templateDir
      .listSync(recursive: true)
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    stderr.writeln('Error: no files found in templates/');
    exit(1);
  }

  final buffer = StringBuffer();
  buffer.writeln(
      "// GENERATED — do not edit. Run 'just gen-templates' to regenerate.");
  buffer.writeln('// Source: templates/ + branches.json');
  buffer.writeln();
  buffer.writeln("part of 'embedded_templates.dart';");
  buffer.writeln();

  // Embed branches.json from the repo root. nixblitz's own branch
  // manifest — the operator picks one of these for nixblitz-self.
  final branchesContent = branchesFile.readAsStringSync();
  buffer.writeln('const String _nixblitzBranchesJson = r\'\'\'');
  buffer.write(branchesContent);
  if (!branchesContent.endsWith('\n')) buffer.writeln();
  buffer.writeln("''';");
  buffer.writeln();

  final mapEntries = <String>[];

  for (final file in files) {
    final relativePath = file.path.replaceFirst('templates/', '');
    final varName = _pathToVarName(relativePath);
    final content = file.readAsStringSync();

    buffer.writeln("const String $varName = r'''");
    buffer.write(content);
    if (!content.endsWith('\n')) buffer.writeln();
    buffer.writeln("''';");
    buffer.writeln();

    mapEntries.add("    '$relativePath': $varName,");
  }

  buffer.writeln('Map<String, String> _getAllTemplates() {');
  buffer.writeln('  return {');
  for (final entry in mapEntries) {
    buffer.writeln(entry);
  }
  buffer.writeln('  };');
  buffer.writeln('}');

  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(buffer.toString());
  print('Generated ${files.length} templates + branches.json -> ${outputFile.path}');
}

String _pathToVarName(String path) {
  // flake.nix → _flake
  // hardware/vm.nix → _hardwareVm
  // modules/apps/bitcoind.nix → _modulesAppsBitcoind
  // modules/system/disko-vm.nix → _modulesSystemDiskoVm
  final withoutExt = path.replaceAll(RegExp(r'\.nix$'), '');
  final parts = withoutExt.split(RegExp(r'[/\-]'));
  final camel = '_${parts.first}${parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join()}';
  return camel;
}
