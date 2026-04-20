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

  Future<void> writeConfig(NixblitzConfig config) async {
    final file = File(configPath);
    await file.writeAsString(config.toJsonString());
  }

  void writeConfigSync(NixblitzConfig config) {
    final file = File(configPath);
    file.writeAsStringSync(config.toJsonString());
  }
}
