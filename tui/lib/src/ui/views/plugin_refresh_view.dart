import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

/// Three-phase refresh flow surfaced from Configure → Plugins via [r].
///
/// Wraps [PluginService.refresh] and renders its three meaningful
/// outcomes:
///
/// - [_Phase.refreshing] — clone + signature check in flight.
/// - [_Phase.done] — success: rev advanced (Apply the rebuild), or
///   rev held (no-op, nothing to apply).
/// - [_Phase.signatureMismatch] — refused: the new commit's signing
///   key doesn't match the fingerprint pinned at install time. Shows
///   both fingerprints + the recovery hint (remove + re-add to
///   re-consent). Refresh is intentionally hard-fail here — we don't
///   silently accept publisher key rotation.
enum _Phase { refreshing, done, signatureMismatch }

class PluginRefreshView extends StatefulComponent {
  final PluginService pluginService;
  final String pluginId;
  final VoidCallback onDismiss;

  const PluginRefreshView({
    super.key,
    required this.pluginService,
    required this.pluginId,
    required this.onDismiss,
  });

  @override
  State<PluginRefreshView> createState() => _PluginRefreshViewState();
}

class _PluginRefreshViewState extends State<PluginRefreshView> {
  _Phase _phase = _Phase.refreshing;
  String? _resultMessage;
  PluginMarker? _resultMarker;
  PluginSignatureMismatch? _mismatch;
  String? _priorRev;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final svc = component.pluginService;
    final id = component.pluginId;

    // Capture the rev from the marker BEFORE refresh so the done
    // phase can distinguish advanced from held without re-reading.
    _priorRev = readMarker('${svc.pluginsDir}/$id')?.rev;

    svc
        .refresh(id)
        .then((marker) {
          if (!mounted) return;
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              _resultMarker = marker;
              final advanced = _priorRev != null && marker.rev != _priorRev;
              _resultMessage = advanced
                  ? 'refreshed ${marker.id}\n  pin: ${_short(marker.rev)}'
                  : '${marker.id} already at pin=${_short(marker.rev)} (no changes)';
              _phase = _Phase.done;
            });
          });
        })
        .catchError((e) {
          if (!mounted) return;
          Future.microtask(() {
            if (!mounted) return;
            if (e is PluginSignatureMismatch) {
              setState(() {
                _mismatch = e;
                _phase = _Phase.signatureMismatch;
              });
            } else {
              setState(() {
                _resultMessage = 'refresh failed: $e';
                _phase = _Phase.done;
              });
            }
          });
        });
  }

  static String _short(String rev) =>
      rev.length >= 8 ? rev.substring(0, 8) : rev;

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape ||
            (event.logicalKey == LogicalKey.enter &&
                _phase != _Phase.refreshing)) {
          component.onDismiss();
          return true;
        }
        // Refreshing phase: swallow keys so the operator can't navigate
        // away mid-clone (subprocess can't be cancelled cleanly anyway).
        return _phase == _Phase.refreshing;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _body(),
        ),
      ),
    );
  }

  List<Component> _body() {
    switch (_phase) {
      case _Phase.refreshing:
        return [
          Text(
            'Refreshing ${component.pluginId}…',
            style: const TextStyle(color: Color.fromRGB(247, 147, 26)),
          ),
        ];
      case _Phase.done:
        final advanced =
            _resultMarker != null &&
            _priorRev != null &&
            _resultMarker!.rev != _priorRev;
        final color = _resultMarker != null
            ? const Color.fromRGB(120, 200, 120)
            : const Color.fromRGB(255, 100, 100);
        return [
          Text(_resultMessage ?? '(no result)', style: TextStyle(color: color)),
          const SizedBox(height: 1),
          if (advanced)
            const Text(
              'Run the Apply view ([a] from the dashboard) to rebuild.',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          if (advanced) const SizedBox(height: 1),
          const Text(
            '[Enter / Esc] back to plugins',
            style: TextStyle(color: Color.fromRGB(110, 110, 130)),
          ),
        ];
      case _Phase.signatureMismatch:
        final m = _mismatch!;
        return [
          Text(
            'REFUSED: signing key changed for ${m.pluginId}',
            style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
          ),
          const SizedBox(height: 1),
          Text(
            '  pinned key: ${m.expected}',
            style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
          ),
          Text(
            '  new key:    ${m.actual ?? "(unsigned)"}',
            style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
          ),
          const SizedBox(height: 1),
          const Text(
            'Refresh hard-fails on key rotation so a stolen-publisher-key',
            style: TextStyle(color: Color.fromRGB(180, 180, 180)),
          ),
          const Text(
            'attack can\'t silently swap the plugin under you.',
            style: TextStyle(color: Color.fromRGB(180, 180, 180)),
          ),
          const SizedBox(height: 1),
          const Text(
            'If the new key is legitimate (publisher rotated, you trust both):',
            style: TextStyle(color: Color.fromRGB(180, 180, 180)),
          ),
          Text(
            '  1. Esc back to plugins',
            style: const TextStyle(color: Color.fromRGB(180, 180, 180)),
          ),
          Text(
            '  2. nixblitz plugin remove ${m.pluginId}',
            style: const TextStyle(color: Color.fromRGB(180, 180, 180)),
          ),
          Text(
            '  3. nixblitz plugin add    <url>',
            style: const TextStyle(color: Color.fromRGB(180, 180, 180)),
          ),
          const Text(
            '  4. Re-affirm the new fingerprint at the consent prompt.',
            style: TextStyle(color: Color.fromRGB(180, 180, 180)),
          ),
          const SizedBox(height: 1),
          const Text(
            '[Enter / Esc] back',
            style: TextStyle(color: Color.fromRGB(110, 110, 130)),
          ),
        ];
    }
  }
}
