import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

void main() {
  test('discover opens the library from WASMTIME_DART_LIB', () {
    final lib = WasmtimeLibrary.discover();
    expect(lib.path, isNotEmpty);
  });

  test('open with a bad path throws WasmtimeError', () {
    expect(
      () => WasmtimeLibrary.open('/nonexistent/libwasmtime.so'),
      throwsA(isA<WasmtimeError>()),
    );
  });

  test('open with a non-wasmtime library gives the version hint', () {
    expect(
      () => WasmtimeLibrary.open('libc.so.6'),
      throwsA(
        isA<WasmtimeError>().having(
          (e) => e.message,
          'message',
          contains('wasmtime 46'),
        ),
      ),
    );
  });
}
