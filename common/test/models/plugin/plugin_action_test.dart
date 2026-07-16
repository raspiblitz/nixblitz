import 'package:common/common.dart';
import 'package:test/test.dart';

void main() {
  test('parses a wasm action', () {
    final a = PluginAction.fromJson({
      'label': 'Node summary',
      'confirm': false,
      'wasm': {'module': 'actions/summary.wasm', 'export': 'run'},
      'timeout_seconds': 10,
    });
    expect(a.isWasm, isTrue);
    expect(a.wasm!.module, 'actions/summary.wasm');
    expect(a.wasm!.export, 'run');
    expect(a.isPrivileged, isFalse);
  });

  test('wasm export defaults to run', () {
    final a = PluginAction.fromJson({
      'label': 'x',
      'wasm': {'module': 'a.wasm'},
    });
    expect(a.wasm!.export, 'run');
  });

  test('rejects an action with both command and wasm', () {
    expect(
      () => PluginAction.fromJson({
        'label': 'x',
        'command': 'echo hi',
        'wasm': {'module': 'a.wasm'},
      }),
      throwsFormatException,
    );
  });

  test('rejects an action with none of command/unit/wasm', () {
    expect(() => PluginAction.fromJson({'label': 'x'}), throwsFormatException);
  });

  test('rejects a wasm action with empty module', () {
    expect(
      () => PluginAction.fromJson({
        'label': 'x',
        'wasm': {'module': ''},
      }),
      throwsFormatException,
    );
  });
}
