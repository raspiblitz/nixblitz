@TestOn('linux')
library;

import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:common/src/models/nixblitz_config.dart';
import 'package:common/src/providers/config_provider.dart';
import 'package:common/src/providers/config_watcher_provider.dart';
import 'package:common/src/services/config_service.dart';

/// Helper: pump the event loop until [predicate] is true or
/// [timeout] elapses. Lets the watcher's `Directory.watch` stream
/// + the 250 ms debounce timer + the resulting `notifier.reload`
/// all settle before the test asserts. Polling is cheap (every
/// 25 ms) and the alternative — sleeping a fixed duration —
/// would either be flaky on slow CI or wasteful when the event
/// arrives sooner.
Future<bool> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return predicate();
}

void main() {
  group('configWatcherProvider', () {
    late Directory home;
    late ConfigService configService;

    setUp(() async {
      home = Directory.systemTemp.createTempSync('nixblitz_cwp_');
      configService = ConfigService(baseDir: home.path);
      // Seed a config so configProvider.load lands AsyncData
      // immediately rather than sitting in loading.
      await configService.writeConfig(NixblitzConfig.defaults());
    });

    tearDown(() {
      home.deleteSync(recursive: true);
    });

    test('external write to config.json triggers reload', () async {
      final container = ProviderContainer(
        overrides: [baseDirProvider.overrideWithValue(home.path)],
      );
      addTearDown(container.dispose);

      // Force the providers to instantiate.
      container.read(configProvider);
      container.read(configWatcherProvider);

      // Wait for the initial async load to settle.
      await _waitFor(() => container.read(configProvider).value != null);
      final initial = container.read(configProvider).value!;
      expect(initial.system.hostname, 'nixblitz');

      // External write — bypassing the notifier entirely so the
      // only path back to `configProvider` is the watcher.
      final mutated = initial.copyWith(
        system: initial.system.copyWith(hostname: 'externally-set'),
      );
      await configService.writeConfig(mutated);

      final reloaded = await _waitFor(() {
        final v = container.read(configProvider).value;
        return v != null && v.system.hostname == 'externally-set';
      });
      expect(
        reloaded,
        isTrue,
        reason: 'configProvider should pick up external write',
      );
    });

    test('plugin manifest write triggers reload', () async {
      // Adding a plugin in another shell drops a manifest.json
      // under plugins/<dirName>/ AND mutates main config.json. The
      // main-config write is the primary trigger, but a manifest
      // write alone (e.g. a refresh that updated the manifest
      // without bumping the entry) should also count — the
      // dashboard service rereads manifests off the back of
      // configProvider changes.
      final container = ProviderContainer(
        overrides: [baseDirProvider.overrideWithValue(home.path)],
      );
      addTearDown(container.dispose);

      container.read(configProvider);
      container.read(configWatcherProvider);
      await _waitFor(() => container.read(configProvider).value != null);

      // Track reload-events by listening to the provider state.
      // Riverpod re-emits even on identical values, so a single
      // reload registers as one notification.
      var emissions = 0;
      container.listen(
        configProvider,
        (_, _) => emissions++,
        fireImmediately: false,
      );

      Directory('${home.path}/plugins/foo').createSync(recursive: true);
      File(
        '${home.path}/plugins/foo/manifest.json',
      ).writeAsStringSync('{"manifest":{"schema_version":2}}');

      final fired = await _waitFor(() => emissions > 0);
      expect(fired, isTrue, reason: 'manifest write should trigger a reload');
    });

    test('per-plugin config.json write does NOT trigger reload', () async {
      // Per-plugin config writes happen on every keystroke in the
      // Configure view's plugin form. Reloading the main config on
      // every one of those would churn the dashboard pollers and
      // pendingChangesProvider for no benefit — they have their
      // own reactivity. Filter pins this down.
      //
      // Pre-create the plugin dir so the test exercises only the
      // per-plugin config.json write — in production, by the time
      // the operator is editing form fields, the plugin's directory
      // already exists from `plugin add`.
      Directory('${home.path}/plugins/foo').createSync(recursive: true);
      File(
        '${home.path}/plugins/foo/manifest.json',
      ).writeAsStringSync('{"manifest":{"schema_version":2}}');
      File('${home.path}/plugins/foo/config.json').writeAsStringSync('{}');

      final container = ProviderContainer(
        overrides: [baseDirProvider.overrideWithValue(home.path)],
      );
      addTearDown(container.dispose);

      container.read(configProvider);
      container.read(configWatcherProvider);
      await _waitFor(() => container.read(configProvider).value != null);

      var emissions = 0;
      container.listen(
        configProvider,
        (_, _) => emissions++,
        fireImmediately: false,
      );

      // Mutate the per-plugin config the same way the Configure
      // view does on each keystroke.
      File(
        '${home.path}/plugins/foo/config.json',
      ).writeAsStringSync('{"some":"value"}');

      // 250 ms debounce + a margin. If the watcher *was* going to
      // trigger, it would have done so by now. Bail with a fast
      // negative assertion rather than waiting the full 3 s
      // timeout — that'd just slow the suite.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        emissions,
        0,
        reason: 'per-plugin config writes should be ignored',
      );
    });

    test('irrelevant file writes are ignored', () async {
      // README, .git/, log files, etc. — none of these change the
      // shape of what the TUI renders, so the watcher should not
      // wake the rest of the provider chain for them.
      final container = ProviderContainer(
        overrides: [baseDirProvider.overrideWithValue(home.path)],
      );
      addTearDown(container.dispose);

      container.read(configProvider);
      container.read(configWatcherProvider);
      await _waitFor(() => container.read(configProvider).value != null);

      var emissions = 0;
      container.listen(
        configProvider,
        (_, _) => emissions++,
        fireImmediately: false,
      );

      File('${home.path}/README.md').writeAsStringSync('hello');
      File('${home.path}/random.txt').writeAsStringSync('content');

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(emissions, 0, reason: 'irrelevant writes should be ignored');
    });

    test('debounces a burst of writes into a single reload', () async {
      // `nixblitz plugin add` writes config.json plus several
      // files under plugins/<id>/ in quick succession. The
      // watcher should collapse that into one reload, not spam
      // four. 250 ms is the debounce window.
      //
      // Pre-create the plugin dir so the burst events all reach
      // the watcher (a fresh-from-mkdir subdir suffers the
      // inotify-attach race).
      Directory('${home.path}/plugins/foo').createSync(recursive: true);

      final container = ProviderContainer(
        overrides: [baseDirProvider.overrideWithValue(home.path)],
      );
      addTearDown(container.dispose);

      container.read(configProvider);
      container.read(configWatcherProvider);
      await _waitFor(() => container.read(configProvider).value != null);

      var emissions = 0;
      container.listen(
        configProvider,
        (_, _) => emissions++,
        fireImmediately: false,
      );

      // Burst: simulate the plugin-add write pattern.
      Directory('${home.path}/plugins/foo').createSync(recursive: true);
      File(
        '${home.path}/plugins/foo/manifest.json',
      ).writeAsStringSync('{"manifest":{"schema_version":2}}');
      await configService.writeConfig(
        NixblitzConfig.defaults().copyWith(
          system: const SystemConfig(
            hostname: 'burst',
            timezone: 'UTC',
            platform: 'x86',
          ),
        ),
      );
      File(
        '${home.path}/plugins/foo/manifest.json',
      ).writeAsStringSync('{"manifest":{"schema_version":2,"name":"foo"}}');

      // Wait long enough for the debounce to fire and settle.
      await _waitFor(() => emissions > 0);
      // Wait a touch longer to confirm no second emission rolls in.
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(
        emissions,
        1,
        reason: 'debounce should collapse the burst to one reload',
      );
    });
  });
}
