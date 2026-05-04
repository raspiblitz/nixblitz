import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:common/src/services/plugin_config_service.dart';

void main() {
  group('PluginConfigService', () {
    late Directory home;
    late PluginConfigService pluginCfgService;

    setUp(() {
      home = Directory.systemTemp.createTempSync('nixblitz_pcs_');
      Directory('${home.path}/plugins/demo').createSync(recursive: true);
      pluginCfgService = PluginConfigService(baseDir: home.path);
    });

    tearDown(() => home.deleteSync(recursive: true));

    test('isInstalled true when plugin dir exists', () {
      expect(pluginCfgService.isInstalled('demo'), isTrue);
      expect(pluginCfgService.isInstalled('ghost'), isFalse);
    });

    test('read returns {} when config.json is missing', () {
      expect(pluginCfgService.read('demo'), isEmpty);
    });

    test('read returns {} for an empty config.json', () {
      File('${home.path}/plugins/demo/config.json').writeAsStringSync('   \n');
      expect(pluginCfgService.read('demo'), isEmpty);
    });

    test('read parses a valid config.json', () {
      File(
        '${home.path}/plugins/demo/config.json',
      ).writeAsStringSync(jsonEncode({'key': 'value', 'count': 3}));
      final m = pluginCfgService.read('demo');
      expect(m['key'], 'value');
      expect(m['count'], 3);
    });

    test('read throws FormatException on non-object JSON', () {
      File(
        '${home.path}/plugins/demo/config.json',
      ).writeAsStringSync('["not", "an", "object"]');
      expect(
        () => pluginCfgService.read('demo'),
        throwsA(isA<FormatException>()),
      );
    });

    test('read throws FormatException on malformed JSON', () {
      File(
        '${home.path}/plugins/demo/config.json',
      ).writeAsStringSync('{{ not json }}');
      expect(
        () => pluginCfgService.read('demo'),
        throwsA(isA<FormatException>()),
      );
    });

    test('write + read round-trips', () async {
      await pluginCfgService.write('demo', {
        'auth_key': 'abc',
        'exit_node': true,
      });
      final back = pluginCfgService.read('demo');
      expect(back['auth_key'], 'abc');
      expect(back['exit_node'], true);
    });

    test('write produces pretty-printed JSON', () async {
      await pluginCfgService.write('demo', {'a': 1});
      final text = File(
        '${home.path}/plugins/demo/config.json',
      ).readAsStringSync();
      expect(text, contains('  "a": 1'));
      expect(text, endsWith('\n'));
    });
  });
}
