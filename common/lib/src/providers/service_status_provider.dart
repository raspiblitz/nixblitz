import 'package:riverpod/riverpod.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/providers/sudo_session_provider.dart';
import 'package:common/src/services/system_service.dart';

final systemServiceProvider = Provider<SystemService>((ref) {
  return SystemService(sudoSession: ref.watch(sudoSessionProvider));
});

final serviceStatusProvider =
    FutureProvider<List<ServiceStatus>>((ref) async {
  final service = ref.watch(systemServiceProvider);
  return service.getAllServiceStatuses();
});

/// Absolute path of the nixblitz binary that started this process. Used
/// after a rebuild to see whether the current-generation symlink now
/// points at a different store path, in which case a `[r] Restart` is
/// offered. Overridden in `main()` with `Platform.resolvedExecutable`.
final startupBinaryProvider = Provider<String>((ref) {
  throw UnimplementedError(
    'startupBinaryProvider must be overridden in main()',
  );
});
