import 'dart:io';

import 'package:test/test.dart';
import 'package:wasmtime_dart/wasmtime_dart.dart';

import 'helpers.dart';

const helloWat = '''
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func \$fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "hello from sandboxed WASI!\\n")
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 16))
    (i32.store (i32.const 4) (i32.const 27))
    (drop (call \$fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))))
''';

/// Writes environ_count as a little-endian u32 to stdout.
const envCountWat = '''
(module
  (import "wasi_snapshot_preview1" "environ_sizes_get"
    (func \$esg (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func \$fdw (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call \$esg (i32.const 0) (i32.const 4)))
    (i32.store (i32.const 8) (i32.const 0))
    (i32.store (i32.const 12) (i32.const 4))
    (drop (call \$fdw (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 16)))))
''';

/// Writes args_count as a little-endian u32 to stdout.
const argCountWat = '''
(module
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func \$asg (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func \$fdw (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "_start")
    (drop (call \$asg (i32.const 0) (i32.const 4)))
    (i32.store (i32.const 8) (i32.const 0))
    (i32.store (i32.const 12) (i32.const 4))
    (drop (call \$fdw (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 16)))))
''';

/// try_create opens "out.txt" with O_CREAT against preopen fd 3;
/// returns the raw errno (0 = success).
const pathOpenWat = '''
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func \$po (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "out.txt")
  (func (export "try_create") (result i32)
    (call \$po
      (i32.const 3)              ;; first preopen
      (i32.const 0)              ;; dirflags
      (i32.const 0) (i32.const 7) ;; path "out.txt"
      (i32.const 1)              ;; oflags: CREAT
      (i64.const 0x440)          ;; rights: fd_write | path_create_file
      (i64.const 0)
      (i32.const 0)
      (i32.const 64))))          ;; opened-fd out ptr
''';

void main() {
  late Engine engine;
  late Store store;
  late Linker linker;
  setUp(() {
    engine = Engine(testLib());
    store = Store(engine);
    linker = Linker(engine)..defineWasi();
  });
  tearDown(() {
    linker.dispose();
    store.dispose();
    engine.dispose();
  });

  File tmpFile(String name) =>
      File('${Directory.systemTemp.path}/wasmtime_dart_$name');

  Instance inst(String wat) {
    final m = Module.fromWat(engine, wat);
    addTearDown(m.dispose);
    return linker.instantiate(store.context, m);
  }

  test('hello world with stdout captured to a file', () {
    final out = tmpFile('stdout.txt');
    store.context.setWasi(WasiConfig(args: ['t'], stdoutFile: out.path));
    inst(helloWat).getFunc(store.context, '_start').call(store.context);
    expect(out.readAsStringSync(), 'hello from sandboxed WASI!\n');
    out.deleteSync();
  });

  test('guest sees the configured env vars', () {
    final out = tmpFile('envcount.bin');
    store.context.setWasi(
      WasiConfig(args: ['t'], env: {'A': '1', 'B': '2'}, stdoutFile: out.path),
    );
    inst(envCountWat).getFunc(store.context, '_start').call(store.context);
    expect(out.readAsBytesSync(), [2, 0, 0, 0]);
    out.deleteSync();
  });

  test('guest sees the configured argv', () {
    final out = tmpFile('argcount.bin');
    store.context.setWasi(
      WasiConfig(args: ['a', 'b', 'c'], stdoutFile: out.path),
    );
    inst(argCountWat).getFunc(store.context, '_start').call(store.context);
    expect(out.readAsBytesSync(), [3, 0, 0, 0]);
    out.deleteSync();
  });

  test('read-only preopen rejects file creation; read-write allows it', () {
    int tryCreate(DirPerms dp, FilePerms fp, Directory dir) {
      final e = Engine(testLib());
      final s = Store(e);
      final l = Linker(e)..defineWasi();
      s.context.setWasi(
        WasiConfig(
          args: ['t'],
          preopens: [
            PreopenDir(dir.path, '/data', dirPerms: dp, filePerms: fp),
          ],
        ),
      );
      final m = Module.fromWat(e, pathOpenWat);
      final errno =
          (l
                      .instantiate(s.context, m)
                      .getFunc(s.context, 'try_create')
                      .call(s.context)
                      .single
                  as ValI32)
              .value;
      m.dispose();
      l.dispose();
      s.dispose();
      e.dispose();
      return errno;
    }

    final roDir = Directory.systemTemp.createTempSync('wasmtime_dart_ro_');
    final rwDir = Directory.systemTemp.createTempSync('wasmtime_dart_rw_');
    addTearDown(() {
      roDir.deleteSync(recursive: true);
      rwDir.deleteSync(recursive: true);
    });

    expect(
      tryCreate(DirPerms.read, FilePerms.read, roDir),
      isNot(0),
      reason: 'RO preopen must refuse O_CREAT',
    );
    expect(File('${roDir.path}/out.txt').existsSync(), isFalse);
    expect(tryCreate(DirPerms.readWrite, FilePerms.readWrite, rwDir), 0);
    expect(File('${rwDir.path}/out.txt').existsSync(), isTrue);
  });

  test('a WasiConfig cannot be used twice', () {
    final cfg = WasiConfig(args: ['t']);
    store.context.setWasi(cfg);
    final store2 = Store(engine);
    addTearDown(store2.dispose);
    expect(() => store2.context.setWasi(cfg), throwsStateError);
  });
}
