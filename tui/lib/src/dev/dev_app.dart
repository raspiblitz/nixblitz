import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';
import 'views/confirm_prompt_demo_view.dart';
import 'views/dashboard_demo_view.dart';
import 'views/dev_menu_view.dart';
import 'views/help_popup_demo_view.dart';
import 'views/log_demo_view.dart';
import 'views/option_editor_demo_view.dart';
import 'views/password_input_demo_view.dart';
import 'views/select_popup_demo_view.dart';
import 'views/service_card_demo_view.dart';
import 'views/spinner_demo_view.dart';

/// Views available in the dev app.
enum DevView {
  menu,
  logDemo,
  passwordInput,
  confirmPrompt,
  selectPopup,
  spinner,
  optionEditor,
  serviceCard,
  helpPopup,
  dashboard,
}

final currentDevViewProvider = StateProvider<DevView>((ref) => DevView.menu);

void _shutdownWithTerminalRestore([int exitCode = 0]) {
  try {
    if (stdin.hasTerminal) {
      stdin.lineMode = true;
      stdin.echoMode = true;
    }
  } catch (e) {
    LogService.warn('Failed to restore terminal mode before shutdown: $e');
  }
  shutdownApp(exitCode);
}

class DevApp extends StatelessComponent {
  const DevApp({super.key});

  @override
  Component build(BuildContext context) {
    return ProviderScope(
      child: NoctermApp(
        title: 'NixBlitz Dev',
        theme: TuiThemeData.dark.copyWith(
          primary: const Color.fromRGB(247, 147, 26),
          background: const Color.fromRGB(24, 24, 36),
          surface: const Color.fromRGB(36, 36, 54),
          onBackground: const Color.fromRGB(220, 220, 220),
          onSurface: const Color.fromRGB(200, 200, 200),
          onPrimary: const Color.fromRGB(0, 0, 0),
          outline: const Color.fromRGB(80, 80, 100),
          outlineVariant: const Color.fromRGB(60, 60, 80),
          selectionColor: const Color.fromRGB(80, 80, 120),
        ),
        home: const _DevShell(),
      ),
    );
  }
}

class _DevShell extends StatelessComponent {
  const _DevShell();

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.matches(LogicalKey.keyC, ctrl: true)) {
            _shutdownWithTerminalRestore();
            return true;
          }
          final currentView = context.read(currentDevViewProvider);
          if (currentView == DevView.menu &&
              event.logicalKey == LogicalKey.keyQ) {
            _shutdownWithTerminalRestore();
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Dev shell key handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              decoration: const BoxDecoration(
                border: BoxBorder(
                  bottom: BorderSide(color: Color.fromRGB(80, 80, 100)),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'NIXBLITZ DEV',
                    style: TextStyle(
                      color: Color.fromRGB(247, 147, 26),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'not for production',
                    style: TextStyle(color: Color.fromRGB(255, 120, 120)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: switch (context.watch(currentDevViewProvider)) {
                DevView.menu => const DevMenuView(),
                DevView.logDemo => const LogDemoView(),
                DevView.passwordInput => const PasswordInputDemoView(),
                DevView.confirmPrompt => const ConfirmPromptDemoView(),
                DevView.selectPopup => const SelectPopupDemoView(),
                DevView.spinner => const SpinnerDemoView(),
                DevView.optionEditor => const OptionEditorDemoView(),
                DevView.serviceCard => const ServiceCardDemoView(),
                DevView.helpPopup => const HelpPopupDemoView(),
                DevView.dashboard => const DashboardDemoView(),
              },
            ),
          ],
        ),
      ),
    );
  }
}
