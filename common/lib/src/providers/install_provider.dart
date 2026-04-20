import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/src/models/install_state.dart';
import 'package:common/src/services/install_service.dart';

final installServiceProvider = Provider<InstallService>((ref) {
  return InstallService();
});

final installStepProvider = StateProvider<InstallStep>((ref) {
  return InstallStep.detectSystem;
});

final systemInfoProvider = FutureProvider<SystemInfo>((ref) async {
  final service = ref.watch(installServiceProvider);
  return service.detectSystem();
});

final selectedDiskProvider = StateProvider<DiskInfo?>((ref) => null);

final installLogProvider = StateProvider<List<String>>((ref) => []);

final installCurrentStepLabelProvider = StateProvider<String>((ref) => '');
