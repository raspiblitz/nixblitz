// Generates common/lib/src/services/configure/bundled/embedded_schemas.g.dart
// from the manifest JSON files in
// common/lib/src/services/configure/bundled/manifests/.
//
// Run: dart run scripts/gen_app_config_schemas.dart
// Or:  just gen-app-schemas

import 'dart:io';

void main() {
  final manifestDir = Directory(
    'common/lib/src/services/configure/bundled/manifests',
  );
  final outputFile = File(
    'common/lib/src/services/configure/bundled/embedded_schemas.g.dart',
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

  // An empty manifest dir is valid: all apps have been extracted to plugins.
  // We still write the .g.dart so the part file exists and compiles.

  final buffer = StringBuffer();
  buffer.writeln(
    "// GENERATED — do not edit. Run 'just gen-app-schemas' to regenerate.",
  );
  buffer.writeln(
    '// Source: common/lib/src/services/configure/bundled/manifests/',
  );
  buffer.writeln();
  buffer.writeln("// ignore_for_file: constant_identifier_names");
  buffer.writeln();
  buffer.writeln("part of 'embedded_schemas.dart';");
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

  buffer.writeln('const Map<String, String> _allAppSchemas = {');
  for (final entry in mapEntries) {
    buffer.writeln(entry);
  }
  buffer.writeln('};');

  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(buffer.toString());
  print('Generated ${files.length} app manifests -> ${outputFile.path}');
}
