import 'package:test/test.dart';
import 'package:common/src/services/install_service.dart';

void main() {
  group('InstallService', () {
    group('parseLsblkOutput', () {
      test('parses disk list from lsblk JSON', () {
        const output =
            '{"blockdevices":[{"name":"sda","size":256060514304,"model":"Samsung SSD","rm":false,"type":"disk"},{"name":"sdb","size":1000204886016,"model":"WD Blue","rm":false,"type":"disk"},{"name":"sr0","size":1073741312,"model":"Virtual CD","rm":true,"type":"rom"}]}';
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
        const output =
            '{"blockdevices":[{"name":"sr0","size":1073741312,"model":"CD-ROM","rm":true,"type":"rom"},{"name":"vda","size":21474836480,"model":null,"rm":false,"type":"disk"}]}';
        final disks = InstallService.parseLsblkOutput(output);
        expect(disks.length, 1);
        expect(disks[0].name, 'vda');
      });
    });

    group('detectPlatform', () {
      test('detects x86 from cpuinfo', () {
        const cpuinfo =
            'processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: Intel Core i7\n';
        expect(InstallService.detectPlatformFromCpuinfo(cpuinfo), 'x86');
      });

      test('Pi 4 falls through to x86 (unsupported, fail loudly)', () {
        // Pi 4 isn't a supported platform — running a Bitcoin
        // node on 4GB RAM + SD-card I/O is a bad experience and
        // we'd rather the rebuild bail than silently produce an
        // image that thrashes.
        const cpuinfo =
            'Hardware\t: BCM2835\nRevision\t: d03114\nModel\t: Raspberry Pi 4 Model B Rev 1.4\n';
        expect(InstallService.detectPlatformFromCpuinfo(cpuinfo), 'x86');
      });

      test('detects pi5 from cpuinfo', () {
        const cpuinfo =
            'Hardware\t: BCM2835\nRevision\t: c04170\nModel\t: Raspberry Pi 5 Model B Rev 1.0\n';
        expect(InstallService.detectPlatformFromCpuinfo(cpuinfo), 'pi5');
      });
    });

    group('parseDiskoStep', () {
      test('detects sgdisk step', () {
        expect(
          InstallService.parseDiskoStep('+ sgdisk --clear /dev/sda'),
          'Partitioning disk...',
        );
      });

      test('detects mount step', () {
        expect(
          InstallService.parseDiskoStep(
            '+ mount /dev/disk/by-partlabel/root /mnt',
          ),
          'Mounting filesystems...',
        );
      });

      test('detects bootloader step', () {
        expect(
          InstallService.parseDiskoStep('installing the boot loader...'),
          'Installing bootloader...',
        );
      });

      test('returns null for unknown line', () {
        expect(InstallService.parseDiskoStep('some random output'), isNull);
      });
    });
  });

  group('isVirtualDiskName', () {
    test('hides zram / loop / dm / md / sr', () {
      // Each of these is a kernel-virtual block device that
      // lsblk --type disk lists but you'd never install onto:
      //   zram0  - compressed-RAM swap (the zram we add at
      //            pre-install becomes 1TB-class disk in lsblk).
      //   loop0  - loopback file (e.g. the live ISO's squashfs).
      //   dm-0   - device-mapper / cryptsetup / LVM virtual.
      //   md0    - software RAID composite.
      //   sr0    - read-only optical.
      for (final n in ['zram0', 'zram12', 'loop0', 'dm-0', 'md0', 'sr0']) {
        expect(InstallService.isVirtualDiskName(n), isTrue, reason: n);
      }
    });

    test('keeps real-disk names', () {
      // sda / nvme / mmcblk are the canonical install targets;
      // vda is the qemu/KVM virtio block. None of these should
      // ever be filtered.
      for (final n in ['sda', 'sdb', 'nvme0n1', 'mmcblk0', 'vda']) {
        expect(InstallService.isVirtualDiskName(n), isFalse, reason: n);
      }
    });
  });

  group('parseLsblkOutput', () {
    test('drops zram from the install-target list', () {
      // Reproduces the symptom the operator hit: after pre-install
      // adds zram swap, `lsblk --type disk` lists /dev/zram0 as a
      // 6 GiB "disk", which then shows up in the picker as a
      // tempting-but-bogus install target.
      const output = '''
{
  "blockdevices": [
    {"name": "sda", "size": 1000204886016, "model": "Samsung SSD 980", "rm": false, "type": "disk"},
    {"name": "zram0", "size": 6442450944, "model": null, "rm": false, "type": "disk"}
  ]
}
''';
      final disks = InstallService.parseLsblkOutput(output);
      expect(disks.map((d) => d.name).toList(), ['sda']);
    });
  });

  group('parseMemTotalBytes', () {
    test('extracts MemTotal from /proc/meminfo', () {
      const content = '''
MemTotal:        8123456 kB
MemFree:         2200000 kB
MemAvailable:    5500000 kB
''';
      // 8123456 kB → 8318418944 bytes.
      expect(InstallService.parseMemTotalBytes(content), 8123456 * 1024);
    });

    test('returns 0 when MemTotal line is absent', () {
      expect(InstallService.parseMemTotalBytes(''), 0);
      expect(InstallService.parseMemTotalBytes('SwapTotal: 0 kB'), 0);
    });
  });

  group('parseProcSwapsTotalBytes', () {
    test('returns 0 when /proc/swaps is header-only', () {
      const content = 'Filename\tType\t\tSize\tUsed\tPriority\n';
      expect(InstallService.parseProcSwapsTotalBytes(content), 0);
    });

    test('sums sizes from active swap devices', () {
      // The sizes column is in 1024-byte units per `man 5 proc`.
      const content = '''
Filename                                Type            Size    Used    Priority
/dev/zram0                              partition       6291452 0       100
/dev/sda2                               partition       1024000 12345   50
''';
      // 6291452 kB + 1024000 kB = 7315452 kB → 7491022848 bytes.
      expect(
        InstallService.parseProcSwapsTotalBytes(content),
        (6291452 + 1024000) * 1024,
      );
    });

    test('skips malformed rows without crashing', () {
      const content = '''
Filename Type Size Used Priority
/dev/zram0 partition not-a-number 0 100
/dev/sda2 partition 512000 0 50
''';
      // The malformed row is dropped; only sda2 contributes.
      expect(InstallService.parseProcSwapsTotalBytes(content), 512000 * 1024);
    });
  });

  group('recommendedZramBytes', () {
    test('returns 0 when swap already exists', () {
      // Operator already configured swap (manual mkswap, NixOS
      // zramSwap module, etc.) — we don't second-guess them.
      expect(
        InstallService.recommendedZramBytes(
          memTotalBytes: 8 * 1024 * 1024 * 1024,
          existingSwapBytes: 1, // any non-zero
        ),
        0,
      );
    });

    test('returns 0 when RAM is unknown', () {
      // /proc/meminfo unreadable — bail rather than guess.
      expect(
        InstallService.recommendedZramBytes(
          memTotalBytes: 0,
          existingSwapBytes: 0,
        ),
        0,
      );
    });

    test('returns RAM-sized zram when no existing swap', () {
      // 8 GB RAM, no swap → 8 GB zram. Compresses ~2-3×, so
      // gives effective 16-24 GB of working memory headroom.
      const eightGb = 8 * 1024 * 1024 * 1024;
      expect(
        InstallService.recommendedZramBytes(
          memTotalBytes: eightGb,
          existingSwapBytes: 0,
        ),
        eightGb,
      );
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
