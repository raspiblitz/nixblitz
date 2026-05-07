import 'dart:async';

import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';

import '../widgets/signature_label.dart';

/// Five-phase install flow surfaced from Configure → Plugins.
///
/// Phases mirror the moving parts of [PluginService.install]:
///
/// - [_Phase.input] — operator types the source URL.
/// - [_Phase.cloning] — service is fetching the manifest in a tmpdir.
/// - [_Phase.consent] — we show the [PluginInstallPreview] with the
///   stark "this grants the author root" warning and wait for y/n.
/// - [_Phase.installing] — operator confirmed; the service is moving
///   staging into place, writing the marker, regenerating
///   `plugins.list`, and seeding `app_configs.<id>`.
/// - [_Phase.done] — success or error message + dismiss back to the
///   plugin list.
enum _Phase { input, cloning, consent, installing, done }

class PluginInstallView extends StatefulComponent {
  final PluginService pluginService;
  final VoidCallback onDismiss;

  const PluginInstallView({
    super.key,
    required this.pluginService,
    required this.onDismiss,
  });

  @override
  State<PluginInstallView> createState() => _PluginInstallViewState();
}

class _PluginInstallViewState extends State<PluginInstallView> {
  _Phase _phase = _Phase.input;
  String _urlBuffer = '';
  PluginInstallPreview? _preview;
  Completer<bool>? _consentCompleter;
  String? _resultMessage;
  PluginMarker? _resultMarker;

  /// Latch flipped the moment we hand the URL off to PluginService —
  /// keeps a re-entrant Enter from spawning a second install. See
  /// CLAUDE.md "Never set StateProvider values inside onKeyEvent
  /// handlers" — same hazard, same workaround (plain field, not a
  /// provider).
  bool _submitted = false;

