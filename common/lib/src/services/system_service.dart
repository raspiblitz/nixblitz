import 'dart:async';
import 'dart:io';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/sudo_session.dart';

/// Exit code that the shell wrapper at `bin/nixblitz` interprets as
/// "restart me with the fresh binary in PATH". Hard-coded in
/// `nix/tui_pkg.nix`'s postInstall wrapper — keep the two in sync.
const int restartExitCode = 42;

/// Symlink NixOS keeps pointing at the currently-active generation's
/// copy of the TUI binary. Used to detect that a rebuild has landed a
/// new nixblitz-bin in the store.
const String _currentSystemBin =
    '/run/current-system/sw/bin/nixblitz-bin';

/// Result of [SystemService.updateLock]: did we actually move the
/// flake.lock forward, and (if not) why?
class LockUpdateResult {
  const LockUpdateResult({
    required this.exitCode,
    required this.committed,
  });

  /// Exit code of the underlying `nix flake update` invocation. Non-
  /// zero means the lock-update step itself failed and the rest of
  /// the flow should bail.
  final int exitCode;

  /// True if the new lock differed from the old AND we successfully
  /// committed it. False means either the flake's pins didn't move
  /// (no inputs changed) or the commit failed.
  final bool committed;

  bool get success => exitCode == 0;
}

/// Result of [SystemService.previewPackageDiff].
class PackageDiffResult {
  const PackageDiffResult({
    required this.exitCode,
    required this.diffText,
    this.newToplevel,
    this.errorMessage,
  });

  /// 0 on a clean preview (eval succeeded, nvd ran). Non-zero means
  /// the eval or nvd step failed; [errorMessage] should explain.
  final int exitCode;

  /// Resolved store path of the newly-evaluated system. Null on
  /// eval failure.
  final String? newToplevel;

  /// Formatted text from `nvd diff` — empty when [noChanges] is
  /// true or when the eval failed before nvd could run.
  final String diffText;

  /// Short human-readable error when [exitCode] is non-zero.
  final String? errorMessage;

  bool get success => exitCode == 0;

  /// True when the new toplevel store path is identical to the
  /// currently-running system's. Saves us showing an empty diff.
  bool get noChanges =>
      success && newToplevel != null && _currentMatches(newToplevel!);

  static bool _currentMatches(String newToplevel) {
    try {
      final r = Process.runSync('readlink', ['-f', '/run/current-system']);
      if (r.exitCode != 0) return false;
      return (r.stdout as String).trim() == newToplevel;
    } catch (_) {
      return false;
    }
  }
}

class SystemService {
  SystemService({required this.sudoSession});

  final SudoSession sudoSession;

  Future<ServiceStatus> getServiceStatus(String serviceName) async {
    final result = await Process.run('systemctl', [
      'show', serviceName, '--property=ActiveState,SubState', '--no-pager',
    ]);
    return parseServiceStatus(serviceName, result.stdout as String);
  }

  static ServiceStatus parseServiceStatus(String name, String output) {
    final lines = output.trim().split('\n');
    String? activeState;
    for (final line in lines) {
      if (line.startsWith('ActiveState=')) {
        activeState = line.substring('ActiveState='.length);
      }
    }
    final state = switch (activeState) {
      'active' => ServiceState.running,
      'inactive' => ServiceState.stopped,
      'failed' => ServiceState.failed,
      'activating' => ServiceState.activating,
      _ => ServiceState.unknown,
    };
    return ServiceStatus(name: name, state: state);
  }

  Future<List<ServiceStatus>> getAllServiceStatuses() async {
    final services = ['bitcoind', 'lnd', 'clightning', 'blitz-api', 'blitz-web'];
    return Future.wait(services.map(getServiceStatus));
  }

