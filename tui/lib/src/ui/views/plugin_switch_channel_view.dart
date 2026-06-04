import 'dart:async';

import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/ui_state_provider.dart';
import '../widgets/signature_label.dart';

/// Phase model for the channel-switch flow.
///
/// - [pickChannel] — operator sees the 4-row channel picker.
/// - [customInput] — operator chose "Custom branch…" and is typing.
/// - [cloning] — [PluginService.switchBranch] is fetching the new branch.
/// - [consent] — service invoked the confirm callback; show preview + y/n.
/// - [switching] — operator confirmed; service is wiping + repopulating.
/// - [done] — success or error message, then dismiss.
enum _Phase { pickChannel, customInput, cloning, consent, switching, done }

class PluginSwitchChannelView extends StatefulComponent {
  final PluginService pluginService;
  final String pluginId;
  final String currentBranch;
  final VoidCallback onDismiss;

  const PluginSwitchChannelView({
    super.key,
    required this.pluginService,
    required this.pluginId,
    required this.currentBranch,
    required this.onDismiss,
  });

  @override
  State<PluginSwitchChannelView> createState() =>
      _PluginSwitchChannelViewState();
}

class _PluginSwitchChannelViewState extends State<PluginSwitchChannelView> {
  _Phase _phase = _Phase.pickChannel;

  /// Picker cursor index (0..3 — 0-2 are the hardcoded channels, 3 is
  /// "Custom branch…").
  int _selected = 0;

  /// Accumulates characters while in [_Phase.customInput].
  String _branchBuffer = '';

  PluginInstallPreview? _preview;
  Completer<bool>? _consentCompleter;
  String? _resultMessage;
  PluginMarker? _resultMarker;

  /// The branch name passed to [_runSwitch] — stored so [_buildCloningPhase]
  /// can display it without having to parse it back from [_branchBuffer].
  String _chosenBranch = '';

  /// Re-entrant guard — latch flipped when we hand the branch to
  /// [PluginService.switchBranch]. Prevents a double-Enter from
  /// spawning a second switch (CLAUDE.md pitfall #1: plain field, not a
  /// provider).
  bool _submitted = false;

  // Hardcoded well-known channels for v1.
  static const _channels = ['main', 'beta', 'dev'];

  // ---------------------------------------------------------------------------
  // Key handlers
  // ---------------------------------------------------------------------------

