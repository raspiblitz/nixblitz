enum InstallStep {
  detectSystem,
  selectDisk,
  configureServices,
  confirmInstall,
  installing,
  complete,
  failed,
}

class DiskInfo {
  final String name;
  final String path;
  final int sizeBytes;
  final String model;
  final bool removable;

  const DiskInfo({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.model,
    required this.removable,
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
