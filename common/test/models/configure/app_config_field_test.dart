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

    group('string_list', () {
      test('parses with default list', () {
        final f = AppConfigField.fromJson({
          'name': 'extensions',
          'type': 'string_list',
          'label': 'Extensions',
          'default': ['lnurlp', 'tipjar'],
        });
        expect(f, isA<StringListField>());
        final list = f as StringListField;
        expect(list.defaultValue, ['lnurlp', 'tipjar']);
        expect(list.placeholder, isNull);
      });

      test('default empty when omitted', () {
        final f = AppConfigField.fromJson({
          'name': 'extensions',
          'type': 'string_list',
          'label': 'Extensions',
        });
        final list = f as StringListField;
        expect(list.defaultValue, isEmpty);
      });

      test('non-list default falls back to empty', () {
        // Deliberately permissive: a malformed manifest shipping
        // `"default": "lnurlp"` instead of `["lnurlp"]` shouldn't
        // crash plugin parsing — just produce an empty default the
        // operator can populate in the TUI.
        final f = AppConfigField.fromJson({
          'name': 'extensions',
          'type': 'string_list',
          'label': 'Extensions',
          'default': 'lnurlp',
        });
        final list = f as StringListField;
        expect(list.defaultValue, isEmpty);
      });

      test('coerces non-string list entries to strings', () {
        final f = AppConfigField.fromJson({
          'name': 'tags',
          'type': 'string_list',
          'label': 'Tags',
          'default': ['one', 2, true],
        });
        final list = f as StringListField;
        expect(list.defaultValue, ['one', '2', 'true']);
      });

      test('placeholder roundtrip', () {
        final f = AppConfigField.fromJson({
          'name': 'extensions',
          'type': 'string_list',
          'label': 'Extensions',
          'default': <String>[],
          'placeholder': 'e.g. lnurlp, tipjar',
        });
        final list = f as StringListField;
        expect(list.placeholder, 'e.g. lnurlp, tipjar');
      });

      test('toJson emits type=string_list and default list', () {
        const f = StringListField(
          name: 'extensions',
          label: 'Extensions',
          defaultValue: ['lnurlp', 'tipjar'],
        );
        final j = f.toJson();
        expect(j['type'], 'string_list');
        expect(j['default'], ['lnurlp', 'tipjar']);
        expect(j.containsKey('description'), isFalse);
        expect(j.containsKey('placeholder'), isFalse);
      });

      test('toJson includes description + placeholder when set', () {
        const f = StringListField(
          name: 'extensions',
          label: 'Extensions',
          description: 'IDs managed by Nix',
          defaultValue: ['lnurlp'],
          placeholder: 'e.g. lnurlp',
        );
        final j = f.toJson();
        expect(j['description'], 'IDs managed by Nix');
        expect(j['placeholder'], 'e.g. lnurlp');
      });
    });
  });
}
