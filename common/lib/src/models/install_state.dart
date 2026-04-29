enum InstallStep {
  detectSystem,
  selectDisk,
  configureServices,
  confirmInstall,
  installing,
  complete,
  failed,
}

/// Reason a candidate disk should be hidden from the install
/// picker by default. Operators can opt into seeing all disks
/// (including filtered ones) via the picker's "Show all" toggle;
/// the reason then renders next to the disk so the operator can
/// see why we'd normally hide it.
///
/// Kernel-virtual block devices (zram/loop/dm-/md/sr) are
/// filtered unconditionally upstream in `parseLsblkOutput` and
/// don't appear here — those are never legitimate install
/// targets, so no escape hatch is offered.
enum DiskFilterReason {
  /// `lsblk` reported size 0 — typically a card reader with no
  /// card inserted. Trivially uninstallable.
  noMedia,

  /// This disk backs the currently-running live image. Picking
  /// it would corrupt the install mid-flow when disko wipes the
  /// partition table out from under us.
  bootDevice,

  /// Below the documented minimum install size (30 GB). Likely
  /// to fill mid-install or shortly after; not blocked outright,
  /// just hidden by default so undersized media (small thumb
  /// drives, leftover SD cards) doesn't tempt the operator.
  tooSmall,
}

extension DiskFilterReasonLabel on DiskFilterReason {
  /// Short human-readable tag for the disk picker's "Show all"
  /// view. Matches the language used in the install docs.
  String get label => switch (this) {
    DiskFilterReason.noMedia => 'no media',
    DiskFilterReason.bootDevice => 'boot device',
    DiskFilterReason.tooSmall => 'too small',
  };
}

class DiskInfo {
  final String name;
  final String path;
  final int sizeBytes;
  final String model;
  final bool removable;

  /// Non-null when the disk should be hidden from the picker by
  /// default. See [DiskFilterReason].
  final DiskFilterReason? filterReason;

  const DiskInfo({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.model,
    required this.removable,
    this.filterReason,
  });

  String get sizeGb => (sizeBytes / 1000000000).toStringAsFixed(1);
  String get displayName => '$name ($sizeGb GB) $model';

  factory DiskInfo.fromLsblkJson(Map<String, dynamic> json) => DiskInfo(
    name: json['name'] as String,
    path: '/dev/${json['name']}',
    sizeBytes: (json['size'] as num).toInt(),
    model: (json['model'] as String?)?.trim() ?? '',
    removable: json['rm'] == true,
  );

  DiskInfo copyWith({DiskFilterReason? filterReason}) => DiskInfo(
    name: name,
    path: path,
    sizeBytes: sizeBytes,
    model: model,
    removable: removable,
    filterReason: filterReason ?? this.filterReason,
  );
}

class SystemInfo {
  final String platform;
  final int memoryMb;
  final List<DiskInfo> disks;

  const SystemInfo({
    required this.platform,
    required this.memoryMb,
    required this.disks,
  });
}
