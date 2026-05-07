import 'dart:async';

import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../widgets/scrollable_log.dart';
import '../widgets/spinner.dart';
import 'configure/field_editor.dart';

/// Per-plugin config form. Rendered by [ConfigureView] when the user
/// picks a plugin from the `plugins` tab.
///
/// State machine:
///
/// - **List mode** (default): renders config fields + actions as a
///   single navigable list. Enter on a field → text overlay or
///   in-place toggle/cycle. Enter on an action → confirm overlay
///   (or directly running, if `confirm: false`).
/// - **Text-edit overlay**: text input for `string` / `secret` /
///   `list<…>` field types.
/// - **Confirm-action overlay**: y/N prompt before running a
///   destructive action.
/// - **Running-action overlay**: streams stdout/stderr from the
///   action; spinner while running, exit code on completion.
///
/// On Esc from List mode, calls [onDismiss] (parent goes back to
/// the plugin list). On Esc from any overlay, the overlay
/// dismisses and we return to list mode.
///
/// Esc on the running overlay does **not** kill the action — the
/// process keeps running in the background; we just hide the log.
/// Cancellation is out of scope for Phase 4.
class PluginConfigView extends StatefulComponent {
  /// On-disk plugin id (matches `<pluginsDir>/<id>/`). Used to look
  /// up the manifest from the plugin registry.
  final String pluginId;

  final VoidCallback onDismiss;

  const PluginConfigView({
    super.key,
    required this.pluginId,
    required this.onDismiss,
  });

  @override
  State<PluginConfigView> createState() => _PluginConfigViewState();
}

/// Tagged-union row in the unified field+action list. Schema fields
/// and actions render side-by-side; the union lets them share the
/// same selection index without losing per-row type info.
sealed class _Row {
  const _Row();
}

/// A schema field declared via [PluginManifest.configSchema]. Values
/// live in the main `app_configs[pluginId]` map and are written
/// through `configProvider`.
class _SchemaFieldRow extends _Row {
  final AppConfigField spec;
  const _SchemaFieldRow(this.spec);
}

class _ActionRow extends _Row {
  final String key;
  final PluginAction action;
  const _ActionRow(this.key, this.action);
}

class _PluginConfigViewState extends State<PluginConfigView> {
  int _selectedIndex = 0;
  String? _editingSchemaFieldName;
  String? _confirmingActionId;
  String? _runningActionId;
  final List<String> _actionOutput = [];
  int? _actionExitCode;
  StreamSubscription<String>? _actionSub;
  String? _errorMessage;

  @override
  void dispose() {
    _actionSub?.cancel();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final pluginId = component.pluginId;

    final plugins = context.watch(installedPluginsProvider);
    final manifest = plugins.firstWhereOrNull((p) => p.id == pluginId);
    if (manifest == null) {
      // Plugin was uninstalled / rescaffolded mid-view, or the id
      // is wrong. Operator gets a clear error + Esc back.
      return _errorScreen(context, 'Plugin "$pluginId" is not installed');
    }

    // Main config — configSchema fields read/write through the main
    // config.json's app_configs[pluginId]. Watched so the row values
    // refresh on external edits / reverts.
    final mainConfigAsync = context.watch(configProvider);
    final mainConfig = mainConfigAsync.value;

    return _body(context, manifest, mainConfig);
  }

