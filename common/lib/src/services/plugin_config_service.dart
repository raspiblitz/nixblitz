import 'dart:convert';
import 'dart:io';

/// Read/write the per-plugin `config.json` that sits inside each
/// `~/nixblitz/plugins/<dirName>/` directory. This is separate from
/// the main NixBlitz config (handled by `ConfigService`) — plugins
/// own their own settings file so edits don't churn the main
/// config's diff view (see docs/decisions/plugins.md D3).
class PluginConfigService {
  final String baseDir;

  PluginConfigService({required this.baseDir});

  String _pluginDir(String dirName) => '$baseDir/plugins/$dirName';
  String _configPath(String dirName) => '${_pluginDir(dirName)}/config.json';

  bool isInstalled(String dirName) =>
      Directory(_pluginDir(dirName)).existsSync();

  /// Read the plugin's config as a raw JSON map. Missing or empty
  /// files return `{}`. Throws [FormatException] if the file exists
  /// but isn't valid JSON.
  Map<String, dynamic> read(String dirName) {
    final f = File(_configPath(dirName));
    if (!f.existsSync()) return <String, dynamic>{};
    final text = f.readAsStringSync().trim();
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw FormatException(
        'plugins/$dirName/config.json: expected a JSON object, '
        'got ${decoded.runtimeType}',
      );
    }
    return decoded.cast<String, dynamic>();
  }

  /// Overwrite the plugin's config.json with [cfg], pretty-printed.
  /// Creates the file if needed; assumes the plugin dir exists
  /// (install() makes it).
  Future<void> write(String dirName, Map<String, dynamic> cfg) async {
    final f = File(_configPath(dirName));
    await f.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(cfg)}\n',
    );
  }
}