  bool _handlePickerKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    final total = _channels.length + 1; // +1 for "Custom branch…"
    if (event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.keyJ) {
      setState(() => _selected = (_selected + 1) % total);
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.keyK) {
      setState(() => _selected = (_selected - 1 + total) % total);
      return true;
    }
    if (event.logicalKey == LogicalKey.enter) {
      if (_selected < _channels.length) {
        _onChannelChosen(_channels[_selected]);
      } else {
        // "Custom branch…" row.
        setState(() {
          _branchBuffer = '';
          _phase = _Phase.customInput;
        });
      }
      return true;
    }
    return false;
  }

  bool _handleCustomInputKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      setState(() => _phase = _Phase.pickChannel);
      return true;
    }
    if (event.logicalKey == LogicalKey.enter) {
      _onChannelChosen(_branchBuffer.trim());
      return true;
    }
    if (event.logicalKey == LogicalKey.backspace) {
      if (_branchBuffer.isNotEmpty) {
        setState(
          () => _branchBuffer = _branchBuffer.substring(
            0,
            _branchBuffer.length - 1,
          ),
        );
      }
      return true;
    }
    // Paste: terminal_binding.dart synthesises Ctrl+V from bracketed-paste
    // sequences. Strip whitespace so branch names arrive cleanly.
    if (event.logicalKey == LogicalKey.keyV && event.modifiers.ctrl) {
      final pasted = ClipboardManager.paste();
      if (pasted != null && pasted.isNotEmpty) {
        setState(() => _branchBuffer += pasted.trim());
      }
      return true;
    }
    final ch = event.character;
    if (ch != null && ch.length == 1) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x20 && code <= 0x7E) {
        setState(() => _branchBuffer += ch);
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
  // Business logic
  // ---------------------------------------------------------------------------

  void _onChannelChosen(String branch) {
    if (branch.isEmpty) return;

    // Already on this branch — short-circuit without cloning.
    if (branch == component.currentBranch) {
      setState(() {
        _resultMessage = 'already on $branch';
        _resultMarker = null; // no nudge, no clone
        _phase = _Phase.done;
      });
      return;
    }

    _chosenBranch = branch;
    setState(() => _phase = _Phase.cloning);
    _runSwitch(branch);
  }

  void _runSwitch(String newBranch) {
    if (_submitted) return;
    _submitted = true;
    // _phase is already _Phase.cloning when this is called.

    final svc = component.pluginService;
    svc
        .switchBranch(
          component.pluginId,
          newBranch,
          confirm: (preview) {
            // The confirm callback is invoked synchronously from inside
            // PluginService.switchBranch — defer setState to a microtask so
            // we don't clobber a render in flight (CLAUDE.md pitfall #1).
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
            final label =
                'switched ${marker.id} to ${marker.branch} v${marker.version}';
            setState(() {
              _resultMarker = marker;
              _resultMessage = label;
              _phase = _Phase.done;
            });
            // Nudge toward applying — the plugin's service won't run on the
            // new branch until a nixos-rebuild via System → Apply.
            context.read(applyNowPromptProvider.notifier).state =
                ApplyNowPrompt(headline: label);
          });
        })
        .catchError((Object e) {
          Future.microtask(() {
            if (!mounted) return;
            setState(() {
              _resultMessage = switch (e) {
                PluginInstallCancelled() => 'switch cancelled',
                PluginPinnedException _ => 'plugin is pinned — unpin first',
                _ => 'switch failed: $e',
              };
              _phase = _Phase.done;
            });
          });
        });
  }

  void _onConsentYes() {
    final completer = _consentCompleter;
    if (completer == null) return;
    _consentCompleter = null;
    setState(() => _phase = _Phase.switching);
    completer.complete(true);
  }

  void _onConsentNo() {
    final completer = _consentCompleter;
    if (completer == null) return;
    _consentCompleter = null;
    // Don't transition here — switchBranch Future will throw
    // PluginInstallCancelled; the catchError lands us in _Phase.done with
    // "switch cancelled".
    completer.complete(false);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          switch (_phase) {
            case _Phase.pickChannel:
              return _handlePickerKey(event);
            case _Phase.customInput:
              return _handleCustomInputKey(event);
            case _Phase.cloning:
            case _Phase.switching:
              // No-op during async work — swallow keys so the operator can't
              // double-submit or trigger a stale transition.
              return true;
            case _Phase.consent:
              return _handleConsentKey(event);
            case _Phase.done:
              return _handleDoneKey(event);
          }
        } catch (e, st) {
          LogService.error(
            'Plugin switch-channel view key handler failed',
            e,
            st,
          );
          return true;
        }
      },
      child: _buildBody(),
    );
  }

  // Style constants — mirrors PluginInstallView so both surfaces look
  // identical.
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

  Component _buildBody() {
    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: switch (_phase) {
          _Phase.pickChannel => _buildPickerPhase(),
          _Phase.customInput => _buildCustomInputPhase(),
          _Phase.cloning => _buildCloningPhase(),
          _Phase.consent => _buildConsentPhase(),
          _Phase.switching => _buildSwitchingPhase(),
          _Phase.done => _buildDonePhase(),
        },
      ),
    );
  }

  List<Component> _buildPickerPhase() {
    final rows = <Component>[
      Text('━━━ Switch channel: ${component.pluginId} ━━━', style: _heading),
      const SizedBox(height: 1),
    ];

    // Render well-known channels.
    for (var i = 0; i < _channels.length; i++) {
      final label = _channels[i];
      final isCurrent = label == component.currentBranch;
      final isSelected = i == _selected;
      final prefix = isSelected ? '> ' : '  ';
      final suffix = isCurrent ? ' (current)' : '';
      rows.add(Text('$prefix$label$suffix', style: _body));
    }

    // "Custom branch…" row.
    final customIdx = _channels.length;
    final customPrefix = _selected == customIdx ? '> ' : '  ';
    rows.add(Text('${customPrefix}Custom branch…', style: _body));

    rows.add(const SizedBox(height: 1));
    rows.add(const Text('[Enter] choose   [Esc] cancel', style: _dim));
    return rows;
  }

  List<Component> _buildCustomInputPhase() {
    return [
      Text('━━━ Switch channel: ${component.pluginId} ━━━', style: _heading),
      const SizedBox(height: 1),
      Text('Branch: ${_branchBuffer}_', style: _body),
      const SizedBox(height: 1),
      const Text('[Enter] continue   [Esc] back', style: _dim),
    ];
  }

  List<Component> _buildCloningPhase() {
    return [
      Text(
        'Cloning ${component.pluginId} from $_chosenBranch...',
        style: _body,
      ),
    ];
  }

  List<Component> _buildConsentPhase() {
    final p = _preview;
    if (p == null) {
      return const [Text('(no preview available)', style: _error)];
    }
    final children = <Component>[
      Text('━━━ Switch ${p.name} → ${p.branch} ━━━', style: _heading),
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

  List<Component> _buildSwitchingPhase() {
    return const [
      Text('Switching... (wiping + repopulating plugin dir)', style: _body),
    ];
  }

  List<Component> _buildDonePhase() {
    final msg = _resultMessage ?? '(no message)';
    final isSuccess = _resultMarker != null;
    return [
      Text(msg, style: isSuccess ? _success : _error),
      if (isSuccess) ...[
        const SizedBox(height: 1),
        const Text(
          'Not yet running — open System → Apply → Apply pending '
          'changes to activate.',
          style: _dim,
        ),
      ],
      const SizedBox(height: 1),
      const Text('[Enter] back', style: _dim),
    ];
  }
}
