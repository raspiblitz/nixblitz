import 'package:common/common.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/nocterm_test.dart';
import 'package:test/test.dart';
import 'package:tui/src/ui/widgets/build_progress_panel.dart';

void main() {
  group('BuildProgressPanel', () {
    test('renders a bar with percent while copying', () async {
      await testNocterm('renders a bar with percent while copying', (
        tester,
      ) async {
        await tester.pumpComponent(
          const BuildProgressPanel(
            progress: InstallProgress(
              phase: InstallPhase.copying,
              copyFraction: 0.73,
            ),
            elapsedSeconds: 252,
            recentLines: ['copying path a', 'copying path b'],
          ),
        );

        expect(tester.terminalState, containsText('Copying NixOS store paths'));
        expect(tester.terminalState, containsText('73%'));
        expect(tester.terminalState, containsText('4m12s'));
      });
    });

    test('renders a spinner (no bar) when copyFraction is null', () async {
      await testNocterm(
        'renders a spinner (no bar) when copyFraction is null',
        (tester) async {
          await tester.pumpComponent(
            const BuildProgressPanel(
              progress: InstallProgress(
                phase: InstallPhase.installing,
                copyFraction: null,
              ),
              elapsedSeconds: 3,
              recentLines: ['installing the boot loader'],
            ),
          );

          final s = tester.terminalState.getText();
          expect(s, contains('Installing bootloader'));
          expect(s, isNot(contains('%')));
          expect(s, contains('[l]'));
        },
      );
    });
  });
}
