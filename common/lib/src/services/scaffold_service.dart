import 'dart:io';
import 'package:common/src/services/embedded_templates.dart';
import 'package:common/src/services/log_service.dart';

class ScaffoldService {
  final String targetDir;

  ScaffoldService({required this.targetDir});

  bool needsScaffold() => !Directory(targetDir).existsSync();

  /// Write all embedded templates to the target directory.
  Future<void> scaffold() async {
    if (!needsScaffold()) {
      LogService.info('Scaffold skipped: $targetDir already exists');
      return;
    }

    LogService.info('Scaffolding $targetDir from embedded templates');
    final templates = EmbeddedTemplates.getAll();

    for (final entry in templates.entries) {
      final filePath = '$targetDir/${entry.key}';
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }

    LogService.info('Scaffold complete: ${templates.length} files written');
  }
}
