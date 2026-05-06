import 'package:common/src/models/configure/app_manifest.dart';

class AppManifestRegistry {
  final List<AppManifest> _all;

  AppManifestRegistry({
    required List<AppManifest> bundled,
    required List<AppManifest> plugin,
  }) : _all = [...bundled, ...plugin];

  List<AppManifest> get allApps => List.unmodifiable(_all);

  AppManifest? get(String id) {
    for (final m in _all) {
      if (m.id == id) return m;
    }
    return null;
  }

  List<AppManifest> withCapability(String tag) =>
      _all.where((m) => m.capabilities.contains(tag)).toList();

  /// systemd unit names for every app in the registry (honouring
  /// `service_unit` override).
  List<String> serviceIds() => _all.map((m) => m.unitName).toList();
}
