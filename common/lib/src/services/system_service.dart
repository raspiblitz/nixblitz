import 'dart:async';
import 'dart:io';
import 'package:common/src/models/service_status.dart';
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

  /// Update a single flake input and rebuild.
  ({Stream<String> output, Future<int> exitCode}) updateInput(
    String flakePath,
    String inputName,
  ) {
    return _updateAndRebuild(
      flakePath: flakePath,
      updateArgs: ['flake', 'update', inputName],
      updateLabel: '> nix flake update $inputName',
      commitMessage: 'Update $inputName',
    );
  }

  /// Update all flake inputs and rebuild.
  ({Stream<String> output, Future<int> exitCode}) updateAll(String flakePath) {
    return _updateAndRebuild(
      flakePath: flakePath,
      updateArgs: ['flake', 'update'],
      updateLabel: '> nix flake update',
      commitMessage: 'Update all flake inputs',
    );
  }

  ({Stream<String> output, Future<int> exitCode}) _updateAndRebuild({
    required String flakePath,
    required List<String> updateArgs,
    required String updateLabel,
    required String commitMessage,
  }) {
    final controller = StreamController<String>();
    final exitCodeFuture = () async {
      // Step 1: run `nix flake update [input]`
      controller.add(updateLabel);
      controller.add('');
      final update = await Process.start(
        'nix', updateArgs,
        workingDirectory: flakePath,
      );
      update.stdout.transform(const SystemEncoding().decoder).listen((data) => controller.add(data));
      update.stderr.transform(const SystemEncoding().decoder).listen((data) => controller.add(data));
      final updateCode = await update.exitCode;
      if (updateCode != 0) {
        controller.add('\nFlake update failed (exit code $updateCode).');
        await controller.close();
        return updateCode;
      }

      // Step 2: only commit + rebuild if flake.lock actually changed.
      // `nix flake update` rewrites the file even when nothing moved,
      // so we use git as the source of truth.
      final diff = await Process.run(
        'git', ['diff', '--quiet', '--exit-code', 'flake.lock'],
        workingDirectory: flakePath,
      );
      final lockChanged = diff.exitCode != 0;
      if (!lockChanged) {
        controller.add('');
        controller.add('No inputs changed — system already up to date.');
        await controller.close();
        return 0;
      }

      controller.add('');
      controller.add('> git commit flake.lock');
      await Process.run('git', ['add', 'flake.lock'], workingDirectory: flakePath);
      await Process.run('git', ['commit', '-m', commitMessage], workingDirectory: flakePath);

      // Step 3: rebuild
      controller.add('');
      controller.add('> sudo nixos-rebuild switch --flake $flakePath');
      controller.add('');
      final (:output, :exitCode) = sudoSession.runStreaming(
        ['nixos-rebuild', 'switch', '--flake', flakePath],
      );
      final sub = output.listen(controller.add);
      final rebuildCode = await exitCode;
      await sub.cancel();
      await controller.close();
      return rebuildCode;
    }();
    return (output: controller.stream, exitCode: exitCodeFuture);
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

  ({Stream<String> output, Future<int> exitCode}) rebuild(String flakePath) {
    return sudoSession.runStreaming(
      ['nixos-rebuild', 'switch', '--flake', flakePath],
    );
  }
}
