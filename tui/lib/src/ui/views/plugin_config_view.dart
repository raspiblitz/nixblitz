import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';

import '../widgets/plugin_field_editor.dart';

/// Per-plugin config form. Rendered by [ConfigureView] when the user
/// picks a plugin from the `plugins` tab.
///
/// Owns its own local state (selected-field index + overlay-open
/// field key). On Esc from the form list, calls [onDismiss] so the
/// parent can go back to the plugin list.
class PluginConfigView extends StatefulComponent {
  final PluginEntry entry;
  final VoidCallback onDismiss;

  const PluginConfigView({
    super.key,
    required this.entry,
    required this.onDismiss,
  });

  @override
  State<PluginConfigView> createState() => _PluginConfigViewState();
}

class _PluginConfigViewState extends State<PluginConfigView> {
  int _selectedIndex = 0;
  String? _overlayFieldKey;
  String? _errorMessage;

  @override
  Component build(BuildContext context) {
    final entry = component.entry;
    final notifier = context.read(
      pluginConfigProvider(entry.dirName).notifier,
    );

    final PluginManifest manifest;
    try {
      manifest = notifier.manifest();
    } catch (e, st) {
      LogService.error('failed to read plugin manifest', e, st);
      return _errorScreen(context, 'Failed to load manifest: $e');
    }

    final configAsync = context.watch(pluginConfigProvider(entry.dirName));

    return configAsync.when(
      loading: () => const Center(child: Text('Loading plugin config…')),
      error: (e, _) => _errorScreen(context, 'Error: $e'),
      data: (cfg) => _body(context, manifest, cfg, notifier),
    );
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
    Map<String, dynamic> cfg,
    PluginConfigNotifier notifier,
  ) {
    final entry = component.entry;
    final fields = manifest.config.entries.toList();

    // If there's nothing configurable, render a stub and still allow
    // Esc to leave.
    if (fields.isEmpty) {
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
              _header(entry, manifest),
              const SizedBox(height: 1),
              const Text(
                '(no configurable fields)',
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

    // Text-edit overlay on top of the form list.
    final overlayKey = _overlayFieldKey;
    if (overlayKey != null) {
      final spec = manifest.config[overlayKey];
      if (spec == null) {
        // Defensive: overlay pointed at a field that no longer
        // exists (manifest churn mid-edit). Drop the overlay.
        _overlayFieldKey = null;
      } else {
        return PluginTextOverlay(
          spec: spec,
          fieldKey: overlayKey,
          initialValue: cfg[overlayKey],
          onSubmit: (value) async {
            try {
              await notifier.updateField(overlayKey, value);
              setState(() {
                _overlayFieldKey = null;
                _errorMessage = null;
              });
            } catch (e, st) {
              LogService.error('plugin field update failed', e, st);
              setState(() {
                _overlayFieldKey = null;
                _errorMessage = e.toString();
              });
            }
          },
          onCancel: () {
            setState(() => _overlayFieldKey = null);
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
            if (_selectedIndex < fields.length - 1) {
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
            _activateSelectedField(fields, cfg, notifier);
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
            _header(entry, manifest),
            const SizedBox(height: 1),
            ...List.generate(fields.length, (i) {
              final e = fields[i];
              return PluginFieldRow(
                spec: e.value,
                fieldKey: e.key,
                value: cfg[e.key] ?? e.value.defaultValue,
                focused: i == _selectedIndex,
              );
            }),
            if (_errorMessage != null) ...[
              const SizedBox(height: 1),
              Text(
                _errorMessage!,
                style: const TextStyle(
                  color: Color.fromRGB(255, 80, 80),
                ),
              ),
            ],
            const SizedBox(height: 1),
            const Text(
              '[↑/↓] move  [Enter] edit  [Esc] back',
              style: TextStyle(color: Color.fromRGB(110, 110, 130)),
            ),
          ],
        ),
      ),
    );
  }

  Component _header(PluginEntry entry, PluginManifest manifest) {
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
          entry.id,
          style: const TextStyle(color: Color.fromRGB(110, 110, 130)),
        ),
      ],
    );
  }

  void _activateSelectedField(
    List<MapEntry<String, ConfigField>> fields,
    Map<String, dynamic> cfg,
    PluginConfigNotifier notifier,
  ) {
    final entry = fields[_selectedIndex];
    final spec = entry.value;
    final key = entry.key;

    // Bool / select cycle in place; everything else opens the
    // text-entry overlay.
    try {
      final cycled = cyclePrimitiveValue(spec, cfg[key] ?? spec.defaultValue);
      if (cycled != null) {
        notifier.updateField(key, cycled).then((_) {
          if (mounted) setState(() => _errorMessage = null);
        }).catchError((e, st) {
          LogService.error('plugin field cycle failed', e, st);
          if (mounted) setState(() => _errorMessage = e.toString());
        });
        return;
      }
    } on UnimplementedError catch (e) {
      setState(() => _errorMessage = e.message ?? 'unsupported field type');
      return;
    }

    // Text-shaped fields: open the overlay.
    if (fieldRequiresOverlay(spec)) {
      setState(() {
        _overlayFieldKey = key;
        _errorMessage = null;
      });
    }
  }
}
