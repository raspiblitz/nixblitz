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
