import 'package:common/src/models/plugin/plugin_manifest_error.dart';

/// Command a plugin declares so nixblitz can read the *app* version —
/// the real software it manages (Bitcoin Core, LND, …) — on demand.
///
/// Distinct from the plugin's own packaging [PluginManifest.version]:
/// the app version is read at runtime from the running app, so it
/// can't drift from what's actually built. A plugin with no underlying
/// app of its own (e.g. an internal helper) omits this; callers then
/// fall back to the plugin version.
class AppVersionCommand {
  /// Executable to launch, resolved against the plugin checkout's PATH
  /// and run with the plugin dir as cwd. Required non-empty.
  final String command;

  /// Argv passed to [command]. May be empty. Always unmodifiable.
  final List<String> args;

  AppVersionCommand({required this.command, List<String> args = const []})
    : args = List<String>.unmodifiable(args);

  factory AppVersionCommand.fromJson(Map<String, dynamic> json) {
    final command = json['command'];
    if (command is! String || command.isEmpty) {
      throw const PluginManifestError(
        'app_version.command is required and must be a non-empty string',
      );
    }
    final rawArgs = json['args'];
    final List<String> args;
    if (rawArgs == null) {
      args = const [];
    } else if (rawArgs is List) {
      args = rawArgs.map((a) {
        if (a is! String) {
          throw PluginManifestError(
            'app_version.args entries must be strings, got ${a.runtimeType}',
          );
        }
        return a;
      }).toList();
    } else {
      throw const PluginManifestError(
        'app_version.args must be a list of strings',
      );
    }
    return AppVersionCommand(command: command, args: args);
  }

  Map<String, dynamic> toJson() => {
    'command': command,
    if (args.isNotEmpty) 'args': args,
  };
}
