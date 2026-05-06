import 'dart:io';

import 'package:common/src/services/plugin/plugin_list_regen.dart';
import 'package:common/src/services/plugin/plugin_marker.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('regen_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('regeneratePluginsList', () {
    test('writes one path per enabled marker', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      _writeMarker(pluginsRoot.path, 'b', false);
      final result = regeneratePluginsList(
        baseDir: tmp.path,
        satisfiedPluginIds: {'a', 'b'},
      );
      expect(result.dropped, isEmpty);
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list.split('\n').where((l) => l.isNotEmpty).toSet(), {
        '${pluginsRoot.path}/a',
        '${pluginsRoot.path}/b',
      });
    });

    test('skips disabled plugins', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      _writeMarker(pluginsRoot.path, 'b', true); // disabled
      regeneratePluginsList(baseDir: tmp.path, satisfiedPluginIds: {'a', 'b'});
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list, contains('${pluginsRoot.path}/a'));
      expect(list, isNot(contains('${pluginsRoot.path}/b')));
    });

    test('skips plugins with unsatisfied deps', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      _writeMarker(pluginsRoot.path, 'b', false);
      regeneratePluginsList(
        baseDir: tmp.path,
        satisfiedPluginIds: {'a'}, // b is missing
      );
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list, contains('${pluginsRoot.path}/a'));
      expect(list, isNot(contains('${pluginsRoot.path}/b')));
    });

    test('detects + drops orphan paths in old plugins.list', () {
      final pluginsRoot = Directory('${tmp.path}/plugins')..createSync();
      _writeMarker(pluginsRoot.path, 'a', false);
      // Pre-existing plugins.list with an orphan path:
      File('${tmp.path}/plugins.list').writeAsStringSync(
        '${pluginsRoot.path}/a\n${pluginsRoot.path}/orphan\n',
      );
      final result = regeneratePluginsList(
        baseDir: tmp.path,
        satisfiedPluginIds: {'a'},
      );
      expect(result.dropped, contains('${pluginsRoot.path}/orphan'));
      final list = File('${tmp.path}/plugins.list').readAsStringSync();
      expect(list, isNot(contains('orphan')));
    });
  });
}

void _writeMarker(String pluginsRoot, String id, bool disabled) {
  final pd = Directory('$pluginsRoot/$id')..createSync();
  writeMarker(
    pd.path,
    PluginMarker(
      id: id,
      url: 'u',
      version: '1',
      rev: 'r',
      installedAt: DateTime.utc(2026, 5, 6),
      disabled: disabled,
    ),
  );
}
