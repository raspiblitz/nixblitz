import 'package:common/src/services/dashboard/dsl/primitives.dart';
import 'package:test/test.dart';

void main() {
  group('Primitive.fromJson', () {
    test('Row', () {
      final p = Primitive.fromJson({
        'Row': {
          'label': 'Peers',
          'value': {'\$data': 'peers'},
        },
      });
      expect(p, isA<Row>());
      expect((p as Row).label, 'Peers');
      expect(p.value, {'\$data': 'peers'});
    });

    test('StatusRow', () {
      final p = Primitive.fromJson({
        'StatusRow': {'label': 'Net', 'value': 'mainnet', 'color': 'ok'},
      });
      expect(p, isA<StatusRow>());
      expect((p as StatusRow).color, 'ok');
    });

    test('ProgressBar with default max', () {
      final p = Primitive.fromJson({
        'ProgressBar': {
          'label': 'Sync',
          'value': {'\$data': 'p'},
          'format': 'percent',
        },
      });
      expect(p, isA<ProgressBar>());
      expect((p as ProgressBar).max, 1.0);
      expect(p.format, 'percent');
    });

    test('Section with nested children', () {
      final p = Primitive.fromJson({
        'Section': {
          'title': 'Wallet',
          'children': [
            {
              'Row': {'label': 'On-chain', 'value': '0'},
            },
          ],
        },
      });
      expect(p, isA<Section>());
      expect((p as Section).children.length, 1);
      expect(p.children.first, isA<Row>());
    });

    test('Spacer default height 1', () {
      final p = Primitive.fromJson({'Spacer': {}});
      expect(p, isA<Spacer>());
      expect((p as Spacer).height, 1);
    });

    test('Footer with text + color', () {
      final p = Primitive.fromJson({
        'Footer': {'text': 'synced', 'color': 'ok'},
      }, allowFooter: true);
      expect(p, isA<Footer>());
      expect((p as Footer).text, 'synced');
    });

    test('Footer rejected outside footer block', () {
      expect(
        () => Primitive.fromJson({
          'Footer': {'text': 'x'},
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('Section rejects Footer in children', () {
      expect(
        () => Primitive.fromJson({
          'Section': {
            'children': [
              {
                'Footer': {'text': 'x'},
              },
            ],
          },
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('unknown primitive throws', () {
      expect(
        () => Primitive.fromJson({'NotAThing': {}}),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('multiple keys at root throws', () {
      expect(
        () => Primitive.fromJson({'Row': {}, 'Spacer': {}}),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('Row missing label throws', () {
      expect(
        () => Primitive.fromJson({
          'Row': {'value': 'x'},
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('Row missing value throws', () {
      expect(
        () => Primitive.fromJson({
          'Row': {'label': 'L'},
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('StatusRow missing value throws', () {
      expect(
        () => Primitive.fromJson({
          'StatusRow': {'label': 'L', 'color': 'ok'},
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('StatusRow missing color throws', () {
      expect(
        () => Primitive.fromJson({
          'StatusRow': {'label': 'L', 'value': 'V'},
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('ProgressBar with bad format throws', () {
      expect(
        () => Primitive.fromJson({
          'ProgressBar': {'value': 0.5, 'format': 'donut'},
        }),
        throwsA(isA<TileManifestError>()),
      );
    });

    test('ProgressBar with custom max parses', () {
      final p =
          Primitive.fromJson({
                'ProgressBar': {'value': 50, 'max': 100, 'format': 'percent'},
              })
              as ProgressBar;
      expect(p.max, 100);
    });
  });
}
