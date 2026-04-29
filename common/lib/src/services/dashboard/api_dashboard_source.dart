import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/dashboard/snapshots.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/blitz_api/blitz_api_client.dart';
import 'package:common/src/services/dashboard/dashboard_data_source.dart';
import 'package:common/src/services/log_service.dart';

/// Ancillary services polled via systemctl. Bitcoin / LND / CLN
/// health is inferred from whether their SSE events keep coming, so
/// they don't need to live here.
const _kAncillaryServices = ['blitz-api', 'blitz-web', 'nginx', 'redis'];

const _kServicePollInterval = Duration(seconds: 10);

/// Consumes SSE events from [BlitzApiClient] and demultiplexes them
/// into four typed snapshot streams.
///
/// The API emits narrow events (`btc_info`, `btc_mempool_status`,
/// `wallet_balance`, …) — each carrying only the fields it owns.
/// Merging against the last-seen snapshot keeps fields in view when a
/// partial update arrives.
class ApiDashboardSource implements DashboardDataSource {
  final BlitzApiClient _client;
  final bool _ownsClient;

  final _systemCtrl = StreamController<SystemSnapshot?>.broadcast();
  final _hardwareCtrl = StreamController<HardwareSnapshot?>.broadcast();
  final _btcCtrl = StreamController<BtcSnapshot?>.broadcast();
  final _lnCtrl = StreamController<LnSnapshot?>.broadcast();

  SystemSnapshot? _system;
  HardwareSnapshot? _hardware;
  BtcSnapshot? _btc;
  LnSnapshot? _ln;

  StreamSubscription? _sub;
  Timer? _serviceTimer;

  /// Captured from the first `hardware_info` event. Lets us refresh
  /// `uptime` on every service poll instead of only when the API
  /// re-broadcasts hardware_info (it suppresses identical payloads,
  /// so on idle nodes updates can lag).
  DateTime? _bootTime;

  /// [seedSystem] is the initial SystemSnapshot the caller hands in
  /// (usually hostname/platform/network from config.json) so we can
  /// render the System tile before the first `system_info` SSE event
  /// lands.
  ApiDashboardSource({BlitzApiClient? client, SystemSnapshot? seedSystem})
    : _client = client ?? BlitzApiClient(),
      _ownsClient = client == null {
    _system = seedSystem;
    _start();
  }

  @override
  Stream<SystemSnapshot?> get system => _systemCtrl.stream;
  @override
  Stream<HardwareSnapshot?> get hardware => _hardwareCtrl.stream;
  @override
  Stream<BtcSnapshot?> get bitcoin => _btcCtrl.stream;
  @override
  Stream<LnSnapshot?> get lightning => _lnCtrl.stream;

  @override
  SystemSnapshot? get seedSystem => _system;
  @override
  HardwareSnapshot? get seedHardware => _hardware;
  @override
  BtcSnapshot? get seedBitcoin => _btc;
  @override
  LnSnapshot? get seedLightning => _ln;

  @override
  Future<void> dispose() async {
    _serviceTimer?.cancel();
    _serviceTimer = null;
    await _sub?.cancel();
    _sub = null;
    if (_ownsClient) await _client.dispose();
    await _systemCtrl.close();
    await _hardwareCtrl.close();
    await _btcCtrl.close();
    await _lnCtrl.close();
  }

  // ── private ──────────────────────────────────────────────────

  void _start() {
    // Push the seed so late subscribers see something right away.
    if (_system != null) _systemCtrl.add(_system);

    _sub = _client.events.listen(_onEvent);
    unawaited(
      _client.start().catchError((e, st) {
        LogService.error('ApiDashboardSource failed to start', e, st);
      }),
    );

    // Systemd status for ancillary services isn't on the SSE stream;
    // poll locally and merge into the SystemSnapshot.
    _pollServices();
    _serviceTimer = Timer.periodic(
      _kServicePollInterval,
      (_) => _pollServices(),
    );
  }

  Future<void> _pollServices() async {
    try {
      final results = await Future.wait(_kAncillaryServices.map(_checkService));
      final map = Map<String, ServiceState>.fromEntries(results);
      final prev = _system;
      if (prev != null) {
        final uptime = _bootTime == null
            ? prev.uptime
            : DateTime.now().difference(_bootTime!);
        _system = prev.copyWith(services: map, uptime: uptime);
        _systemCtrl.add(_system);
      }
    } catch (e, st) {
      LogService.error('ApiDashboardSource service poll failed', e, st);
    }
  }

  Future<MapEntry<String, ServiceState>> _checkService(String unit) async {
    try {
      final r = await Process.run('systemctl', ['is-active', unit]);
      final out = (r.stdout as String).trim();
      return MapEntry(unit, _parseState(out));
    } catch (_) {
      return MapEntry(unit, ServiceState.unknown);
    }
  }

  ServiceState _parseState(String s) {
    switch (s) {
      case 'active':
        return ServiceState.running;
      case 'inactive':
      case 'dead':
        return ServiceState.stopped;
      case 'failed':
        return ServiceState.failed;
      case 'activating':
      case 'reloading':
        return ServiceState.activating;
      default:
        return ServiceState.unknown;
    }
  }

