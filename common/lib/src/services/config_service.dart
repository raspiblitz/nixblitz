import 'dart:convert';
import 'dart:io';
import 'package:common/src/models/nixblitz_config.dart';

class ConfigService {
  final String baseDir;

  ConfigService({required this.baseDir});

  String get configPath => '$baseDir/config.json';

  bool configExists() => File(configPath).existsSync();

  Future<NixblitzConfig> readConfig() async {
    final file = File(configPath);
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    return NixblitzConfig.fromJson(json);
  }

  // config.json is the single source of truth, so a write must never leave a
  // half-written file behind. Write to a sibling temp file and rename over the
  // target: rename(2) within one directory is atomic on POSIX, so a crash
  // leaves either the old file or the new one intact — never a truncated one.
  Future<void> writeConfig(NixblitzConfig config) async {
    final tmp = File('$configPath.tmp');
    await tmp.writeAsString(config.toJsonString());
    await tmp.rename(configPath);
  }

  void writeConfigSync(NixblitzConfig config) {
    final tmp = File('$configPath.tmp');
    tmp.writeAsStringSync(config.toJsonString());
    tmp.renameSync(configPath);
  }
}
