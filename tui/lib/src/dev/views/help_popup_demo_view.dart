import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import '../../ui/widgets/help_popup.dart';
import '../dev_app.dart';

final _helpVisibleProvider = StateProvider<bool>((ref) => true);

class HelpPopupDemoView extends StatelessComponent {
  const HelpPopupDemoView({super.key});

  @override
  Component build(BuildContext context) {
    final visible = context.watch(_helpVisibleProvider);

    return Stack(
      children: [
        Focusable(
          focused: !visible,
          onKeyEvent: (event) {
            try {
              if (event.logicalKey == LogicalKey.question) {
                context.read(_helpVisibleProvider.notifier).state = true;
                return true;
              }
              if (event.logicalKey == LogicalKey.escape) {
                context.read(_helpVisibleProvider.notifier).state = true;
                context.read(currentDevViewProvider.notifier).state =
                    DevView.menu;
                return true;
              }
              return false;
            } catch (e, st) {
              LogService.error('Help popup demo key handler failed', e, st);
              return true;
            }
          },
          child: Container(
            padding: const EdgeInsets.all(2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Help Popup Demo',
                  style: TextStyle(
                    color: Color.fromRGB(247, 147, 26),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 1),
                const Text('The popup should overlay this page.'),
                const Text(
                  '[?] show popup  [Esc] close popup / back to menu',
                  style: TextStyle(color: Color.fromRGB(150, 150, 180)),
                ),
              ],
            ),
          ),
        ),
        if (visible)
          HelpPopup(
            onClose: () {
              context.read(_helpVisibleProvider.notifier).state = false;
            },
          ),
      ],
    );
  }
}
