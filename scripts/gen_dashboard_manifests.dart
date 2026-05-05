// Generates common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart
// from the manifest JSON files in
// common/lib/src/services/dashboard/bundled/manifests/.
//
// Run: dart run scripts/gen_dashboard_manifests.dart
// Or:  just gen-manifests

import 'dart:io';

void main() {
  final manifestDir = Directory(
    'common/lib/src/services/dashboard/bundled/manifests',
  );
  final outputFile = File(
    'common/lib/src/services/dashboard/bundled/embedded_manifests.g.dart',
  );

  if (!manifestDir.existsSync()) {
    stderr.writeln(
      'Error: ${manifestDir.path} directory not found. Run from repo root.',
    );
    exit(1);
  }

  // Find all JSON files, sort for deterministic output.
  final files = manifestDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    stderr.writeln('Error: no .json files found in ${manifestDir.path}');
    exit(1);
  }

  final buffer = StringBuffer();
  buffer.writeln(
    "// GENERATED — do not edit. Run 'just gen-manifests' to regenerate.",
  );
  buffer.writeln(
    '// Source: common/lib/src/services/dashboard/bundled/manifests/',
  );
  buffer.writeln();
  buffer.writeln("part of 'embedded_manifests.dart';");
  buffer.writeln();

  final mapEntries = <String>[];

  for (final file in files) {
    final name = file.uri.pathSegments.last.replaceAll('.json', '');
    final varName = '_${name}Json';
    final content = file.readAsStringSync();

    buffer.writeln('const String $varName = r\'\'\'');
    buffer.write(content);
    if (!content.endsWith('\n')) buffer.writeln();
    buffer.writeln("''';");
    buffer.writeln();

    mapEntries.add("  '$name': $varName,");
  }

  buffer.writeln('const Map<String, String> _allManifests = {');
  for (final entry in mapEntries) {
    buffer.writeln(entry);
  }
  buffer.writeln('};');

  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(buffer.toString());
  print('Generated ${files.length} manifests -> ${outputFile.path}');
}
