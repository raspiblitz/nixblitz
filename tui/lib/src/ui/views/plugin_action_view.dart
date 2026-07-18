import 'dart:async';
import 'dart:io';

import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../widgets/password_input.dart';
import '../widgets/scrollable_log.dart';

/// Per-plugin action runner. Routed to when the operator selects an
/// action row in Configure → `<plugin>`. Walks an input collection
/// phase (one prompt per declared `PluginActionInput`), an optional
/// y/n confirm, a streaming-output phase while the action runs, and
/// a final exit-code summary.
///
/// Reuses the project's existing widgets:
///
/// - [PasswordInput] (with `requireConfirmation: false`,
///   `minLength: 0`) for `type: 'secret'` inputs — same masked-input
///   + Tab-to-reveal UX the System → password flow uses.
/// - A small inline text overlay for `type: 'text'` inputs.
/// - [ScrollableLog] for the streaming output, identical to the
///   apply / update views.
///
/// Inputs aren't persisted to `config.json` — they only flow into
/// the action's spawned process as env vars and live in
/// [PluginActionRunner]'s in-memory map. After [_Phase.done] the
/// values are discarded along with the state object.
enum _Phase { collectingInputs, confirm, running, done }

class PluginActionView extends StatefulComponent {
  final PluginAction action;

  /// Id of the plugin that declared [action]. Used only for the
  /// `wasm:` path — resolves the owning [PluginManifest] (for its
  /// `sandbox` block) and the plugin's installed source dir via
  /// [installedPluginsProvider] / [pluginServiceProvider]. `command:`
  /// and `unit:` actions ignore it; they run through [runner] as
  /// before.
  final String pluginId;

  final PluginActionRunner runner;
  final VoidCallback onDismiss;

  const PluginActionView({
    super.key,
    required this.action,
    required this.pluginId,
    required this.runner,
    required this.onDismiss,
  });

  @override
  State<PluginActionView> createState() => _PluginActionViewState();
}

