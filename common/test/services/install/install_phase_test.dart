import 'package:test/test.dart';
import 'package:common/src/services/install/install_phase.dart';
import 'package:common/src/services/install_service.dart';

void main() {
  group('installPhaseForLine', () {
    test('detects the verbatim disko-install offline markers', () {
      expect(installPhaseForLine('Copying store paths'), InstallPhase.copying);
      expect(
        installPhaseForLine('Loading nix database'),
        InstallPhase.loadingDb,
      );
    });
    test('detects partition/format/mount/build/install/done markers', () {
      expect(
        installPhaseForLine('running sgdisk ...'),
        InstallPhase.partitioning,
      );
      expect(
        installPhaseForLine('mkfs.ext4 /dev/sda2'),
        InstallPhase.formatting,
      );
      expect(
        installPhaseForLine('mount /dev/sda2 /mnt'),
        InstallPhase.mounting,
      );
      expect(
        installPhaseForLine("building '/nix/store/...'"),
        InstallPhase.building,
      );
      expect(
        installPhaseForLine('installing the boot loader'),
        InstallPhase.installing,
      );
      expect(
        installPhaseForLine('running nixos-install'),
        InstallPhase.installing,
      );
      expect(installPhaseForLine('disko-install succeeded'), InstallPhase.done);
    });
    test('nix\'s "copying path … from cache" lines do NOT flip to copying', () {
      // These fire during build/eval (fetching inputs into the LOCAL
      // store), not the store-to-disk copy — matching them parked the
      // bar at a few % against the empty target. Only disko's own
      // "Copying store paths" echo counts as the copy phase.
      expect(
        installPhaseForLine(
          "copying path '/nix/store/x' from 'https://cache.nixos.org'...",
        ),
        isNull,
      );
    });
    test('non-marker lines produce no transition', () {
      expect(installPhaseForLine('some unrelated chatter'), isNull);
      expect(installPhaseForLine(''), isNull);
    });
  });

  group('phaseLabel', () {
    test('preserves existing parseDiskoStep label strings', () {
      expect(phaseLabel(InstallPhase.partitioning), 'Partitioning disk...');
      expect(phaseLabel(InstallPhase.formatting), 'Formatting partitions...');
      expect(phaseLabel(InstallPhase.mounting), 'Mounting filesystems...');
      expect(phaseLabel(InstallPhase.copying), 'Copying NixOS store paths...');
      expect(phaseLabel(InstallPhase.installing), 'Installing bootloader...');
      expect(phaseLabel(InstallPhase.loadingDb), 'Loading Nix database...');
    });
  });

  group('parseDiskoStep delegates (behaviour preserved + markers added)', () {
    test('existing markers keep their labels', () {
      expect(
        InstallService.parseDiskoStep('running sgdisk'),
        'Partitioning disk...',
      );
      expect(
        InstallService.parseDiskoStep('boot loader'),
        'Installing bootloader...',
      );
    });
    test('now also catches the offline cp markers it used to miss', () {
      expect(
        InstallService.parseDiskoStep('Copying store paths'),
        'Copying NixOS store paths...',
      );
      expect(
        InstallService.parseDiskoStep('Loading nix database'),
        'Loading Nix database...',
      );
    });
  });
}
