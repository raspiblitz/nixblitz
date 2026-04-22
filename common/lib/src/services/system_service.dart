import 'dart:async';
import 'dart:io';
import 'package:common/src/models/service_status.dart';

class SystemService {
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
      final rebuild = await Process.start(
        'sudo', ['nixos-rebuild', 'switch', '--flake', flakePath],
      );
      rebuild.stdout.transform(const SystemEncoding().decoder).listen((data) => controller.add(data));
      rebuild.stderr.transform(const SystemEncoding().decoder).listen((data) => controller.add(data));
      final rebuildCode = await rebuild.exitCode;
      await controller.close();
      return rebuildCode;
    }();
    return (output: controller.stream, exitCode: exitCodeFuture);
  }

  ({Stream<String> output, Future<int> exitCode}) rebuild(String flakePath) {
    final controller = StreamController<String>();
    final exitCodeFuture = () async {
      final process = await Process.start(
        'sudo', ['nixos-rebuild', 'switch', '--flake', flakePath],
      );
      process.stdout.transform(const SystemEncoding().decoder).listen((data) => controller.add(data));
      process.stderr.transform(const SystemEncoding().decoder).listen((data) => controller.add(data));
      final code = await process.exitCode;
      await controller.close();
      return code;
    }();
    return (output: controller.stream, exitCode: exitCodeFuture);
  }
}