class _PluginActionViewState extends State<PluginActionView> {
  late _Phase _phase;
  int _inputIndex = 0;
  final Map<String, String> _collected = <String, String>{};
  final List<String> _output = <String>[];
  int? _exitCode;
  StreamSubscription<String>? _outputSub;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final action = component.action;
    if (action.inputs.isNotEmpty) {
      _phase = _Phase.collectingInputs;
    } else if (action.confirm) {
      _phase = _Phase.confirm;
    } else {
      _phase = _Phase.running;
      Future.microtask(_startAction);
    }
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    super.dispose();
  }

  // ── Phase transitions ───────────────────────────────────────────

  void _onInputSubmit(String value) {
    final action = component.action;
    final input = action.inputs[_inputIndex];
    _collected[input.name] = value;
    if (_inputIndex + 1 < action.inputs.length) {
      setState(() => _inputIndex++);
      return;
    }
    if (action.confirm) {
      setState(() => _phase = _Phase.confirm);
    } else {
      setState(() => _phase = _Phase.running);
      Future.microtask(_startAction);
    }
  }

  void _onConfirmYes() {
    if (_started) return;
    setState(() => _phase = _Phase.running);
    Future.microtask(_startAction);
  }

  void _onCancel() {
    component.onDismiss();
  }

  void _startAction() {
    if (_started) return;
    _started = true;
    if (component.action.isWasm) {
      unawaited(_startWasmAction());
      return;
    }
    try {
      final run = component.runner.run(component.action, inputs: _collected);
      _outputSub = run.output.listen(
        (line) {
          if (!mounted) return;
          setState(() => _output.add(line));
        },
        onError: (Object e, StackTrace st) {
          LogService.error('Plugin action output stream error', e, st);
        },
      );
      run.exitCode
          .then((code) {
            if (!mounted) return;
            setState(() {
              _exitCode = code;
              _phase = _Phase.done;
            });
          })
          .catchError((Object e, StackTrace st) {
            LogService.error('Plugin action failed', e, st);
            if (!mounted) return;
            setState(() {
              _exitCode = 1;
              _output.add('plugin-action: $e');
              _phase = _Phase.done;
            });
          });
    } catch (e, st) {
      LogService.error('Plugin action launch failed', e, st);
      setState(() {
        _exitCode = 1;
        _output.add('plugin-action: launch failed: $e');
        _phase = _Phase.done;
      });
    }
  }

  /// `wasm:` counterpart to [_startAction]'s command/unit path. The
  /// only structural difference is that [WasmActionRunner.run] itself
  /// is async (it has to spin up an Engine/Store before it can hand
  /// back the `(output, exitCode)` record), so the stream/exitCode
  /// wiring below happens after an `await` instead of synchronously.
  /// Once wired, the rest is identical: same [ScrollableLog] stream,
  /// same exit-code → [_Phase.done] transition.
  Future<void> _startWasmAction() async {
    try {
      final action = component.action;
      final manifest = context
          .read(installedPluginsProvider)
          .where((m) => m.id == component.pluginId)
          .firstOrNull;
      if (manifest == null) {
        throw StateError(
          'plugin "${component.pluginId}" is not installed '
          '(installedPluginsProvider has no matching manifest)',
        );
      }
      final pluginDir =
          '${context.read(pluginServiceProvider).pluginsDir}/'
          '${component.pluginId}';
      final wasmRunner = context.read(wasmActionRunnerProvider);
      final home = Platform.environment['HOME'] ?? '.';
      final run = await runPluginWasm(
        runner: wasmRunner,
        manifest: manifest,
        pluginDir: pluginDir,
        moduleRelPath: action.wasm!.module,
        export: action.wasm!.export,
        stateDir: '$home/nixblitz/state/sandbox',
        quiet: false,
      );
      if (!mounted) return;
      _outputSub = run.output.listen(
        (line) {
          if (!mounted) return;
          setState(() => _output.add(line));
        },
        onError: (Object e, StackTrace st) {
          LogService.error('Plugin wasm action output stream error', e, st);
        },
      );
      run.exitCode
          .then((code) {
            if (!mounted) return;
            setState(() {
              _exitCode = code;
              _phase = _Phase.done;
            });
          })
          .catchError((Object e, StackTrace st) {
            LogService.error('Plugin wasm action failed', e, st);
            if (!mounted) return;
            setState(() {
              _exitCode = 1;
              _output.add('plugin-action: $e');
              _phase = _Phase.done;
            });
          });
    } catch (e, st) {
      LogService.error('Plugin wasm action launch failed', e, st);
      if (!mounted) return;
      setState(() {
        _exitCode = 1;
        _output.add('plugin-action: launch failed: $e');
        _phase = _Phase.done;
      });
    }
  }

  // ── Render ──────────────────────────────────────────────────────

  @override
  Component build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      child: switch (_phase) {
        _Phase.collectingInputs => _buildInputPhase(),
        _Phase.confirm => _buildConfirmPhase(),
        _Phase.running => _buildRunningPhase(),
        _Phase.done => _buildDonePhase(),
      },
    );
  }

  static const _heading = TextStyle(
    color: Color.fromRGB(247, 147, 26),
    fontWeight: FontWeight.bold,
  );
  static const _body = TextStyle(color: Color.fromRGB(220, 220, 220));
  static const _dim = TextStyle(color: Color.fromRGB(140, 140, 150));
  static const _success = TextStyle(color: Color.fromRGB(110, 220, 110));
  static const _error = TextStyle(color: Color.fromRGB(255, 80, 80));

  Component _buildInputPhase() {
    final action = component.action;
    final input = action.inputs[_inputIndex];
    final counter = action.inputs.length > 1
        ? '(${_inputIndex + 1}/${action.inputs.length}) '
        : '';
    final title = '$counter${input.label}';

    if (input.type == 'secret') {
      return PasswordInput(
        title: title,
        subtitle: input.description.isNotEmpty ? input.description : null,
        minLength: 0,
        requireConfirmation: false,
        onSubmit: _onInputSubmit,
        onCancel: _onCancel,
      );
    }
    return _PlainTextInput(
      title: title,
      subtitle: input.description.isNotEmpty ? input.description : null,
      onSubmit: _onInputSubmit,
      onCancel: _onCancel,
    );
  }

  Component _buildConfirmPhase() {
    final action = component.action;
    final children = <Component>[
      Text('━━━ ${action.label} ━━━', style: _heading),
    ];
    if (action.description.isNotEmpty) {
      children.add(const SizedBox(height: 1));
      children.add(Text(action.description, style: _body));
    }
    if (_collected.isNotEmpty) {
      children.add(const SizedBox(height: 1));
      children.add(const Text('Inputs:', style: _dim));
      for (final input in action.inputs) {
        final value = _collected[input.name] ?? '';
        final display = input.type == 'secret' ? '*' * value.length : value;
        children.add(Text('  ${input.label}: $display', style: _body));
      }
    }
    children.add(const SizedBox(height: 1));
    children.add(const Text('[y] run   [n / Esc] cancel', style: _dim));

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyY) {
            _onConfirmYes();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyN ||
              event.logicalKey == LogicalKey.escape) {
            _onCancel();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Plugin action confirm handler failed', e, st);
          return true;
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Component _buildRunningPhase() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('━━━ running: ${component.action.label} ━━━', style: _heading),
        const SizedBox(height: 1),
        Expanded(child: ScrollableLog(lines: _output)),
      ],
    );
  }

  Component _buildDonePhase() {
    final code = _exitCode ?? 1;
    final isSuccess = code == 0;
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter ||
            event.logicalKey == LogicalKey.escape) {
          component.onDismiss();
          return true;
        }
        return false;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isSuccess
                ? '${component.action.label}: done (exit 0)'
                : '${component.action.label}: failed (exit $code)',
            style: isSuccess ? _success : _error,
          ),
          const SizedBox(height: 1),
          Expanded(child: ScrollableLog(lines: _output)),
          const SizedBox(height: 1),
          const Text('[Enter / Esc] back to plugin', style: _dim),
        ],
      ),
    );
  }
}