  Component _errorScreen(BuildContext context, String msg) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape) {
          component.onDismiss();
          return true;
        }
        return false;
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              msg,
              style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
            ),
            const SizedBox(height: 1),
            const Text(
              '[Esc] back',
              style: TextStyle(color: Color.fromRGB(110, 110, 130)),
            ),
          ],
        ),
      ),
    );
  }

  Component _body(
    BuildContext context,
    PluginManifest manifest,
    NixblitzConfig? mainConfig,
  ) {
    final pluginId = component.pluginId;

    // Build the unified field+action list.
    //   1. configSchema fields (backed by app_configs[pluginId])
    //   2. actions
    //
    // Indexes here match _selectedIndex.
    final schemaFields = manifest.configSchema?.fields ?? const [];
    final rows = <_Row>[
      for (final f in schemaFields) _SchemaFieldRow(f),
      for (final e in manifest.actions.entries) _ActionRow(e.key, e.value),
    ];

    // Empty plugin (no config + no actions) — render stub.
    if (rows.isEmpty) {
      return Focusable(
        focused: true,
        onKeyEvent: (event) {
          if (event.logicalKey == LogicalKey.escape) {
            component.onDismiss();
            return true;
          }
          return false;
        },
        child: Container(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(pluginId, manifest),
              const SizedBox(height: 1),
              const Text(
                '(no configurable fields or actions)',
                style: TextStyle(color: Color.fromRGB(150, 150, 170)),
              ),
              const SizedBox(height: 1),
              const Text(
                '[Esc] back',
                style: TextStyle(color: Color.fromRGB(110, 110, 130)),
              ),
            ],
          ),
        ),
      );
    }

    // Overlay precedence: running > confirming > text-edit > list.
    if (_runningActionId != null) {
      final action = manifest.actions[_runningActionId];
      if (action == null) {
        // Manifest churn mid-run (action removed). Drop to list.
        _runningActionId = null;
      } else {
        return _runningOverlay(action);
      }
    }
    if (_confirmingActionId != null) {
      final action = manifest.actions[_confirmingActionId];
      if (action == null) {
        _confirmingActionId = null;
      } else {
        return _confirmOverlay(action);
      }
    }
    // Schema-field overlay (StringField / IntField from configSchema).
    if (_editingSchemaFieldName != null) {
      final field = manifest.configSchema?.field(_editingSchemaFieldName!);
      if (field == null || mainConfig == null) {
        _editingSchemaFieldName = null;
      } else if (!fieldRequiresEditor(field)) {
        // Stale state — bool/enum cycle in-place; no overlay.
        _editingSchemaFieldName = null;
      } else {
        final pluginAppId = manifest.id;
        final currentValue = mainConfig.appConfig(pluginAppId)[field.name];
        return buildFieldEditor(
          field: field,
          currentValue: currentValue,
          onSubmit: (value) {
            try {
              final updated = mainConfig.setAppOption(
                pluginAppId,
                field.name,
                value,
              );
              context.read(configProvider.notifier).updateConfig(updated);
              setState(() {
                _editingSchemaFieldName = null;
                _errorMessage = null;
              });
            } catch (e, st) {
              LogService.error('plugin schema field update failed', e, st);
              setState(() {
                _editingSchemaFieldName = null;
                _errorMessage = e.toString();
              });
            }
          },
          onCancel: () {
            setState(() => _editingSchemaFieldName = null);
          },
        );
      }
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            component.onDismiss();
            return true;
          }
          if (event.logicalKey == LogicalKey.keyJ ||
              event.logicalKey == LogicalKey.arrowDown) {
            if (_selectedIndex < rows.length - 1) {
              setState(() => _selectedIndex += 1);
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.keyK ||
              event.logicalKey == LogicalKey.arrowUp) {
            if (_selectedIndex > 0) {
              setState(() => _selectedIndex -= 1);
            }
            return true;
          }
          if (event.logicalKey == LogicalKey.enter ||
              event.logicalKey == LogicalKey.space) {
            _activateRow(context, rows, mainConfig);
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('plugin config key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(pluginId, manifest),
            const SizedBox(height: 1),
            ..._renderRows(rows, manifest, mainConfig),
            if (_errorMessage != null) ...[
              const SizedBox(height: 1),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
              ),
            ],
            const SizedBox(height: 1),
            const Text(
              '[↑/↓] move  [Enter] edit/run  [Esc] back',
              style: TextStyle(color: Color.fromRGB(110, 110, 130)),
            ),
          ],
        ),
      ),
    );
  }

  /// Render the unified rows list with focus highlight + an
  /// "Actions" heading separator if the manifest has both fields
  /// and actions.
  List<Component> _renderRows(
    List<_Row> rows,
    PluginManifest manifest,
    NixblitzConfig? mainConfig,
  ) {
    final out = <Component>[];
    var sawActionsHeading = false;
    final hasFields = manifest.configSchema?.fields.isNotEmpty ?? false;
    final pluginAppId = manifest.id;
    final appCfg = mainConfig?.appConfig(pluginAppId) ?? const {};

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      // Insert the "Actions" heading once, between the last field
      // row and the first action row, when both are present.
      if (row is _ActionRow && hasFields && !sawActionsHeading) {
        out.add(const SizedBox(height: 1));
        out.add(
          const Text(
            'Actions',
            style: TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        sawActionsHeading = true;
      }
      // If the plugin only has actions, also show the heading.
      if (row is _ActionRow && !hasFields && !sawActionsHeading) {
        out.add(
          const Text(
            'Actions',
            style: TextStyle(
              color: Color.fromRGB(247, 147, 26),
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        sawActionsHeading = true;
      }

      final focused = i == _selectedIndex;
      switch (row) {
        case _SchemaFieldRow(:final spec):
          out.add(
            FieldDisplayRow(
              field: spec,
              currentValue: appCfg[spec.name],
              selected: focused,
            ),
          );
        case _ActionRow(:final key, :final action):
          out.add(_actionRow(key, action, focused));
      }
    }
    return out;
  }

  Component _actionRow(String key, PluginAction action, bool focused) {
    final prefix = focused ? '> ' : '  ';
    final color = focused
        ? const Color.fromRGB(247, 147, 26)
        : const Color.fromRGB(200, 200, 200);
    final hint = action.confirm ? '  (requires confirmation)' : '';
    return Text('$prefix${action.label}$hint', style: TextStyle(color: color));
  }

  Component _confirmOverlay(PluginAction action) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape ||
              event.logicalKey == LogicalKey.keyN) {
            setState(() => _confirmingActionId = null);
            return true;
          }
          if (event.logicalKey == LogicalKey.keyY ||
              event.logicalKey == LogicalKey.enter) {
            final id = _confirmingActionId!;
            _launchAction(id, action);
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('plugin action confirm key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Run: ${action.label}',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            if (action.description.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(
                action.description,
                style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
              ),
            ],
            const SizedBox(height: 1),
            Text(
              action.unit != null
                  ? 'Unit: ${action.unit}  (root via systemctl)'
                  : 'Command: ${action.command}',
              style: const TextStyle(color: Color.fromRGB(110, 110, 130)),
            ),
            const SizedBox(height: 1),
            const Text(
              'Proceed? [y/N]',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
          ],
        ),
      ),
    );
  }

  Component _runningOverlay(PluginAction action) {
    final exit = _actionExitCode;
    final isDone = exit != null;
    final headerColor = !isDone
        ? const Color.fromRGB(247, 147, 26)
        : (exit == 0
              ? const Color.fromRGB(110, 220, 110)
              : const Color.fromRGB(220, 180, 100));
    final statusText = !isDone
        ? '${action.label} — running…'
        : (exit == 0
              ? '${action.label} — done (exit 0)'
              : (exit == 124
                    ? '${action.label} — timed out (exit 124)'
                    : '${action.label} — failed (exit $exit)'));

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape ||
              event.logicalKey == LogicalKey.enter) {
            // Hide overlay. If still running, the subprocess keeps
            // going; we cancel the subscription so we don't leak
            // listeners. The overlay's "done" state is lost — user
            // can re-trigger if they need to see output again.
            _actionSub?.cancel();
            _actionSub = null;
            setState(() {
              _runningActionId = null;
              _actionOutput.clear();
              _actionExitCode = null;
            });
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('plugin action running key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              statusText,
              style: TextStyle(color: headerColor, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: ScrollableLog(
                lines: List.unmodifiable(_actionOutput),
                focused: true,
              ),
            ),
            const SizedBox(height: 1),
            if (!isDone)
              Spinner(label: 'Working…')
            else
              const Text(
                '[Enter/Esc] dismiss',
                style: TextStyle(color: Color.fromRGB(150, 150, 180)),
              ),
          ],
        ),
      ),
    );
  }

  Component _header(String pluginId, PluginManifest manifest) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          manifest.name,
          style: const TextStyle(
            color: Color.fromRGB(247, 147, 26),
            fontWeight: FontWeight.bold,
          ),
        ),
        if (manifest.description.isNotEmpty)
          Text(
            manifest.description,
            style: const TextStyle(color: Color.fromRGB(200, 200, 200)),
          ),
        Text(
          pluginId,
          style: const TextStyle(color: Color.fromRGB(110, 110, 130)),
        ),
      ],
    );
  }

  void _activateRow(
    BuildContext context,
    List<_Row> rows,
    NixblitzConfig? mainConfig,
  ) {
    final row = rows[_selectedIndex];
    switch (row) {
      case _SchemaFieldRow(:final spec):
        _activateSchemaField(context, spec, mainConfig);
      case _ActionRow(:final key, :final action):
        if (action.confirm) {
          setState(() {
            _confirmingActionId = key;
            _errorMessage = null;
          });
        } else {
          _launchAction(key, action);
        }
    }
  }

  /// Edit a configSchema field. Bool/Enum cycle in-place and write
  /// to main config.json's `app_configs[pluginId]`. String/Int open
  /// the overlay (see `_editingSchemaFieldName`).
  void _activateSchemaField(
    BuildContext context,
    AppConfigField field,
    NixblitzConfig? mainConfig,
  ) {
    if (mainConfig == null) {
      // Config still loading — refuse silently (highly unlikely:
      // build() handles configAsync.value being null upstream).
      return;
    }
    if (fieldRequiresEditor(field)) {
      setState(() {
        _editingSchemaFieldName = field.name;
        _errorMessage = null;
      });
      return;
    }
    // BoolField / EnumField — cycle in place.
    final pluginAppId = component.pluginId;
    final current = mainConfig.appConfig(pluginAppId)[field.name];
    final next = cycleFieldValue(field, current);
    final updated = mainConfig.setAppOption(pluginAppId, field.name, next);
    context.read(configProvider.notifier).updateConfig(updated);
    setState(() => _errorMessage = null);
  }

  void _launchAction(String id, PluginAction action) {
    final runner = context.read(pluginActionRunnerProvider);
    final session = context.read(sudoSessionProvider);
    LogService.info('plugin action started: $id (${action.label})');

    setState(() {
      _confirmingActionId = null;
      _runningActionId = id;
      _actionOutput.clear();
      _actionExitCode = null;
      _errorMessage = null;
    });

    // Privileged actions go through systemctl-via-sudo, so prime the
    // sudo timestamp first. Unprivileged command actions skip the
    // prompt — they run as the admin user, no auth needed.
    final guard = action.isPrivileged
        ? session.ensureFresh()
        : Future<bool>.value(true);

    guard.then((ok) {
      if (!ok) {
        if (!mounted) return;
        setState(() {
          _actionOutput.add('Authorization cancelled — aborting.\n');
          _actionExitCode = 1;
        });
        return;
      }
      _streamAction(id, runner, action);
    });
  }

  void _streamAction(
    String id,
    PluginActionRunner runner,
    PluginAction action,
  ) {
    final r = runner.run(action);
    _actionSub = r.output.listen(
      (line) {
        // Persist every output line so post-mortem debugging works
        // after the overlay's been dismissed. Mirror what
        // `apply_view` + `update_view` do for nixos-rebuild output.
        for (final l in line.split('\n')) {
          if (l.isEmpty) continue;
          LogService.info('[plugin-action $id] $l');
        }
        if (!mounted) return;
        setState(() => _actionOutput.add(line));
      },
      onError: (e, st) {
        LogService.error('plugin action stream error', e, st);
      },
    );
    r.exitCode
        .then((code) {
          LogService.info('plugin action finished: $id exit=$code');
          if (!mounted) return;
          setState(() => _actionExitCode = code);
        })
        .catchError((e, st) {
          LogService.error('plugin action exitCode threw', e, st);
          if (!mounted) return;
          setState(() => _actionExitCode = -1);
        });
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
