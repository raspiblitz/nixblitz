import 'package:common/src/models/plugin/plugin_manifest_error.dart';

/// Subprocess streamer declared by a plugin manifest (Phase 4).
///
/// A streamer is a long-running child process the TUI launches when
/// the plugin is installed and enabled. It writes JSON tile-event
/// frames to stdout, one per line; each frame carries a `tile_id`
/// which the TUI dispatches to the matching tile renderer.
///
/// [tileIds] is the *declared* set of tile ids the streamer is
/// allowed to emit for. The runtime tile-event filter rejects any
/// frame whose `tile_id` falls outside this set — that way a
/// misbehaving plugin can't squat on tiles it didn't declare in its
/// manifest. Required non-empty: a streamer that emits for no tiles
/// is meaningless.
class StreamerSpec {
  /// Identifier used in logs and process names. Required non-empty.
  final String name;

  /// Executable to launch (resolved against the plugin checkout's
  /// PATH at runtime). Required non-empty.
  final String command;

  /// Argv passed to [command]. May be empty. Always unmodifiable.
  final List<String> args;

  /// Set of tile ids this streamer is permitted to emit events for.
  /// Required non-empty. Always unmodifiable.
  final Set<String> tileIds;

  /// Constructs a [StreamerSpec], wrapping [args] and [tileIds] as
  /// unmodifiable views so the public API never exposes a mutable
  /// final field. Not `const`: const construction would defeat the
  /// unmodifiable wrapping (a `const` list passed in stays as the
  /// caller's reference).
  StreamerSpec({
    required this.name,
    required this.command,
    List<String> args = const [],
    required Set<String> tileIds,
  }) : args = List<String>.unmodifiable(args),
       tileIds = Set<String>.unmodifiable(tileIds);

  factory StreamerSpec.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) {
      throw const PluginManifestError(
        'streamer.name is required and must be a non-empty string',
      );
    }
    final command = json['command'];
    if (command is! String || command.isEmpty) {
      throw PluginManifestError(
        'streamer `$name`: command is required and must be a non-empty string',
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
            'streamer `$name`: args entries must be strings, got ${a.runtimeType}',
          );
        }
        return a;
      }).toList();
    } else {
      throw PluginManifestError(
        'streamer `$name`: args must be a list of strings',
      );
    }
    final rawTileIds = json['tile_ids'];
    if (rawTileIds is! List) {
      throw PluginManifestError(
        'streamer `$name`: tile_ids is required and must be a list',
      );
    }
    if (rawTileIds.isEmpty) {
      throw PluginManifestError(
        'streamer `$name`: tile_ids must be non-empty (a streamer with no '
        'tiles is meaningless)',
      );
    }
    final tileIds = <String>{};
    for (final t in rawTileIds) {
      if (t is! String || t.isEmpty) {
        throw PluginManifestError(
          'streamer `$name`: tile_ids entries must be non-empty strings',
        );
      }
      tileIds.add(t);
    }
    return StreamerSpec(
      name: name,
      command: command,
      args: args,
      tileIds: tileIds,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'command': command,
    if (args.isNotEmpty) 'args': args,
    'tile_ids': tileIds.toList(),
  };
}
