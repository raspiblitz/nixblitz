import 'dart:io';

import 'package:test/test.dart';
import 'package:common/src/services/sbom_service.dart';

void main() {
  const svc = SbomService();

  group('diffComponents', () {
    test('changed / added / removed, sorted by name', () {
      final before = {'foo': '1.2', 'baz': '2.0'};
      final after = {'foo': '1.3', 'bar': '0.9'};
      final changes = svc.diffComponents(before, after);
      expect(changes.map((c) => '${c.name}:${c.kind.name}'), [
        'bar:added',
        'baz:removed',
        'foo:changed',
      ]);
      final foo = changes.firstWhere((c) => c.name == 'foo');
      expect(foo.from, '1.2');
      expect(foo.to, '1.3');
    });

    test('identical maps → no changes', () {
      expect(svc.diffComponents({'a': '1'}, {'a': '1'}), isEmpty);
    });
  });

  group('readComponents', () {
    test('parses CycloneDX components into name→version', () {
      final dir = Directory.systemTemp.createTempSync('sbom');
      final tmp = File('${dir.path}/x.json');
      tmp.writeAsStringSync('''
        {"bomFormat":"CycloneDX","components":[
          {"name":"foo","version":"1.2","purl":"pkg:nix/foo"},
          {"name":"bar","version":"","purl":"pkg:nix/bar"}
        ]}
      ''');
      final m = svc.readComponents(tmp.path);
      expect(m['foo'], '1.2');
      expect(m['bar'], '');
      dir.deleteSync(recursive: true);
    });

    test('missing file → empty map', () {
      expect(svc.readComponents('/nonexistent/sbom.cdx.json'), isEmpty);
    });
  });
}
