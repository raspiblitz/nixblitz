import 'package:common/src/models/configure/app_config_field.dart';
import 'package:test/test.dart';

void main() {
  group('AppConfigField.fromJson', () {
    test('bool field', () {
      final f = AppConfigField.fromJson({
        'name': 'enabled',
        'type': 'bool',
        'label': 'Enabled',
        'default': false,
      });
      expect(f, isA<BoolField>());
      expect(f.name, 'enabled');
      expect((f as BoolField).defaultValue, isFalse);
    });

    test('string field with placeholder', () {
      final f = AppConfigField.fromJson({
        'name': 'alias',
        'type': 'string',
        'label': 'Alias',
        'default': '',
        'placeholder': 'my-node',
      });
      expect(f, isA<StringField>());
      expect((f as StringField).placeholder, 'my-node');
    });

    test('"str" accepted as alias for string', () {
      final f = AppConfigField.fromJson({
        'name': 'host_name',
        'type': 'str',
        'label': 'Hostname',
        'default': 'localhost',
      });
      expect(f, isA<StringField>());
    });

    test('"integer" accepted as alias for int', () {
      final f = AppConfigField.fromJson({
        'name': 'port',
        'type': 'integer',
        'label': 'Port',
        'default': 8080,
      });
      expect(f, isA<IntField>());
    });

    test('secret field', () {
      final f = AppConfigField.fromJson({
        'name': 'auth_key',
        'type': 'secret',
        'label': 'Auth key',
        'default': '',
        'placeholder': 'tskey-auth-...',
      });
      expect(f, isA<SecretField>());
      expect((f as SecretField).name, 'auth_key');
      expect(f.label, 'Auth key');
      expect(f.defaultValue, '');
      expect(f.placeholder, 'tskey-auth-...');
    });

    test('secret field round-trips via toJson', () {
      final src = {
        'name': 'token',
        'type': 'secret',
        'label': 'API token',
        'default': '',
      };
      final f = AppConfigField.fromJson(src);
      final back = AppConfigField.fromJson(f.toJson());
      expect(back, isA<SecretField>());
      expect((back as SecretField).name, 'token');
      expect(back.label, 'API token');
    });

    test('int field with min/max', () {
      final f = AppConfigField.fromJson({
        'name': 'prune_size_gb',
        'type': 'int',
        'label': 'Prune size',
        'default': 0,
        'min': 0,
        'max': 4096,
      });
      expect(f, isA<IntField>());
      expect((f as IntField).min, 0);
      expect(f.max, 4096);
    });

    test('enum field', () {
      final f = AppConfigField.fromJson({
        'name': 'network',
        'type': 'enum',
        'label': 'Network',
        'choices': ['mainnet', 'testnet', 'regtest', 'signet'],
        'default': 'mainnet',
      });
      expect(f, isA<EnumField>());
      expect((f as EnumField).choices, [
        'mainnet',
        'testnet',
        'regtest',
        'signet',
      ]);
      expect(f.defaultValue, 'mainnet');
    });

    test('description is optional', () {
      final f = AppConfigField.fromJson({
        'name': 'enabled',
        'type': 'bool',
        'label': 'L',
        'default': false,
        'description': 'turn it on',
      });
      expect(f.description, 'turn it on');
    });

    test('unknown type throws AppManifestError', () {
      expect(
        () => AppConfigField.fromJson({
          'name': 'x',
          'type': 'donut',
          'label': 'X',
          'default': 'glaze',
        }),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('missing required name throws', () {
      expect(
        () => AppConfigField.fromJson({
          'type': 'bool',
          'label': 'X',
          'default': false,
        }),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('missing required label throws', () {
      expect(
        () => AppConfigField.fromJson({
          'name': 'x',
          'type': 'bool',
          'default': false,
        }),
        throwsA(isA<AppManifestError>()),
      );
    });

    test('enum default not in choices throws', () {
      expect(
        () => AppConfigField.fromJson({
          'name': 'n',
          'type': 'enum',
          'label': 'N',
          'choices': ['a', 'b'],
          'default': 'c',
        }),
        throwsA(isA<AppManifestError>()),
      );
    });
  });
}
