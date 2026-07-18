import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  test('parses a bash command tile (unchanged)', () {
    final s = PluginTileSpec.fromJson({'title': 'T', 'command': 'echo {}'});
    expect(s.command, 'echo {}');
    expect(s.isWasm, isFalse);
  });

  test('parses a wasm tile', () {
    final s = PluginTileSpec.fromJson({
      'title': 'Node Summary',
      'wasm': {'module': 'actions/summary.wasm', 'export': 'tile'},
      'poll_interval_seconds': 15,
    });
    expect(s.isWasm, isTrue);
    expect(s.wasm!.module, 'actions/summary.wasm');
    expect(s.wasm!.export, 'tile');
    expect(s.command, isNull);
    expect(s.pollInterval.inSeconds, 15);
  });

  test('wasm export defaults to tile', () {
    final s = PluginTileSpec.fromJson({
      'title': 'T',
      'wasm': {'module': 'a.wasm'},
    });
    expect(s.wasm!.export, 'tile');
  });

  test('rejects declaring both command and wasm', () {
    expect(
      () => PluginTileSpec.fromJson({
        'title': 'T',
        'command': 'echo {}',
        'wasm': {'module': 'a.wasm'},
      }),
      throwsFormatException,
    );
  });

  test('rejects declaring neither command nor wasm', () {
    expect(
      () => PluginTileSpec.fromJson({'title': 'T'}),
      throwsFormatException,
    );
  });

  test('rejects a wasm tile with empty module', () {
    expect(
      () => PluginTileSpec.fromJson({
        'title': 'T',
        'wasm': {'module': ''},
      }),
      throwsFormatException,
    );
  });
}
