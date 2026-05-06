import 'package:common/src/models/configure/app_config_field.dart';
import 'package:common/src/models/configure/app_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('AppManifest.fromJsonString', () {
    test('full round-trip', () {
      final m = AppManifest.fromJsonString(r'''
        {
          "id": "lnd",
          "label": "LND",
          "description": "Lightning Network Daemon",
          "capabilities": ["lightning_backend"],
          "fields": [
            {"name": "enabled", "type": "bool", "label": "Enabled", "default": false},
            {"name": "alias",   "type": "string", "label": "Alias",   "default": "", "placeholder": "my-node"}
          ]
        }
      ''');
      expect(m.id, 'lnd');
      expect(m.label, 'LND');
      expect(m.capabilities, contains('lightning_backend'));
      expect(m.fields.length, 2);
      expect(m.fields.first, isA<BoolField>());
      expect(m.serviceUnit, isNull);
      expect(m.unitName, 'lnd');
    });

    test('service_unit override', () {
      final m = AppManifest.fromJsonString(r'''
        {
          "id": "cln",
          "label": "CLN",
          "service_unit": "clightning",
          "fields": []
        }
      ''');
      expect(m.serviceUnit, 'clightning');
      expect(m.unitName, 'clightning');
    });

    test('field(name) lookup', () {
      final m = AppManifest.fromJsonString(r'''
        {"id": "x", "label": "X", "fields": [
          {"name": "enabled", "type": "bool", "label": "Enabled", "default": false}
        ]}
      ''');
      expect(m.field('enabled'), isA<BoolField>());
      expect(m.field('missing'), isNull);
    });

    test('rejects missing id', () {
      expect(
        () => AppManifest.fromJsonString(r'{"label": "X", "fields": []}'),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('rejects missing label', () {
      expect(
        () => AppManifest.fromJsonString(r'{"id": "x", "fields": []}'),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('rejects malformed JSON', () {
      expect(
        () => AppManifest.fromJsonString('not json'),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('empty fields list is allowed', () {
      final m = AppManifest.fromJsonString(
        r'{"id": "x", "label": "X", "fields": []}',
      );
      expect(m.fields, isEmpty);
    });

    test('empty capabilities default', () {
      final m = AppManifest.fromJsonString(
        r'{"id": "x", "label": "X", "fields": []}',
      );
      expect(m.capabilities, isEmpty);
    });
  });
}
