import 'package:test/test.dart';
import 'package:common/src/services/install_service.dart';

void main() {
  group('InstallService', () {
    group('parseLsblkOutput', () {
      test('parses disk list from lsblk JSON', () {
        const output = '{"blockdevices":[{"name":"sda","size":256060514304,"model":"Samsung SSD","rm":false,"type":"disk"},{"name":"sdb","size":1000204886016,"model":"WD Blue","rm":false,"type":"disk"},{"name":"sr0","size":1073741312,"model":"Virtual CD","rm":true,"type":"rom"}]}';
        final disks = InstallService.parseLsblkOutput(output);
        expect(disks.length, 2);
        expect(disks[0].name, 'sda');
        expect(disks[0].path, '/dev/sda');
        expect(disks[0].model, 'Samsung SSD');
        expect(disks[1].name, 'sdb');
      });

      test('handles empty disk list', () {
        const output = '{"blockdevices":[]}';
        final disks = InstallService.parseLsblkOutput(output);
        expect(disks, isEmpty);
      });

      test('filters out rom devices', () {
        const output = '{"blockdevices":[{"name":"sr0","size":1073741312,"model":"CD-ROM","rm":true,"type":"rom"},{"name":"vda","size":21474836480,"model":null,"rm":false,"type":"disk"}]}';
        final disks = InstallService.parseLsblkOutput(output);
        expect(disks.length, 1);
        expect(disks[0].name, 'vda');
      });
    });

    group('detectPlatform', () {
      test('detects x86 from cpuinfo', () {
        const cpuinfo = 'processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel Core i7\n';
        expect(InstallService.detectPlatformFromCpuinfo(cpuinfo), 'x86');
      });

      test('Pi 4 falls through to x86 (unsupported, fail loudly)', () {
        // Pi 4 isn't a supported platform — running a Bitcoin
        // node on 4GB RAM + SD-card I/O is a bad experience and
        // we'd rather the rebuild bail than silently produce an
        // image that thrashes.
        const cpuinfo = 'Hardware\t: BCM2835\nRevision\t: d03114\nModel\t: Raspberry Pi 4 Model B Rev 1.4\n';
        expect(InstallService.detectPlatformFromCpuinfo(cpuinfo), 'x86');
      });

      test('detects pi5 from cpuinfo', () {
        const cpuinfo = 'Hardware\t: BCM2835\nRevision\t: c04170\nModel\t: Raspberry Pi 5 Model B Rev 1.0\n';
        expect(InstallService.detectPlatformFromCpuinfo(cpuinfo), 'pi5');
      });
    });

    group('parseDiskoStep', () {
      test('detects sgdisk step', () {
        expect(InstallService.parseDiskoStep('+ sgdisk --clear /dev/sda'), 'Partitioning disk...');
      });

      test('detects mount step', () {
        expect(InstallService.parseDiskoStep('+ mount /dev/disk/by-partlabel/root /mnt'), 'Mounting filesystems...');
      });

      test('detects bootloader step', () {
        expect(InstallService.parseDiskoStep('installing the boot loader...'), 'Installing bootloader...');
      });

      test('returns null for unknown line', () {
        expect(InstallService.parseDiskoStep('some random output'), isNull);
      });
    });
  });

  group('installerAttributeFor', () {
    test('pi5 → nixblitz-pi5-installer', () {
      // Pi 5 install needs the aarch64 target with vendor kernel
      // + matched firmware from nvmd/nixos-raspberrypi; landing
      // x86_64 disko-install onto a Pi 5 fails at copy, with a
      // confusing error. Pin this so a future refactor doesn't
      // accidentally swap the mapping.
      expect(installerAttributeFor('pi5'), 'nixblitz-pi5-installer');
    });

    test('x86 / vm / unknown → nixblitz-installer', () {
      expect(installerAttributeFor('x86'), 'nixblitz-installer');
      expect(installerAttributeFor('vm'), 'nixblitz-installer');
      // Unknown strings fall through to the x86 default; better
      // than throwing, since `disko-install` rejects a missing
      // attribute or wrong arch loudly enough on its own.
      expect(installerAttributeFor(''), 'nixblitz-installer');
      expect(installerAttributeFor('martian'), 'nixblitz-installer');
    });
  });
}
