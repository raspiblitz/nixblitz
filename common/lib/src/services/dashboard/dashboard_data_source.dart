import 'dart:async';

import 'package:common/src/models/dashboard/snapshots.dart';

/// Drives the four dashboard tiles. Implementations pick the source
/// of truth (blitz-api SSE today, shell polling later); the tiles
/// don't care.
///
/// Each stream is a broadcast — late subscribers see the most recent
/// value via `seed*` getters (useful because the tile may mount after
/// the first event has already passed through).
abstract class DashboardDataSource {
  Stream<SystemSnapshot?> get system;
  Stream<HardwareSnapshot?> get hardware;
  Stream<BtcSnapshot?> get bitcoin;
  Stream<LnSnapshot?> get lightning;

  SystemSnapshot? get seedSystem;
  HardwareSnapshot? get seedHardware;
  BtcSnapshot? get seedBitcoin;
  LnSnapshot? get seedLightning;

  Future<void> dispose();
}

/// Fallback used when no real data source is available (e.g. blitz-api
/// disabled, and CLI source not yet implemented). Each stream emits a
/// single `null` so tiles render "unavailable" instead of "loading".
class NullDashboardSource implements DashboardDataSource {
  @override
  Stream<SystemSnapshot?> get system => Stream.value(null);
  @override
  Stream<HardwareSnapshot?> get hardware => Stream.value(null);
  @override
  Stream<BtcSnapshot?> get bitcoin => Stream.value(null);
  @override
  Stream<LnSnapshot?> get lightning => Stream.value(null);

  @override
  SystemSnapshot? get seedSystem => null;
  @override
  HardwareSnapshot? get seedHardware => null;
  @override
  BtcSnapshot? get seedBitcoin => null;
  @override
  LnSnapshot? get seedLightning => null;

  @override
  Future<void> dispose() async {}
}