  /// Phase 1 of the Update flow: run `nix flake update <inputs>` in
  /// [flakePath], commit the new `flake.lock` if (and only if) it
  /// actually moved, and stream the output for live display.
  ///
  /// Caller checks [LockUpdateResult.committed] to decide whether
  /// to proceed to [previewPackageDiff] / [rebuild]. When
  /// `committed` is false the flow can short-circuit ("nothing to
  /// preview").
  ({
    Stream<String> output,
    Future<LockUpdateResult> result,
  }) updateLock({
    required String flakePath,
    required List<String> updateArgs,
    required String commitMessage,
  }) {
    final controller = StreamController<String>();
    final result = () async {
      controller.add('> nix ${updateArgs.join(" ")}');
      controller.add('');

      final update = await Process.start(
        'nix', updateArgs,
        workingDirectory: flakePath,
      );
      update.stdout
          .transform(const SystemEncoding().decoder)
          .listen(controller.add);
      update.stderr
          .transform(const SystemEncoding().decoder)
          .listen(controller.add);
      final updateCode = await update.exitCode;
      if (updateCode != 0) {
        controller.add('\nFlake update failed (exit $updateCode).');
        await controller.close();
        return LockUpdateResult(exitCode: updateCode, committed: false);
      }

      // Even when nothing moves, `nix flake update` rewrites the
      // file with a fresh `lastModified`. Use git as the source of
      // truth on whether the pins actually changed.
      final diff = await Process.run(
        'git', ['diff', '--quiet', '--exit-code', 'flake.lock'],
        workingDirectory: flakePath,
      );
      final lockChanged = diff.exitCode != 0;
      if (!lockChanged) {
        controller.add('');
        controller.add('No inputs changed — system already up to date.');
        await controller.close();
        return const LockUpdateResult(exitCode: 0, committed: false);
      }

      controller.add('');
      controller.add('> git commit flake.lock');
      await Process.run('git', ['add', 'flake.lock'],
          workingDirectory: flakePath);
      final commit = await Process.run(
        'git', ['commit', '-m', commitMessage],
        workingDirectory: flakePath,
      );
      await controller.close();
      return LockUpdateResult(
        exitCode: 0,
        committed: commit.exitCode == 0,
      );
    }();
    return (output: controller.stream, result: result);
  }

  /// Phase 2 of the Update flow: evaluate the (now-updated) flake's
  /// `nixosConfigurations.nixblitz.config.system.build.toplevel` to
  /// resolve the *new* system store path, then run `nvd diff` against
  /// `/run/current-system`. Streams progress (the eval is the slow
  /// step on a freshly-bumped lock).
  ///
  /// On eval failure, [PackageDiffResult.exitCode] is non-zero and
  /// [PackageDiffResult.errorMessage] holds the reason; the UI
  /// should let the user revert the lock commit and bail out before
  /// kicking off a doomed rebuild.
  ({
    Stream<String> output,
    Future<PackageDiffResult> result,
  }) previewPackageDiff({required String flakePath}) {
    final controller = StreamController<String>();
    final result = () async {
      controller.add('> nix build --no-link --print-out-paths '
          '.#nixosConfigurations.nixblitz.config.system.build.toplevel');
      controller.add('  (realizing new system — pulls from binary cache, '
          'compiles anything not cached; first run after a flake bump '
          'can take a few minutes)');
      controller.add('');

      // `nix build --no-link --print-out-paths` realizes the
      // derivation (mostly via binary-cache substitution) and writes
      // the resulting store path to stdout. We need realization, not
      // just evaluation: nvd diff fails with "Path does not exist"
      // when the toplevel store path is just a hash prediction the
      // store doesn't actually contain yet. Bonus: by building here,
      // the subsequent `nixos-rebuild switch` is essentially
      // activation-only — everything's already in the store.
      final eval = await Process.start(
        'nix',
        [
          'build', '--no-link', '--print-out-paths',
          '$flakePath#nixosConfigurations.nixblitz.config.system.build.toplevel',
        ],
        workingDirectory: flakePath,
      );

      final stdoutBuf = StringBuffer();
      final stdoutDone = Completer<void>();
      eval.stdout.transform(const SystemEncoding().decoder).listen(
        stdoutBuf.write,
        onDone: () =>
            stdoutDone.isCompleted ? null : stdoutDone.complete(),
      );
      eval.stderr
          .transform(const SystemEncoding().decoder)
          .listen(controller.add);

      final evalCode = await eval.exitCode;
      await stdoutDone.future;

      if (evalCode != 0) {
        final msg = 'Build failed (exit $evalCode). The new lock '
            "can't build cleanly — fix the underlying error or "
            'discard the update.';
        controller.add('');
        controller.add(msg);
        await controller.close();
        return PackageDiffResult(
          exitCode: evalCode,
          diffText: '',
          errorMessage: msg,
        );
      }

      final newTop = parseToplevel(stdoutBuf.toString());
      if (newTop == null) {
        const msg = 'Could not parse new system store path from '
            'nix-build output.';
        controller.add('');
        controller.add(msg);
        await controller.close();
        return const PackageDiffResult(
          exitCode: 1,
          diffText: '',
          errorMessage: msg,
        );
      }

      controller.add('');
      controller.add('> nvd diff /run/current-system $newTop');
      controller.add('');

      // nvd may not yet be on PATH — happens on the very first
      // template refresh that *adds* it to base.nix. Treat
      // ProcessException as a soft failure so the user still gets
      // a preview screen and can proceed/discard.
      try {
        final nvd = await Process.run(
          'nvd', ['diff', '/run/current-system', newTop],
        );
        final nvdOut = (nvd.stdout as String) + (nvd.stderr as String);
        controller.add(nvdOut);
        await controller.close();
        return PackageDiffResult(
          exitCode: 0,
          diffText: nvdOut,
          newToplevel: newTop,
        );
      } on ProcessException catch (e) {
        const placeholder =
            '(nvd not installed yet — this rebuild will install it; '
            'per-package preview will be available on the next update)';
        controller.add(placeholder);
        controller.add('  spawn error: ${e.message}');
        await controller.close();
        return PackageDiffResult(
          exitCode: 0,
          diffText: placeholder,
          newToplevel: newTop,
        );
      }
    }();
    return (output: controller.stream, result: result);
  }

