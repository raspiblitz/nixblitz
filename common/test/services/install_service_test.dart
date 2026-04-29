import 'package:test/test.dart';
import 'package:common/src/models/install_state.dart';
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

  group('partitionToParentDisk', () {
    test('strips digit suffix from SCSI / IDE / virtio names', () {
      // sdaN, vdaN, hdaN — all share the simple <letters><digits>
      // partition naming. Common on x86 SATA and qemu virtio.
      expect(InstallService.partitionToParentDisk('sda1'), 'sda');
      expect(InstallService.partitionToParentDisk('sdb12'), 'sdb');
      expect(InstallService.partitionToParentDisk('vda3'), 'vda');
    });

    test('strips pN suffix from NVMe / mmcblk / loop names', () {
      // NVMe and mmcblk use `<disk>p<N>`, so the disk root itself
      // ends in a digit; a naive trailing-digit strip would
      // mangle it. loop devices follow the same pattern; they're
      // already filtered upstream but the helper should still
      // round-trip them correctly.
      expect(InstallService.partitionToParentDisk('nvme0n1p1'), 'nvme0n1');
      expect(InstallService.partitionToParentDisk('mmcblk0p2'), 'mmcblk0');
      expect(InstallService.partitionToParentDisk('loop0'), 'loop0');
    });

    test('returns bare disk names unchanged', () {
      expect(InstallService.partitionToParentDisk('sda'), 'sda');
      expect(InstallService.partitionToParentDisk('nvme0n1'), 'nvme0n1');
      expect(InstallService.partitionToParentDisk('mmcblk0'), 'mmcblk0');
    });
  });

  group('parseProcMountsBootDevice', () {
    test('returns the parent disk for /iso (NixOS live ISO)', () {
      // Real /proc/mounts shape: device, mountpoint, fs, opts,
      // dump, pass — space-separated. Reproduces the layout
      // the operator hit (USB stick at /iso, squashfs loop,
      // tmpfs /run).
      const mounts = '''
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
/dev/sdb1 /iso vfat rw,relatime,fmask=0022 0 0
/dev/loop0 /nix/.ro-store squashfs ro,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev,size=2G 0 0
''';
      expect(InstallService.parseProcMountsBootDevice(mounts), 'sdb');
    });

    test('returns null when no live mount is present', () {
      // Installed system: /iso isn't mounted, /run/initramfs/live
      // either. Annotation just doesn't fire and the picker
      // shows the raw lsblk list.
      const mounts = '''
proc /proc proc rw 0 0
/dev/sda2 / ext4 rw 0 0
''';
      expect(InstallService.parseProcMountsBootDevice(mounts), isNull);
    });

    test('falls back to /run/initramfs/live for non-NixOS images', () {
      // Some other live distributions mount their boot media at
      // /run/initramfs/live. We don't currently install on top
      // of those, but the helper should handle the convention
      // so the code stays portable.
      const mounts = '''
/dev/nvme0n1p1 /run/initramfs/live vfat rw 0 0
''';
      expect(InstallService.parseProcMountsBootDevice(mounts), 'nvme0n1');
    });
  });

  group('annotateDisks', () {
    test('flags zero-byte disks as noMedia', () {
      // The empty multi-card-reader case. Trivially uninstallable;
      // hide it so the operator doesn't waste time picking it.
      final disks = [
        const DiskInfo(
          name: 'sdc',
          path: '/dev/sdc',
          sizeBytes: 0,
          model: 'Multi-Card',
          removable: true,
        ),
      ];
      final annotated = InstallService.annotateDisks(disks);
      expect(annotated.first.filterReason, DiskFilterReason.noMedia);
    });

    test('flags the boot device', () {
      // The user's reported case: they booted from a 64 GB USB
      // stick (`sdb`); picking it would corrupt the live image
      // mid-install. Tag it so it's hidden by default.
      final disks = [
        const DiskInfo(
          name: 'sda',
          path: '/dev/sda',
          sizeBytes: 1000204886016,
          model: 'Samsung SSD',
          removable: false,
        ),
        const DiskInfo(
          name: 'sdb',
          path: '/dev/sdb',
          sizeBytes: 64 * 1000 * 1000 * 1000,
          model: 'SanDisk',
          removable: true,
        ),
      ];
      final annotated = InstallService.annotateDisks(
        disks,
        bootDeviceName: 'sdb',
      );
      expect(annotated[0].filterReason, isNull);
      expect(annotated[1].filterReason, DiskFilterReason.bootDevice);
    });

    test('flags disks below the documented minimum', () {
      // 30 GB threshold matches getting-started.md's stated
      // minimum. 16 GB SD cards or small thumb drives shouldn't
      // tempt the operator into a doomed install.
      final disks = [
        const DiskInfo(
          name: 'sda',
          path: '/dev/sda',
          sizeBytes: 16 * 1000 * 1000 * 1000,
          model: 'Small thumb',
          removable: true,
        ),
      ];
      final annotated = InstallService.annotateDisks(disks);
      expect(annotated.first.filterReason, DiskFilterReason.tooSmall);
    });

    test('priority order: noMedia > bootDevice > tooSmall', () {
      // A zero-byte disk that happens to share the boot-device
      // name still reads as "no media" first — the operator's
      // takeaway is "no card inserted", not "would corrupt
      // boot." Pin the precedence so a refactor can't quietly
      // re-order it.
      final disks = [
        const DiskInfo(
          name: 'sdb',
          path: '/dev/sdb',
          sizeBytes: 0,
          model: '',
          removable: true,
        ),
      ];
      final annotated = InstallService.annotateDisks(
        disks,
        bootDeviceName: 'sdb',
      );
      expect(annotated.first.filterReason, DiskFilterReason.noMedia);
    });

    test('viable disks pass through unchanged', () {
      const disk = DiskInfo(
        name: 'sda',
        path: '/dev/sda',
        sizeBytes: 1000204886016,
        model: 'Samsung SSD 860 EVO 1TB',
        removable: false,
      );
      final annotated = InstallService.annotateDisks([disk]);
      expect(annotated.first.filterReason, isNull);
      expect(identical(annotated.first, disk), isTrue);
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

  group('parseFindmntOutput', () {
    test('parses size + fstype from findmnt output', () {
      // `findmnt -bn -o SIZE,FSTYPE --target /` shape: a single
      // line with two whitespace-separated fields.
      final r = InstallService.parseFindmntOutput('4137459712 tmpfs');
      expect(r, isNotNull);
      expect(r!.sizeBytes, 4137459712);
      expect(r.fstype, 'tmpfs');
    });

    test('handles trailing newline (real findmnt output)', () {
      final r = InstallService.parseFindmntOutput('4137459712 tmpfs\n');
      expect(r!.sizeBytes, 4137459712);
      expect(r.fstype, 'tmpfs');
    });

    test('returns null on empty input', () {
      // Empty stdout — caller treats as "skip this path" rather
      // than crashing.
      expect(InstallService.parseFindmntOutput(''), isNull);
      expect(InstallService.parseFindmntOutput('   \n'), isNull);
    });

    test('returns null when size column is non-numeric', () {
      // findmnt sometimes prints '0' or '-' for unknown sizes;
      // treat non-int values as "skip" rather than guessing.
      expect(InstallService.parseFindmntOutput('- tmpfs'), isNull);
    });

    test('returns null when only one field is present', () {
      expect(InstallService.parseFindmntOutput('4137459712'), isNull);
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