class _PlainTextInput extends StatefulComponent {
  final String title;
  final String? subtitle;
  final void Function(String) onSubmit;
  final VoidCallback onCancel;

  const _PlainTextInput({
    required this.title,
    this.subtitle,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<_PlainTextInput> createState() => _PlainTextInputState();
}

class _PlainTextInputState extends State<_PlainTextInput> {
  String _buffer = '';

  @override
  Component build(BuildContext context) {
    final comp = component;
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            comp.onCancel();
            return true;
          }
          if (event.logicalKey == LogicalKey.enter) {
            comp.onSubmit(_buffer);
            return true;
          }
          if (event.logicalKey == LogicalKey.backspace) {
            if (_buffer.isNotEmpty) {
              setState(
                () => _buffer = _buffer.substring(0, _buffer.length - 1),
              );
            }
            return true;
          }
          // Paste — single-line input. Strip newlines so a copied
          // value with trailing whitespace doesn't accidentally
          // submit on paste (same defense the password input uses).
          if (event.logicalKey == LogicalKey.keyV && event.modifiers.ctrl) {
            final pasted = ClipboardManager.paste();
            if (pasted != null && pasted.isNotEmpty) {
              setState(
                () => _buffer += pasted.replaceAll(RegExp(r'[\r\n]+'), ''),
              );
            }
            return true;
          }
          final ch = event.character;
          if (ch != null && ch.length == 1) {
            final code = ch.codeUnitAt(0);
            if (code >= 0x20 && code <= 0x7E) {
              setState(() => _buffer += ch);
            }
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Plain text input handler failed', e, st);
          return true;
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            comp.title,
            style: const TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
          if (comp.subtitle != null) ...[
            const SizedBox(height: 1),
            Text(
              comp.subtitle!,
              style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
            ),
          ],
          const SizedBox(height: 1),
          Text('Value: ${_buffer}_'),
          const SizedBox(height: 1),
          const Text(
            'Enter to submit, Esc to cancel.',
            style: TextStyle(color: Color.fromRGB(150, 150, 180)),
          ),
        ],
      ),
    );
  }
}