  /// Pure parser: extracts a single `/nix/store/...` path from the
  /// stdout of `nix build --print-out-paths` (or `nix eval --raw`
  /// for that matter — both emit a single store path).
  ///
  /// Tolerates trailing whitespace / multi-line output. Returns
  /// null if no store path is found.
  static String? parseToplevel(String stdout) {
    final trimmed = stdout.trim();
    if (trimmed.startsWith('/nix/store/') && !trimmed.contains('\n')) {
      return trimmed;
    }
    final match = RegExp(r'/nix/store/[a-z0-9]+-[^\s]+').firstMatch(trimmed);
    return match?.group(0);
  }

  /// Phase 4 (used on user [d]iscard from the preview screen):
  /// roll back the most recent `flake.lock` commit so the working
  /// tree returns to its pre-Update state. Idempotent.
  Future<bool> revertLastFlakeCommit(String flakePath) async {
    try {
      final r = await Process.run(
        'git', ['reset', '--hard', 'HEAD~1'],
        workingDirectory: flakePath,
      );
      if (r.exitCode != 0) {
        LogService.warn(
          'revertLastFlakeCommit: git reset failed: ${r.stderr}',
        );
      }
      return r.exitCode == 0;
    } catch (e, st) {
      LogService.error('revertLastFlakeCommit threw', e, st);
      return false;
    }
  }

  /// True if the binary currently targeted by the NixOS "current generation"
  /// symlink differs from [startupPath] (captured at TUI launch). Used to
  /// surface a `[r] Restart` option after a rebuild replaces nixblitz-bin.
  ///
  /// Returns false on non-NixOS systems or when the symlink can't be read
  /// (e.g. the live ISO before install).
  Future<bool> hasNewerBinary(String startupPath) async {
    try {
      final result = await Process.run('readlink', ['-f', _currentSystemBin]);
      if (result.exitCode != 0) return false;
      final currentPath = (result.stdout as String).trim();
      return currentPath.isNotEmpty && currentPath != startupPath;
    } catch (_) {
      return false;
    }
  }

  /// Run `sudo nixos-rebuild switch --flake <path>#<attr>`.
  ///
  /// [attribute] selects which `nixosConfigurations.<name>` target
  /// to build; pick it via [rebuildAttributeFor] from the running
  /// system's `config.system.platform`. Defaults to `nixblitz`,
  /// the x86 / VM target.
  ({Stream<String> output, Future<int> exitCode}) rebuild(
    String flakePath, {
    String attribute = 'nixblitz',
  }) {
    return sudoSession.runStreaming(
      ['nixos-rebuild', 'switch', '--flake', '$flakePath#$attribute'],
    );
  }
}

/// Map a `system.platform` config value to the
/// `nixosConfigurations.<attribute>` it should rebuild against.
///
/// Pi 5 needs vendor kernel + matched firmware which neither
/// `nixblitz` nor `nixblitz-installer` (both x86_64-linux) provide;
/// `nixblitz-pi5` (aarch64, layered on `nvmd/nixos-raspberrypi`)
/// is its dedicated target. Everything else falls through to the
/// default x86 target — fine for `vm` (qemu builds the same way as
/// bare-metal x86) and a reasonable failure mode for unknown
/// strings, since `nixos-rebuild` will refuse loudly if the attr
/// is missing rather than silently producing the wrong system.
String rebuildAttributeFor(String platform) =>
    platform == 'pi5' ? 'nixblitz-pi5' : 'nixblitz';
