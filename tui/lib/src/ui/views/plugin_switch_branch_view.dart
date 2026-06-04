import 'dart:async';

import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../../providers/ui_state_provider.dart';
import '../widgets/branch_picker.dart';
import '../widgets/signature_label.dart';

/// Phase model for the branch-switch flow.
///
/// - [pickBranch] — operator drives the shared [BranchPicker] (declared
///   rows from the plugin's manifest + a trailing Custom branch… input).
/// - [cloning] — [PluginService.switchBranch] is fetching the new branch.
/// - [consent] — service invoked the confirm callback; show preview + y/n.
/// - [switching] — operator confirmed; service is wiping + repopulating.
/// - [done] — success or error message, then dismiss.
enum _Phase { pickBranch, cloning, consent, switching, done }

class PluginSwitchBranchView extends StatefulComponent {
  final PluginService pluginService;
  final String pluginId;
  final String currentBranch;

  /// The plugin's declared branches block (`branches` field of its
  /// manifest). Null when the plugin's manifest omits the block — the
  /// shared [BranchPicker] then renders only the "Custom branch…" row.
  final BranchManifest? branches;

  final VoidCallback onDismiss;

  const PluginSwitchBranchView({
    super.key,
    required this.pluginService,
    required this.pluginId,
    required this.currentBranch,
    required this.branches,
    required this.onDismiss,
  });

  @override
  State<PluginSwitchBranchView> createState() => _PluginSwitchBranchViewState();
}

class _PluginSwitchBranchViewState extends State<PluginSwitchBranchView> {
  _Phase _phase = _Phase.pickBranch;

  PluginInstallPreview? _preview;
  Completer<bool>? _consentCompleter;
  String? _resultMessage;
  PluginMarker? _resultMarker;

  /// The branch ref passed to [_runSwitch] — stored so [_buildCloningPhase]
  /// can display it.
  String _chosenRef = '';

  /// Re-entrant guard — latch flipped when we hand the ref to
  /// [PluginService.switchBranch]. Prevents a double-Enter from
  /// spawning a second switch (CLAUDE.md pitfall #1: plain field, not a
  /// provider).
  bool _submitted = false;

  // ---------------------------------------------------------------------------
  // Key handlers (post-picker phases)
  // ---------------------------------------------------------------------------

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

  /// Resolve the picker's operator-facing value (declared key or
  /// `custom:<ref>`) into a concrete git ref that
  /// [PluginService.switchBranch] understands. Declared rows resolve
  /// via the manifest; `custom:<ref>` values strip the prefix.
  String _resolveRef(String value, BranchManifest? manifest) {
    if (value.startsWith('custom:')) return value.substring('custom:'.length);
    if (manifest != null && manifest.branches.containsKey(value)) {
      return manifest.branches[value]!.ref;
    }
    // The picker only emits declared keys or `custom:<ref>` — anything
    // else is a programming error.
    throw StateError('BranchPicker emitted unknown value: $value');
  }

  void _onPickerSelected(String value) {
    final ref = _resolveRef(value, component.branches);
    if (ref.isEmpty) return;

    // Already on this branch — short-circuit without cloning.
    if (ref == component.currentBranch) {
      setState(() {
        _resultMessage = 'already on $ref';
        _resultMarker = null; // no nudge, no clone
        _phase = _Phase.done;
      });
      return;
    }

    _chosenRef = ref;
    setState(() => _phase = _Phase.cloning);
    _runSwitch(ref);
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
    // The picker phase delegates focus to BranchPicker's own Focusable
    // so it can own arrow/Enter handling for its two-phase list +
    // customInput sub-states. Post-picker phases need our own Focusable
    // to catch y/n and Enter.
    if (_phase == _Phase.pickBranch) {
      return _buildPickerPhase();
    }
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          switch (_phase) {
            case _Phase.pickBranch:
              return false; // handled by BranchPicker above
            case _Phase.cloning:
            case _Phase.switching:
              // No-op during async work — swallow keys so the operator
              // can't double-submit or trigger a stale transition.
              return true;
            case _Phase.consent:
              return _handleConsentKey(event);
            case _Phase.done:
              return _handleDoneKey(event);
          }
        } catch (e, st) {
          LogService.error(
            'Plugin switch-branch view key handler failed',
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
          // pickBranch is rendered separately via _buildPickerPhase above.
          _Phase.pickBranch => const [],
          _Phase.cloning => _buildCloningPhase(),
          _Phase.consent => _buildConsentPhase(),
          _Phase.switching => _buildSwitchingPhase(),
          _Phase.done => _buildDonePhase(),
        },
      ),
    );
  }

  Component _buildPickerPhase() {
    return Container(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('━━━ Switch branch: ${component.pluginId} ━━━', style: _heading),
          const SizedBox(height: 1),
          BranchPicker(
            manifest: component.branches,
            currentValue: component.currentBranch,
            onSelected: _onPickerSelected,
            onCancel: component.onDismiss,
          ),
        ],
      ),
    );
  }

  List<Component> _buildCloningPhase() {
    return [
      Text('Cloning ${component.pluginId} from $_chosenRef...', style: _body),
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