  void _onUrlSubmit() {
    final url = _urlBuffer.trim();
    if (url.isEmpty || _submitted) return;
    _submitted = true;
    setState(() => _phase = _Phase.cloning);

    // Mirror the CLI's heuristic: any explicit non-allow-listed scheme
    // (file://, http://, ssh://) needs allowInsecure=true. Whitelisted
    // schemes (https://, git+https://, forgejo:, github:) are safe.
    final svc = component.pluginService;
    final insecure =
        url.contains('://') &&
        !url.startsWith('https://') &&
        !url.startsWith('git+https://') &&
        !url.startsWith('forgejo:') &&
        !url.startsWith('github:');

    svc
        .install(
          url,
          allowInsecure: insecure,
          confirm: (preview) {
            // The callback is invoked synchronously from inside
            // PluginService.install — defer setState to a microtask
            // so we don't clobber a render in flight (CLAUDE.md
            // pitfall #1).
            final completer = Completer<bool>();
            _consentCompleter = completer;
            Future.microtask(() {
              if (!mounted) return;
              setState(() {
                _preview = preview;
                _phase = _Phase.consent;
              });
            });
            return completer.future;
          },
        )
        .then((marker) {
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              _resultMarker = marker;
              _resultMessage = 'installed ${marker.id} v${marker.version}';
              _phase = _Phase.done;
            });
          });
        })
        .catchError((Object e) {
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              _resultMessage = e is PluginInstallCancelled
                  ? 'install cancelled'
                  : 'install failed: $e';
              _phase = _Phase.done;
            });
          });
        });
  }

  void _onConsentYes() {
    final completer = _consentCompleter;
    if (completer == null) return;
    _consentCompleter = null;
    setState(() => _phase = _Phase.installing);
    completer.complete(true);
  }

  void _onConsentNo() {
    final completer = _consentCompleter;
    if (completer == null) return;
    _consentCompleter = null;
    // Don't transition here — the install Future will throw
    // PluginInstallCancelled, the catchError lands us in
    // _Phase.done with "install cancelled".
    completer.complete(false);
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          switch (_phase) {
            case _Phase.input:
              return _handleInputKey(event);
            case _Phase.cloning:
            case _Phase.installing:
              // No-op during async work. Cancelling a Future cleanly
              // requires explicit cooperation we don't yet have; just
              // swallow keys so the operator can't double-submit.
              return true;
            case _Phase.consent:
              return _handleConsentKey(event);
            case _Phase.done:
              return _handleDoneKey(event);
          }
        } catch (e, st) {
          LogService.error('Plugin install view key handler failed', e, st);
          return true;
        }
      },
      child: _buildBody(),
    );
  }

  bool _handleInputKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    if (event.logicalKey == LogicalKey.enter) {
      _onUrlSubmit();
      return true;
    }
    if (event.logicalKey == LogicalKey.backspace) {
      if (_urlBuffer.isNotEmpty) {
        setState(
          () => _urlBuffer = _urlBuffer.substring(0, _urlBuffer.length - 1),
        );
      }
      return true;
    }
    final ch = event.character;
    if (ch != null && ch.length == 1) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x20 && code <= 0x7E) {
        setState(() => _urlBuffer += ch);
      }
      return true;
    }
    return false;
  }

  bool _handleConsentKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.keyY) {
      _onConsentYes();
      return true;
    }
    if (event.logicalKey == LogicalKey.keyN ||
        event.logicalKey == LogicalKey.escape) {
      _onConsentNo();
      return true;
    }
    return false;
  }

  bool _handleDoneKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter ||
        event.logicalKey == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Phase rendering
  // ---------------------------------------------------------------------------

  Component _buildBody() {
    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: switch (_phase) {
          _Phase.input => _buildInputPhase(),
          _Phase.cloning => _buildCloningPhase(),
          _Phase.consent => _buildConsentPhase(),
          _Phase.installing => _buildInstallingPhase(),
          _Phase.done => _buildDonePhase(),
        },
      ),
    );
  }

  static const _heading = TextStyle(
    color: Color.fromRGB(247, 147, 26),
    fontWeight: FontWeight.bold,
  );
  static const _body = TextStyle(color: Color.fromRGB(220, 220, 220));
  static const _dim = TextStyle(color: Color.fromRGB(140, 140, 150));
  static const _warn = TextStyle(
    color: Color.fromRGB(255, 200, 80),
    fontWeight: FontWeight.bold,
  );
  static const _error = TextStyle(color: Color.fromRGB(255, 80, 80));
  static const _success = TextStyle(color: Color.fromRGB(110, 220, 110));

  List<Component> _buildInputPhase() {
    return [
      const Text('━━━ Install plugin ━━━', style: _heading),
      const SizedBox(height: 1),
      Text('URL: ${_urlBuffer}_', style: _body),
      const SizedBox(height: 1),
      const Text('Examples:', style: _dim),
      const Text(
        '  forgejo:forge.f44.fyi/f44/nixblitz_official_plugins/lnbits',
        style: _dim,
      ),
      const Text(
        '  github:fusion44/nixblitz_official_plugins/tailscale',
        style: _dim,
      ),
      const Text(
        '  git+https://forge.f44.fyi/f44/nixblitz-plugin-blitz-api',
        style: _dim,
      ),
      const Text(
        '  file:///home/admin/dev/myplugin  (use --insecure CLI for ssh:// or http://)',
        style: _dim,
      ),
      const SizedBox(height: 1),
      const Text('[Enter] install   [Esc] cancel', style: _dim),
    ];
  }

  List<Component> _buildCloningPhase() {
    return [Text('Cloning ${_urlBuffer.trim()}...', style: _body)];
  }

  List<Component> _buildConsentPhase() {
    final p = _preview;
    if (p == null) {
      // Should never happen — the consent phase is only entered after
      // the confirm callback hands us a preview.
      return const [Text('(no preview available)', style: _error)];
    }
    final children = <Component>[
      Text('━━━ plugin: ${p.name} ━━━', style: _heading),
    ];
    if (p.description.isNotEmpty) {
      children.add(const SizedBox(height: 1));
      children.add(Text(p.description, style: _body));
    }
    children.add(const SizedBox(height: 1));
    children.add(Text('source:      ${p.url}', style: _body));
    children.add(Text('branch:      ${p.branch}', style: _body));
    children.add(Text('pinned rev:  ${p.pinnedRev}', style: _body));
    children.add(Text('schema:      v${p.schemaVersion}', style: _body));
    children.add(
      Text('signature:   ${describeSignature(p.signature)}', style: _body),
    );
    children.add(const SizedBox(height: 1));
    children.add(
      const Text(
        'WARNING: installing this plugin grants the plugin author root on',
        style: _warn,
      ),
    );
    children.add(
      const Text(
        'this node. plugin.nix is arbitrary Nix code that runs at',
        style: _warn,
      ),
    );
    children.add(
      const Text(
        'nixos-rebuild time as root and can declare any systemd service,',
        style: _warn,
      ),
    );
    children.add(
      const Text(
        'activation script, or external dependency. This prompt is consent',
        style: _warn,
      ),
    );
    children.add(
      const Text(
        "to run that code, not a sandbox. If you don't trust the source +",
        style: _warn,
      ),
    );
    children.add(
      const Text(
        'commit above, read plugin.nix at the upstream URL before answering yes.',
        style: _warn,
      ),
    );
    children.add(const SizedBox(height: 1));
    children.add(const Text('[y] confirm   [n / Esc] cancel', style: _dim));
    return children;
  }

  List<Component> _buildInstallingPhase() {
    return const [
      Text(
        'Installing... (writing marker, regenerating plugins.list)',
        style: _body,
      ),
    ];
  }

  List<Component> _buildDonePhase() {
    final msg = _resultMessage ?? '(no message)';
    final isSuccess = _resultMarker != null;
    return [
      Text(msg, style: isSuccess ? _success : _error),
      const SizedBox(height: 1),
      const Text('[Enter] back to plugins', style: _dim),
    ];
  }
}
