import 'package:riverpod/legacy.dart';

enum AppView {
  install,
  setup,
  dashboard,
  configure,
  apply,
  update,
  debug,
  configTooNew,
}

final currentViewProvider = StateProvider<AppView>((ref) => AppView.dashboard);
final selectedServiceIndexProvider = StateProvider<int>((ref) => 0);