  /// Events whose `data:` payload is JSON we know how to parse. Any
  /// other event short-circuits before the `jsonDecode` — saves a
  /// parse on the ignore-path AND, more importantly, stops blitz-api
  /// events with bare-string payloads (`LN_INVOICE_STATUS` ships a
  /// timestamp like `2026-04-24 14:12:39.672868`, not JSON) from
  /// flooding the log with `FormatException` traces. See issue #1.
  static const _kHandledEvents = <String>{
    'btc_info',
    'btc_mempool_status',
    'btc_network_status',
    'ln_info',
    'wallet_balance',
    'hardware_info',
    'system_info',
  };

  void _onEvent(dynamic ev) {
    final String event;
    final String rawData;
    try {
      event = ev.event as String;
      rawData = ev.data as String;
    } catch (e) {
      LogService.warn('ApiDashboardSource: malformed SSE event object: $e');
      return;
    }

    // Ignore events we don't surface (LN_INVOICE_STATUS,
    // APP_MANAGE_MESSAGE, …). Doing this BEFORE the JSON decode
    // means a non-JSON payload on an ignored event is silent — no
    // log noise, no stack trace.
    if (!_kHandledEvents.contains(event)) return;
    if (rawData.isEmpty) return;

    final Map<String, dynamic> m;
    try {
      final json = jsonDecode(rawData);
      if (json is! Map) {
        LogService.warn(
          'ApiDashboardSource: $event payload is not a JSON object '
          '(got ${json.runtimeType}); skipping',
        );
        return;
      }
      m = json.cast<String, dynamic>();
    } on FormatException catch (e) {
      // Handled events that *should* be JSON occasionally aren't
      // (e.g. blitz-api transient stream framing glitches). Log a
      // single warn line — no stack trace, no escalating volume.
      final preview = rawData.length > 80
          ? '${rawData.substring(0, 80)}…'
          : rawData;
      LogService.warn(
        'ApiDashboardSource: $event payload not JSON (${e.message}); '
        'data preview: $preview',
      );
      return;
    }

    try {
      _dispatchEvent(event, m);
    } catch (e, st) {
      // Real bug in our own dispatch code (typo, missing field
      // assumption, etc.). Keep the full trace here.
      LogService.error('ApiDashboardSource dispatch failure for $event', e, st);
    }
  }

  void _dispatchEvent(String event, Map<String, dynamic> m) {
    switch (event) {
      case 'btc_info':
        _btc = BtcSnapshot.fromBtcInfo(m, prev: _btc);
        _btcCtrl.add(_btc);
      case 'btc_mempool_status':
        final prev = _btc;
        if (prev != null) {
          _btc = prev.copyWith(
            mempoolTxs: (m['size'] as num?)?.toInt() ?? prev.mempoolTxs,
            mempoolBytes: (m['bytes'] as num?)?.toInt() ?? prev.mempoolBytes,
          );
          _btcCtrl.add(_btc);
        }
      case 'btc_network_status':
        // connections_in/out in case btc_info hasn't landed yet.
        final peers =
            ((m['connections_in'] as num?)?.toInt() ?? 0) +
            ((m['connections_out'] as num?)?.toInt() ?? 0);
        _btc = (_btc ?? BtcSnapshot.fromBtcInfo(const {})).copyWith(
          peers: peers,
        );
        _btcCtrl.add(_btc);
      case 'ln_info':
        _ln = LnSnapshot.fromLnInfo(m, prev: _ln);
        _lnCtrl.add(_ln);
      case 'wallet_balance':
        final onChain =
            (m['onchain_confirmed_balance'] as num?)?.toInt() ??
            _ln?.onChainSats ??
            0;
        // API reports channel balances in msat.
        final localMsat = (m['channel_local_balance'] as num?)?.toInt() ?? 0;
        final channelSats = localMsat ~/ 1000;
        _ln = (_ln ?? LnSnapshot.fromLnInfo(const {})).copyWith(
          onChainSats: onChain,
          channelSats: channelSats,
        );
        _lnCtrl.add(_ln);
      case 'hardware_info':
        _hardware = HardwareSnapshot.fromApi(m);
        _hardwareCtrl.add(_hardware);

        // Uptime derives from boot_time_timestamp (unix seconds).
        // Cache the boot time so the service poll timer can tick
        // uptime forward even when hardware_info isn't re-emitted.
        final bootTs = (m['boot_time_timestamp'] as num?)?.toDouble();
        if (bootTs != null) {
          _bootTime = DateTime.fromMillisecondsSinceEpoch(
            (bootTs * 1000).toInt(),
          );
          final prev = _system;
          if (prev != null) {
            _system = prev.copyWith(
              uptime: DateTime.now().difference(_bootTime!),
            );
            _systemCtrl.add(_system);
          }
        }
      case 'system_info':
        final prev = _system;
        if (prev != null) {
          // Don't overwrite platform from BAPI_PLATFORM
          // (native_python / raspiblitz) — the seed carries the
          // nixblitz platform (vm / x86 / pi5) which is what the
          // user expects to see.
          _system = prev.copyWith(
            network: (m['chain'] as String?) ?? prev.network,
          );
          _systemCtrl.add(_system);
        }
    }
  }
}
