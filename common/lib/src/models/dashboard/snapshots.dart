/// Typed snapshots the dashboard tiles consume. Produced by a
/// `DashboardDataSource` implementation (blitz-api SSE today, CLI
/// polling in the future). Keep the surface minimal — add fields
/// only when a tile actually renders them.
library;

import 'package:common/src/models/service_status.dart';

/// System-level snapshot: identity + uptime + process health for
/// ancillary services (blitz-api, blitz-web, nginx, redis). Bitcoin /
/// LN status live in their own tiles.
class SystemSnapshot {
  final String hostname;
  final String platform;
  final String network;
  final Duration uptime;
  final Map<String, ServiceState> services;

  const SystemSnapshot({
    required this.hostname,
    required this.platform,
    required this.network,
    required this.uptime,
    required this.services,
  });

  SystemSnapshot copyWith({
    String? hostname,
    String? platform,
    String? network,
    Duration? uptime,
    Map<String, ServiceState>? services,
  }) =>
      SystemSnapshot(
        hostname: hostname ?? this.hostname,
        platform: platform ?? this.platform,
        network: network ?? this.network,
        uptime: uptime ?? this.uptime,
        services: services ?? this.services,
      );
}

/// Hardware snapshot: the handful of stats we show (CPU + memory +
/// primary data-dir disk). The API's hardware_info event carries a
/// lot more (per-CPU, swap, sensors, NICs) — parse only what we show.
class HardwareSnapshot {
  final double cpuPercent;
  final int memUsedBytes;
  final int memTotalBytes;
  final int diskUsedBytes;
  final int diskTotalBytes;

  const HardwareSnapshot({
    required this.cpuPercent,
    required this.memUsedBytes,
    required this.memTotalBytes,
    required this.diskUsedBytes,
    required this.diskTotalBytes,
  });

