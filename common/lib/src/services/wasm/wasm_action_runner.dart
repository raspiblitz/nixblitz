import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wasmtime_dart/wasmtime_dart.dart';

import '../../models/plugin/sandbox_spec.dart';
import 'host_call.dart';
import 'module_cache.dart';

const int maxFuel = 5000000000;
const int maxTimeoutSeconds = 60;

/// Runs a sandboxed WASM action: one guest instance per invocation with
/// fuel + wall-clock limits, no filesystem/network, and the single
/// `nixblitz.host_call` import wired to [HostCallHandler].
class WasmActionRunner {
  WasmActionRunner({required this.library, required this.cacheDir})
    : _cache = ModuleCache(cacheDir);

  final WasmtimeLibrary library;
  final String cacheDir;
  final ModuleCache _cache;

  Future<({Stream<String> output, Future<int> exitCode})> run({
    required String wasmPath,
    required String export,
    required SandboxSpec sandbox,
    required HostCallHandler hostCall,
    bool quiet = false,
    int? maxWallClockSeconds,
  }) async {
    final controller = StreamController<String>();
    final fuel = sandbox.limits.fuel.clamp(1, maxFuel);
    final limit = sandbox.limits.timeoutSeconds.clamp(1, maxTimeoutSeconds);
    final timeout = maxWallClockSeconds == null
        ? limit
        : maxWallClockSeconds.clamp(1, limit);

    final exitFuture = () async {
      final engine = Engine(
        library,
        config: const EngineConfig(consumeFuel: true, epochInterruption: true),
      );
      final store = Store(engine);
      final ctx = store.context;
      final stdoutFile = File(
        '$cacheDir/.stdout-${DateTime.now().microsecondsSinceEpoch}',
      );
      EpochTicker? ticker;
      try {
        // WASI's stdout file lives under cacheDir, and the module cache
        // itself is only created lazily on first Module.fromWasm — make
        // sure the directory exists before wiring either one up. Kept
        // inside the try so a filesystem failure (read-only dir, disk
        // full, stray file at the path) is caught below: the controller
        // still closes and store/engine still dispose.
        Directory(cacheDir).createSync(recursive: true);
        ctx.setFuel(fuel);
        ctx.setEpochDeadline(timeout * 100); // ticker fires every 10ms
        final wasi = WasiConfig(
          args: const ['plugin'],
          stdoutFile: stdoutFile.path,
        );
        ctx.setWasi(wasi);

        final module = _cache.load(engine, wasmPath);
        final linker = Linker(engine)..defineWasi();

        // The one host import. host_call reads the request from guest
        // memory, runs the policy gate, writes the response back via the
        // guest's `alloc`, and returns (ptr<<32)|len.
        linker.defineFunc(
          'nixblitz',
          'host_call',
          FuncType(params: [ValType.i32, ValType.i32], results: [ValType.i64]),
          (caller, args) {
            final reqPtr = (args[0] as ValI32).value;
            final reqLen = (args[1] as ValI32).value;
            final mem = caller.getMemory('memory');
            final reqBytes = mem.readBytes(caller.context, reqPtr, reqLen);
            final responseJson = hostCall.handle(utf8.decode(reqBytes));
            final respBytes = utf8.encode(responseJson);
            final alloc = caller.getFunc('alloc');
            final outPtr =
                (alloc.call(caller.context, [ValI32(respBytes.length)]).single
                        as ValI32)
                    .value;
            mem.writeBytes(caller.context, outPtr, respBytes);
            final packed = (outPtr << 32) | respBytes.length;
            return [ValI64(packed)];
          },
        );

        ticker = await EpochTicker.start(
          engine,
          interval: const Duration(milliseconds: 10),
        );

        final instance = linker.instantiate(ctx, module);
        final fn = instance.getFunc(ctx, export);
        if (!quiet) controller.add('> wasm action: $export\n');
        fn.call(ctx);

        final out = stdoutFile.existsSync()
            ? stdoutFile.readAsStringSync()
            : '';
        if (out.isNotEmpty) controller.add(out);
        return 0;
      } on WasmTrap catch (t) {
        final msg = switch (t.code) {
          TrapCode.outOfFuel => 'plugin exceeded its fuel budget',
          TrapCode.interrupt => 'plugin exceeded its time budget',
          _ => 'plugin trapped: ${t.message}',
        };
        controller.add('$msg\n');
        return 1;
      } on WasmtimeError catch (e) {
        controller.add('wasm runtime error: ${e.message}\n');
        return 1;
      } finally {
        if (ticker != null) await ticker.stop();
        try {
          store.dispose();
        } catch (_) {}
        engine.dispose();
        if (stdoutFile.existsSync()) {
          try {
            stdoutFile.deleteSync();
          } catch (_) {}
        }
        // Not awaited: close() on a single-subscription StreamController
        // only completes once a listener has drained it, so awaiting
        // here would deadlock exitFuture for callers that only care
        // about the exit code and never listen to `output`. Any
        // buffered events (and the eventual done notification) are
        // still delivered to a listener that subscribes later.
        unawaited(controller.close());
      }
    }();

    return (output: controller.stream, exitCode: exitFuture);
  }
}
