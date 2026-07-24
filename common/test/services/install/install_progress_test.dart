import 'dart:async';
import 'package:test/test.dart';
import 'package:common/src/services/install/install_phase.dart';
import 'package:common/src/services/install/install_progress.dart';

void main() {
  group('parse helpers', () {
    test('parseDuBytes reads the leading byte count', () {
      expect(parseDuBytes('12345\t/nix/store\n'), 12345);
      expect(parseDuBytes('nonsense'), isNull);
    });
    test('parseDfUsedBytes reads the value under the "used" header', () {
      expect(parseDfUsedBytes('used\n67890\n'), 67890);
      expect(parseDfUsedBytes(''), isNull);
    });
  });

  group('InstallProgressTracker', () {
    test(
      'phase transitions emit and copy polls rise then snap to 1.0',
      () async {
        final emissions = <InstallProgress>[];
        var used = 0;
        final tracker = InstallProgressTracker(
          readTotalBytes: () async => 100,
          readUsedBytes: () async => used,
          pollInterval: const Duration(milliseconds: 10),
          onChange: emissions.add,
        );

        tracker.addLine('running sgdisk'); // partitioning
        expect(tracker.value.phase, InstallPhase.partitioning);

        tracker.addLine('Copying store paths'); // -> copying, starts poll
        expect(tracker.value.phase, InstallPhase.copying);

        used = 50;
        await Future.delayed(const Duration(milliseconds: 25));
        expect(tracker.value.copyFraction, closeTo(0.5, 0.001));

        used = 1000; // over total -> clamp
        await Future.delayed(const Duration(milliseconds: 25));
        expect(tracker.value.copyFraction, 0.99);

        tracker.addLine('Loading nix database'); // snap
        expect(tracker.value.phase, InstallPhase.loadingDb);
        expect(tracker.value.copyFraction, 1.0);

        // poll stopped: further used changes don't move the fraction
        used = 0;
        await Future.delayed(const Duration(milliseconds: 25));
        expect(tracker.value.copyFraction, 1.0);

        tracker.addLine('installing the boot loader'); // installing -> no bar
        expect(tracker.value.phase, InstallPhase.installing);
        expect(tracker.value.copyFraction, isNull);

        tracker.dispose();
        expect(emissions, isNotEmpty);
      },
    );

    test('null total keeps the bar hidden during copying', () async {
      final tracker = InstallProgressTracker(
        readTotalBytes: () async => null,
        readUsedBytes: () async => 500,
        pollInterval: const Duration(milliseconds: 10),
        onChange: (_) {},
      );
      tracker.addLine('Copying store paths');
      await Future.delayed(const Duration(milliseconds: 25));
      expect(tracker.value.phase, InstallPhase.copying);
      expect(tracker.value.copyFraction, isNull);
      tracker.dispose();
    });

    test('a used-bytes read that resolves after the phase snapped to 1.0 does '
        'not overwrite it with a stale copying fraction', () async {
      final emissions = <InstallProgress>[];
      final usedCompleter = Completer<int?>();
      final tracker = InstallProgressTracker(
        readTotalBytes: () async => 100,
        readUsedBytes: () => usedCompleter.future,
        pollInterval: const Duration(seconds: 30), // no periodic firing
        onChange: emissions.add,
      );

      tracker.addLine('Copying store paths'); // starts poll, awaits used
      expect(tracker.value.phase, InstallPhase.copying);
      // Let the microtask queue drain up to the await point inside
      // _pollOnce, but the used-bytes completer is still unresolved.
      await Future<void>.delayed(Duration.zero);

      tracker.addLine('Loading nix database'); // snaps to loadingDb / 1.0
      expect(tracker.value.phase, InstallPhase.loadingDb);
      expect(tracker.value.copyFraction, 1.0);

      final emissionsBeforeResolve = emissions.length;
      usedCompleter.complete(50); // stale poll finally resolves
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The stale copying-phase fraction must not have been emitted.
      expect(tracker.value.phase, InstallPhase.loadingDb);
      expect(tracker.value.copyFraction, 1.0);
      expect(
        emissions
            .skip(emissionsBeforeResolve)
            .any((e) => e.phase == InstallPhase.copying),
        isFalse,
      );

      tracker.dispose();
    });

    test(
      'dispose during an in-flight poll suppresses the pending emit',
      () async {
        var onChangeCalls = 0;
        final usedCompleter = Completer<int?>();
        final tracker = InstallProgressTracker(
          readTotalBytes: () async => 100,
          readUsedBytes: () => usedCompleter.future,
          pollInterval: const Duration(seconds: 30),
          onChange: (_) => onChangeCalls++,
        );

        tracker.addLine('Copying store paths'); // starts poll, awaits used
        await Future<void>.delayed(Duration.zero);

        final callsBeforeDispose = onChangeCalls;
        tracker.dispose();

        usedCompleter.complete(50); // in-flight poll resolves post-dispose
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(onChangeCalls, callsBeforeDispose);
      },
    );

    test('a later-phase copying line during the install tail does not flap '
        'the phase backward', () async {
      final emissions = <InstallProgress>[];
      final tracker = InstallProgressTracker(
        readTotalBytes: () async => 100,
        readUsedBytes: () async => 50,
        pollInterval: const Duration(milliseconds: 10),
        onChange: emissions.add,
      );

      tracker.addLine('Copying store paths'); // -> copying
      expect(tracker.value.phase, InstallPhase.copying);

      tracker.addLine('Loading nix database'); // -> loadingDb, frac 1.0
      expect(tracker.value.phase, InstallPhase.loadingDb);

      tracker.addLine('installing the boot loader'); // -> installing
      expect(tracker.value.phase, InstallPhase.installing);
      final copyFractionAtInstalling = tracker.value.copyFraction;
      final emissionsBeforeStaleLine = emissions.length;

      // nixos-install's own output tail includes nix store-copy lines
      // like this even after disko-install's phase has moved past
      // copying. installPhaseForLine still classifies it as `copying`,
      // but the monotonic guard must ignore it.
      tracker.addLine("copying path '/nix/store/x-abc'");
      expect(tracker.value.phase, InstallPhase.installing);
      expect(tracker.value.copyFraction, copyFractionAtInstalling);
      expect(emissions.length, emissionsBeforeStaleLine);

      tracker.dispose();
    });
  });
}
