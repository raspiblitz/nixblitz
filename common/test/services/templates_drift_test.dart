import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  group('detectTemplatesDrift', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('templates-drift-');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Materialise every embedded template into [tmp]. Mirrors what
    /// `ScaffoldService.refreshTemplatesSync()` does — used to seed
    /// the in-sync starting state for each test.
    void writeAllEmbedded() {
      final embedded = EmbeddedTemplates.getAll();
      for (final entry in embedded.entries) {
        final file = File('${tmp.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
      }
    }

    test('reports no drift when on-disk matches embedded', () {
      writeAllEmbedded();
      final drift = detectTemplatesDrift(tmp.path);
      expect(drift.hasDrift, isFalse);
      expect(drift.missing, isEmpty);
      expect(drift.modified, isEmpty);
      expect(drift.totalChanged, 0);
    });

    test('flags modified files', () {
      writeAllEmbedded();
      // Pick a file we know exists in the embedded set and corrupt
      // it. The page-size-fix saga's victim is a fitting choice.
      final target = File('${tmp.path}/hosts/installed-pi5.nix');
      target.writeAsStringSync('${target.readAsStringSync()}\n# pwn');

      final drift = detectTemplatesDrift(tmp.path);
      expect(drift.hasDrift, isTrue);
      expect(drift.modified, contains('hosts/installed-pi5.nix'));
      expect(drift.missing, isEmpty);
    });

    test('flags missing files', () {
      writeAllEmbedded();
      File('${tmp.path}/hosts/installed.nix').deleteSync();

      final drift = detectTemplatesDrift(tmp.path);
      expect(drift.hasDrift, isTrue);
      expect(drift.missing, contains('hosts/installed.nix'));
      expect(drift.modified, isEmpty);
    });

    test('treats an empty target dir as fully-missing drift', () {
      // Fresh repo, no scaffold yet. Every embedded key shows up
      // in `missing` so the dashboard / autoUpgrade can decide
      // whether to scaffold from scratch.
      final drift = detectTemplatesDrift(tmp.path);
      expect(drift.hasDrift, isTrue);
      expect(drift.modified, isEmpty);
      expect(drift.missing.length, equals(EmbeddedTemplates.getAll().length));
    });

    test('ignores operator-managed files outside the embedded set', () {
      // Pre-fix, `_autoUpgrade` would refresh templates wholesale
      // and the operator's `config.json`, `flake.lock`, etc. lived
      // alongside. Drift detection must only look at the embedded
      // keys — anything else stays in the operator's hands.
      writeAllEmbedded();
      File('${tmp.path}/config.json').writeAsStringSync('{"foo": 1}');
      File('${tmp.path}/flake.lock').writeAsStringSync('lock-stub');
      File(
        '${tmp.path}/hardware-configuration.nix',
      ).writeAsStringSync('{ ... }: {}');

      final drift = detectTemplatesDrift(tmp.path);
      expect(drift.hasDrift, isFalse);
    });

    test('lists are sorted ascending', () {
      writeAllEmbedded();
      // Modify two files; expect them to come back in alphabetical
      // order regardless of map iteration order.
      File('${tmp.path}/hosts/installed-pi5.nix').writeAsStringSync('A');
      File('${tmp.path}/hosts/installed.nix').writeAsStringSync('B');

      final drift = detectTemplatesDrift(tmp.path);
      expect(drift.modified, [
        'hosts/installed-pi5.nix',
        'hosts/installed.nix',
      ]);
    });
  });
}
