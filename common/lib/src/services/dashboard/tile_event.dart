import 'package:meta/meta.dart';

/// Single update from a [TileEventSource]. The source emits one of
/// these per logical state change; the [TileDataCache] merges
/// `data` into the per-tile snapshot.
@immutable
class TileEvent {
  final String tileId;
  final Map<String, dynamic> data;
  final DateTime ts;

  const TileEvent({required this.tileId, required this.data, required this.ts});

  @override
  bool operator ==(Object other) =>
      other is TileEvent &&
      other.tileId == tileId &&
      _mapEquals(other.data, data) &&
      other.ts == ts;

  @override
  int get hashCode => Object.hash(tileId, _mapHashCode(data), ts);
}

bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k) || a[k] != b[k]) return false;
  }
  return true;
}

int _mapHashCode(Map<String, dynamic> m) {
  var h = 0;
  for (final e in m.entries) {
    h ^= Object.hash(e.key, e.value);
  }
  return h;
}
