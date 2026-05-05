import 'package:meta/meta.dart';

/// Per-tile state the renderer consumes. Built up by the
/// [TileDataCache] from successive [TileEvent]s.
@immutable
class TileSnapshot {
  final Map<String, dynamic> data;
  final Object? lastError;
  final DateTime? lastEventTs;

  const TileSnapshot({this.data = const {}, this.lastError, this.lastEventTs});

  bool get isEmpty => data.isEmpty && lastError == null && lastEventTs == null;

  TileSnapshot copyWith({
    Map<String, dynamic>? data,
    Object? lastError,
    DateTime? lastEventTs,
    bool clearError = false,
  }) => TileSnapshot(
    data: data ?? this.data,
    lastError: clearError ? null : (lastError ?? this.lastError),
    lastEventTs: lastEventTs ?? this.lastEventTs,
  );
}
