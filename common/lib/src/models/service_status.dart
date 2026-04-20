enum ServiceState { running, stopped, failed, activating, unknown }

class ServiceStatus {
  final String name;
  final ServiceState state;

  const ServiceStatus({required this.name, required this.state});

  bool get isRunning => state == ServiceState.running;

  String get stateLabel => switch (state) {
    ServiceState.running => 'running',
    ServiceState.stopped => 'stopped',
    ServiceState.failed => 'failed',
    ServiceState.activating => 'activating',
    ServiceState.unknown => 'unknown',
  };
}
