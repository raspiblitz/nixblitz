import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

/// Two-phase bulk refresh flow surfaced from Configure → Plugins via [R].
///
/// Wraps [PluginService.refreshAll] and renders its four-way partition
/// (advanced / unchanged / failures / skipped) in a single screen.
/// Refresh-all is a "click and wait" interaction: no per-plugin
/// confirmation, no signature-mismatch recovery flow inline. Failures
/// are reported per plugin in the result list; the operator deals with
/// signature mismatches by dropping back to the single-plugin refresh
/// flow ([r]) on each affected row, which has the recovery UX.
enum _Phase { refreshing, done }

class PluginRefreshAllView extends StatefulComponent {
  final PluginService pluginService;
  final VoidCallback onDismiss;

  const PluginRefreshAllView({
    super.key,
    required this.pluginService,
    required this.onDismiss,
  });

  @override
  State<PluginRefreshAllView> createState() => _PluginRefreshAllViewState();
}

class _PluginRefreshAllViewState extends State<PluginRefreshAllView> {
  _Phase _phase = _Phase.refreshing;
  PluginRefreshAllResult? _result;
  String? _topLevelError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final svc = component.pluginService;
    svc
        .refreshAll()
        .then((result) {
          if (!mounted) return;
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              _result = result;
              _phase = _Phase.done;
            });
          });
        })
        .catchError((e) {
          // refreshAll itself doesn't throw — per-plugin errors land
          // in result.failures. But defend against e.g. baseDirProvider
          // misconfiguration triggering a top-level throw.
          if (!mounted) return;
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              _topLevelError = '$e';
              _phase = _Phase.done;
            });
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
            (event.logicalKey == LogicalKey.enter && _phase == _Phase.done)) {
          component.onDismiss();
          return true;
        }
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
    if (_phase == _Phase.refreshing) {
      return const [
        Text(
          'Refreshing all plugins…',
          style: TextStyle(color: Color.fromRGB(247, 147, 26)),
        ),
        SizedBox(height: 1),
        Text(
          '(cloning each plugin\'s upstream, comparing pin + signature)',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      ];
    }

    if (_topLevelError != null) {
      return [
        Text(
          'refresh-all failed: $_topLevelError',
          style: const TextStyle(color: Color.fromRGB(255, 100, 100)),
        ),
        const SizedBox(height: 1),
        const Text(
          '[Enter / Esc] back to plugins',
          style: TextStyle(color: Color.fromRGB(110, 110, 130)),
        ),
      ];
    }

    final r = _result!;
    final children = <Component>[
      Text(
        'Refresh-all complete: '
        '${r.advanced.length} advanced, '
        '${r.unchanged.length} unchanged, '
        '${r.failures.length} failed, '
        '${r.skipped.length} pinned-skipped',
        style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
      ),
      const SizedBox(height: 1),
    ];

    for (final p in r.advanced) {
      children.add(
        Text(
          '  ↑ ${p.id}  pin=${_short(p.rev)}  (advanced)',
          style: const TextStyle(color: Color.fromRGB(120, 200, 120)),
        ),
      );
    }
    for (final p in r.unchanged) {
      children.add(
        Text(
          '  = ${p.id}  pin=${_short(p.rev)}  (no changes)',
          style: const TextStyle(color: Color.fromRGB(180, 180, 180)),
        ),
      );
    }
    for (final f in r.failures) {
      final mismatch = f.error is PluginSignatureMismatch;
      children.add(
        Text(
          mismatch
              ? '  ✗ ${f.plugin.id}  signing key changed (use [r] to see recovery)'
              : '  ✗ ${f.plugin.id}  ${f.error}',
          style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
        ),
      );
    }
    for (final p in r.skipped) {
      children.add(
        Text(
          '  · ${p.id}  pinned (autoUpdate=false)',
          style: const TextStyle(color: Color.fromRGB(140, 140, 150)),
        ),
      );
    }

    if (r.advanced.isNotEmpty) {
      children.add(const SizedBox(height: 1));
      children.add(
        const Text(
          'Run the Apply view ([a] from the dashboard) to rebuild.',
          style: TextStyle(color: Color.fromRGB(150, 150, 180)),
        ),
      );
    }

    children.add(const SizedBox(height: 1));
    children.add(
      const Text(
        '[Enter / Esc] back to plugins',
        style: TextStyle(color: Color.fromRGB(110, 110, 130)),
      ),
    );
    return children;
  }
}
