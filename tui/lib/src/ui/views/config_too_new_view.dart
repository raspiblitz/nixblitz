import 'dart:convert';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:common/common.dart';
import '../widgets/scrollable_log.dart';
import '../../providers/ui_state_provider.dart';

/// Shown when `config.json` declares a `version` higher than
/// [currentConfigVersion]. The user's config was written by a newer TUI
/// and this one may drop unknown fields on save. Offer a way to continue
/// at their own risk or quit and upgrade.
class ConfigTooNewView extends StatelessComponent {
  const ConfigTooNewView({super.key});

  @override
  Component build(BuildContext context) {
    final baseDir = context.read(baseDirProvider);
    final path = '$baseDir/config.json';

    String rawConfig = '';
    int diskVersion = 0;
    bool initialized = false;

    try {
      rawConfig = File(path).readAsStringSync();
      final json = jsonDecode(rawConfig) as Map<String, dynamic>;
      diskVersion = (json['version'] as int?) ?? 0;
      initialized = json['initialized'] == true;
    } catch (e) {
      rawConfig = '(could not read $path: $e)';
    }

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.keyC) {
            context.read(currentViewProvider.notifier).state =
                initialized ? AppView.dashboard : AppView.setup;
            return true;
          }
          if (event.logicalKey == LogicalKey.keyQ) {
            exit(0);
          }
          return false;
        } catch (e, st) {
          LogService.error('ConfigTooNew key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Config is newer than this TUI',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              'config.json: v$diskVersion   '
              'this TUI: v$currentConfigVersion',
              style: const TextStyle(color: Color.fromRGB(220, 220, 220)),
            ),
            const SizedBox(height: 1),
            const Text(
              'Fields this TUI does not understand may be dropped on save.',
              style: TextStyle(color: Color.fromRGB(220, 180, 100)),
            ),
            const SizedBox(height: 1),
            const Text(
              'config.json (current on-disk content):',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            Expanded(child: ScrollableLog(lines: rawConfig.split('\n'))),
            const SizedBox(height: 1),
            const Text(
              '[c] Continue anyway   [q] Quit',
              style: TextStyle(color: Color.fromRGB(247, 147, 26)),
            ),
          ],
        ),
      ),
    );
  }
}
