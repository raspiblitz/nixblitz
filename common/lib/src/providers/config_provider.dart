import 'package:riverpod/riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/services/config_service.dart';
import 'package:common/src/services/log_service.dart';

final baseDirProvider = Provider<String>((ref) {
  throw UnimplementedError('baseDirProvider must be overridden');
});

final configServiceProvider = Provider<ConfigService>((ref) {
  return ConfigService(baseDir: ref.watch(baseDirProvider));
});

final configProvider =
    StateNotifierProvider<ConfigNotifier, AsyncValue<NixblitzConfig>>((ref) {
      return ConfigNotifier(ref.watch(configServiceProvider));
    });

class ConfigNotifier extends StateNotifier<AsyncValue<NixblitzConfig>> {
  final ConfigService _configService;

  ConfigNotifier(this._configService) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      if (_configService.configExists()) {
        final config = await _configService.readConfig();
        state = AsyncValue.data(config);
      } else {
        state = AsyncValue.data(NixblitzConfig.defaults());
      }
    } catch (e, st) {
      LogService.error('Failed to load config', e, st);
      state = AsyncValue.error(e, st);
    }
  }

  // Sync write deliberately. Async writes here race with sync
  // writeConfigSync calls in adjacent code paths (the setup wizard
  // writes via writeConfigSync + immediately calls updateConfig with
  // the same content, and _markStepCompleted does the same dance):
  // Dart's `writeAsString` truncates at open time but doesn't clear
  // bytes past the new content's length, so two concurrent
  // truncate-and-write calls splice the longer write's tail onto the
  // shorter write's body. Result: malformed JSON. Sync write closes
  // the race entirely and the file is small enough that the lost
  // async-ness doesn't matter.
  Future<void> updateConfig(NixblitzConfig config) async {
    _configService.writeConfigSync(config);
    state = AsyncValue.data(config);
  }

  Future<void> reload() async => _load();
}