  /// Parse blitz-api's hardware_info event payload. Picks the partition
  /// that matches [dataMountpoint] for disk stats; falls back to root
  /// if not found.
  factory HardwareSnapshot.fromApi(
    Map<String, dynamic> json, {
    String dataMountpoint = '/mnt/data',
  }) {
    final disks = (json['disks'] as List?) ?? const [];
    Map<String, dynamic>? disk;
    for (final d in disks.whereType<Map>()) {
      if (d['mountpoint'] == dataMountpoint) {
        disk = d.cast<String, dynamic>();
        break;
      }
    }
    disk ??= disks
        .whereType<Map>()
        .cast<Map<String, dynamic>>()
        .where((d) => d['mountpoint'] == '/')
        .firstOrNull;
    disk ??= <String, dynamic>{};

    return HardwareSnapshot(
      cpuPercent: (json['cpu_overall_percent'] as num?)?.toDouble() ?? 0,
      memUsedBytes: (json['vram_used_bytes'] as num?)?.toInt() ?? 0,
      memTotalBytes: (json['vram_total_bytes'] as num?)?.toInt() ?? 0,
      diskUsedBytes: (disk['partition_used_bytes'] as num?)?.toInt() ?? 0,
      diskTotalBytes: (disk['partition_total_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Bitcoin snapshot: sync progress + peers + mempool.
class BtcSnapshot {
  final String chain;          // "main" / "test" / "regtest" / "signet"
  final int blocks;
  final int headers;
  final double verificationProgress; // 0.0 - 1.0
  final int peers;
  final int sizeOnDiskBytes;
  final int mempoolTxs;
  final int mempoolBytes;

  const BtcSnapshot({
    required this.chain,
    required this.blocks,
    required this.headers,
    required this.verificationProgress,
    required this.peers,
    required this.sizeOnDiskBytes,
    required this.mempoolTxs,
    required this.mempoolBytes,
  });

  /// btc_info event carries most of it; mempool comes from a separate
  /// btc_mempool_status event — we always merge against a prior
  /// snapshot to avoid blanking fields the current event doesn't own.
  factory BtcSnapshot.fromBtcInfo(
    Map<String, dynamic> json, {
    BtcSnapshot? prev,
  }) {
    return BtcSnapshot(
      chain: prev?.chain ?? 'main',
      blocks: (json['blocks'] as num?)?.toInt() ?? prev?.blocks ?? 0,
      headers: (json['headers'] as num?)?.toInt() ?? prev?.headers ?? 0,
      verificationProgress:
          (json['verification_progress'] as num?)?.toDouble() ??
              prev?.verificationProgress ??
              0,
      peers: ((json['connections_in'] as num?)?.toInt() ?? 0) +
          ((json['connections_out'] as num?)?.toInt() ?? 0),
      sizeOnDiskBytes:
          (json['size_on_disk'] as num?)?.toInt() ?? prev?.sizeOnDiskBytes ?? 0,
      mempoolTxs: prev?.mempoolTxs ?? 0,
      mempoolBytes: prev?.mempoolBytes ?? 0,
    );
  }

  BtcSnapshot copyWith({
    String? chain,
    int? blocks,
    int? headers,
    double? verificationProgress,
    int? peers,
    int? sizeOnDiskBytes,
    int? mempoolTxs,
    int? mempoolBytes,
  }) =>
      BtcSnapshot(
        chain: chain ?? this.chain,
        blocks: blocks ?? this.blocks,
        headers: headers ?? this.headers,
        verificationProgress:
            verificationProgress ?? this.verificationProgress,
        peers: peers ?? this.peers,
        sizeOnDiskBytes: sizeOnDiskBytes ?? this.sizeOnDiskBytes,
        mempoolTxs: mempoolTxs ?? this.mempoolTxs,
        mempoolBytes: mempoolBytes ?? this.mempoolBytes,
      );
}

/// Lightning snapshot. Implementation-agnostic — the API abstracts
/// LND/CLN into a common LnInfo shape so the tile doesn't branch.
class LnSnapshot {
  final String impl;                 // "lnd" or "cln"
  final String pubkey;
  final String alias;
  final bool syncedToChain;
  final int numPeers;
  final int numActiveChannels;
  final int numPendingChannels;
  final int onChainSats;             // confirmed on-chain balance
  final int channelSats;             // local channel balance (sats)

  const LnSnapshot({
    required this.impl,
    required this.pubkey,
    required this.alias,
    required this.syncedToChain,
    required this.numPeers,
    required this.numActiveChannels,
    required this.numPendingChannels,
    required this.onChainSats,
    required this.channelSats,
  });

  factory LnSnapshot.fromLnInfo(
    Map<String, dynamic> json, {
    LnSnapshot? prev,
  }) {
    return LnSnapshot(
      impl: (json['implementation'] as String?)?.toLowerCase() ??
          prev?.impl ??
          'lnd',
      pubkey: (json['identity_pubkey'] as String?) ?? prev?.pubkey ?? '',
      alias: (json['alias'] as String?) ?? prev?.alias ?? '',
      syncedToChain:
          (json['synced_to_chain'] as bool?) ?? prev?.syncedToChain ?? false,
      numPeers: (json['num_peers'] as num?)?.toInt() ?? prev?.numPeers ?? 0,
      numActiveChannels: (json['num_active_channels'] as num?)?.toInt() ??
          prev?.numActiveChannels ??
          0,
      numPendingChannels: (json['num_pending_channels'] as num?)?.toInt() ??
          prev?.numPendingChannels ??
          0,
      onChainSats: prev?.onChainSats ?? 0,
      channelSats: prev?.channelSats ?? 0,
    );
  }

  LnSnapshot copyWith({
    String? impl,
    String? pubkey,
    String? alias,
    bool? syncedToChain,
    int? numPeers,
    int? numActiveChannels,
    int? numPendingChannels,
    int? onChainSats,
    int? channelSats,
  }) =>
      LnSnapshot(
        impl: impl ?? this.impl,
        pubkey: pubkey ?? this.pubkey,
        alias: alias ?? this.alias,
        syncedToChain: syncedToChain ?? this.syncedToChain,
        numPeers: numPeers ?? this.numPeers,
        numActiveChannels: numActiveChannels ?? this.numActiveChannels,
        numPendingChannels: numPendingChannels ?? this.numPendingChannels,
        onChainSats: onChainSats ?? this.onChainSats,
        channelSats: channelSats ?? this.channelSats,
      );
}
