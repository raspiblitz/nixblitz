import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'generated/raw.dart';
import 'library.dart';
import 'trap.dart';

/// wasi_dir_perms flags (wasi.h): READ = 1, WRITE = 2.
enum DirPerms {
  read(1),
  write(2),
  readWrite(3);

  const DirPerms(this.native);
  final int native;
}

/// wasi_file_perms flags (wasi.h): READ = 1, WRITE = 2.
enum FilePerms {
  read(1),
  write(2),
  readWrite(3);

  const FilePerms(this.native);
  final int native;
}

/// One host directory exposed to the guest at [guestPath].
class PreopenDir {
  const PreopenDir(
    this.hostPath,
    this.guestPath, {
    this.dirPerms = DirPerms.readWrite,
    this.filePerms = FilePerms.readWrite,
  });
  final String hostPath;
  final String guestPath;
  final DirPerms dirPerms;
  final FilePerms filePerms;
}

/// WASI Preview1 configuration. Consumed exactly once by
/// Context.setWasi — the C config is destroyed by wasmtime on use.
/// Custom stdio callbacks are deliberately not exposed: wasmtime-wasi
/// invokes them from tokio worker threads, where Dart isolateLocal
/// callbacks abort the VM. Capture stdio through files.
class WasiConfig {
  WasiConfig({
    this.args = const [],
    this.env = const {},
    this.preopens = const [],
    this.stdoutFile,
    this.stderrFile,
    this.stdinBytes,
    this.inheritStdout = false,
    this.inheritStderr = false,
    this.inheritStdin = false,
  });

  final List<String> args;
  final Map<String, String> env;
  final List<PreopenDir> preopens;
  final String? stdoutFile;
  final String? stderrFile;
  final Uint8List? stdinBytes;
  final bool inheritStdout;
  final bool inheritStderr;
  final bool inheritStdin;
  bool consumed = false;

  /// Builds the native config. Internal — called by Context.setWasi.
  ffi.Pointer<wasi_config_t> buildNative(WasmtimeLibrary lib) {
    if (consumed) {
      throw StateError('WasiConfig was already consumed by setWasi');
    }
    consumed = true;
    final raw = lib.raw;
    final cfg = raw.wasi_config_new();
    final allocs = <ffi.Pointer<ffi.NativeType>>[];
    // Generated bindings type WASI's char* params as Pointer<Char>
    // (not Pointer<Uint8> as ffigen sometimes emits) — dup() matches
    // that so call sites need no per-argument casts.
    ffi.Pointer<ffi.Char> dup(String s) {
      final p = s.toNativeUtf8();
      allocs.add(p);
      return p.cast();
    }

    try {
      if (args.isNotEmpty) {
        final argv = calloc<ffi.Pointer<ffi.Char>>(args.length);
        allocs.add(argv);
        for (var i = 0; i < args.length; i++) {
          argv[i] = dup(args[i]);
        }
        if (!raw.wasi_config_set_argv(cfg, args.length, argv)) {
          throw WasmtimeError('wasi_config_set_argv failed');
        }
      }
      if (env.isNotEmpty) {
        final names = calloc<ffi.Pointer<ffi.Char>>(env.length);
        final values = calloc<ffi.Pointer<ffi.Char>>(env.length);
        allocs.addAll([names, values]);
        var i = 0;
        for (final MapEntry(:key, :value) in env.entries) {
          names[i] = dup(key);
          values[i] = dup(value);
          i++;
        }
        if (!raw.wasi_config_set_env(cfg, env.length, names, values)) {
          throw WasmtimeError('wasi_config_set_env failed');
        }
      }
      for (final p in preopens) {
        if (!raw.wasi_config_preopen_dir(
          cfg,
          dup(p.hostPath),
          dup(p.guestPath),
          p.dirPerms.native,
          p.filePerms.native,
        )) {
          throw WasmtimeError(
            'wasi_config_preopen_dir(${p.hostPath}) failed — does it exist?',
          );
        }
      }
      if (stdoutFile != null &&
          !raw.wasi_config_set_stdout_file(cfg, dup(stdoutFile!))) {
        throw WasmtimeError('wasi_config_set_stdout_file failed');
      }
      if (stderrFile != null &&
          !raw.wasi_config_set_stderr_file(cfg, dup(stderrFile!))) {
        throw WasmtimeError('wasi_config_set_stderr_file failed');
      }
      if (stdinBytes != null) {
        final vec = calloc<wasm_byte_vec_t>();
        allocs.add(vec);
        final buf = calloc<ffi.Uint8>(stdinBytes!.length);
        allocs.add(buf);
        buf.asTypedList(stdinBytes!.length).setAll(0, stdinBytes!);
        raw.wasm_byte_vec_new(vec, stdinBytes!.length, buf.cast());
        raw.wasi_config_set_stdin_bytes(cfg, vec); // consumes vec contents
      }
      if (inheritStdout) raw.wasi_config_inherit_stdout(cfg);
      if (inheritStderr) raw.wasi_config_inherit_stderr(cfg);
      if (inheritStdin) raw.wasi_config_inherit_stdin(cfg);
      return cfg;
    } catch (_) {
      raw.wasi_config_delete(cfg);
      rethrow;
    } finally {
      for (final p in allocs) {
        calloc.free(p);
      }
    }
  }
}
