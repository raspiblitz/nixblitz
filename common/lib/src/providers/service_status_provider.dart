import 'package:riverpod/riverpod.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/system_service.dart';

final systemServiceProvider = Provider<SystemService>((ref) {
  return SystemService();
});

final serviceStatusProvider =
    FutureProvider<List<ServiceStatus>>((ref) async {
  final service = ref.watch(systemServiceProvider);
  return service.getAllServiceStatuses();
});
