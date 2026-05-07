import 'package:common/src/models/plugin/plugin_manifest_error.dart';

/// Plugin dependency declarations parsed from `plugin.json`'s
/// top-level `requires` array (Phase 4).
///
/// A plugin can depend on:
///
/// - **Built-in apps** (`type: app`) — `bitcoind`, `lnd`, `cln`, etc.
///   Identified by their canonical app id; the dep-check task
///   resolves these against the active `NixblitzConfig` to confirm
///   the app is installed and enabled.
///
/// - **Other plugins** (`type: plugin`) — referenced by their install
///   URL (the same URL used to install them). The check confirms the
///   target plugin is currently installed by URL match in the
///   plugin registry.
///
/// [PluginDep] is a sealed type so dependency resolution can
/// `switch (dep)` exhaustively over both shapes without a fallthrough
/// branch — adding a new dependency kind in the future is a
/// compile-time error everywhere it's matched.
sealed class PluginDep {
  const PluginDep();

  factory PluginDep.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String) {
      throw PluginManifestError(
        'plugin dep is missing required `type` field (expected '
        '"app" or "plugin")',
      );
    }
    switch (type) {
      case 'app':
        final id = json['id'];
        if (id is! String || id.isEmpty) {
          throw PluginManifestError('app dep requires a non-empty `id` field');
        }
        return AppDep(id: id);
      case 'plugin':
        final url = json['url'];
        if (url is! String || url.isEmpty) {
          throw PluginManifestError(
            'plugin dep requires a non-empty `url` field',
          );
        }
        return PluginUrlDep(url: url);
      default:
        throw PluginManifestError(
          'unknown plugin dep type `$type` (expected "app" or "plugin")',
        );
    }
  }

  Map<String, dynamic> toJson();
}

/// Dependency on a built-in app, identified by its canonical id
/// (e.g. `bitcoind`, `lnd`, `cln`).
class AppDep extends PluginDep {
  final String id;

  const AppDep({required this.id});

  @override
  Map<String, dynamic> toJson() => {'type': 'app', 'id': id};
}

/// Dependency on another plugin, identified by its install URL.
/// The URL is matched verbatim against entries in the plugin
/// registry — the resolver doesn't normalise or canonicalise it
/// past a scheme smell test.
///
/// The URL must start with one of: `git+https://`, `git+ssh://`,
/// `https://`, `http://`, `file:`. This rejects whitespace-only
/// strings, bare paths, and obvious typos at manifest-load time
/// rather than letting them propagate to the dep resolver.
class PluginUrlDep extends PluginDep {
  static const _allowedSchemes = [
    'git+https://',
    'git+ssh://',
    'https://',
    'http://',
    'file:',
  ];

  final String url;

  PluginUrlDep({required String url}) : url = _validateUrl(url);

  static String _validateUrl(String url) {
    if (url.isEmpty) {
      throw const PluginManifestError(
        'PluginUrlDep.url must be a non-empty string',
      );
    }
    for (final scheme in _allowedSchemes) {
      if (url.startsWith(scheme)) return url;
    }
    throw PluginManifestError(
      'PluginUrlDep.url must start with one of: '
      '${_allowedSchemes.join(', ')}',
    );
  }

  @override
  Map<String, dynamic> toJson() => {'type': 'plugin', 'url': url};
}
