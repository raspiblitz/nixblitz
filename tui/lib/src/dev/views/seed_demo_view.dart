import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/legacy.dart';
import 'package:common/common.dart';

import '../../ui/widgets/lnd_seed_panel.dart';
import '../dev_app.dart';

/// Hardcoded fake aezeed-like words for the dev-mode seed flow
/// preview. Real BIP-39 wordlist entries so the cell width and
/// padding match a production seed visually, but in
/// alphabetical order so it can never be mistaken for a real
/// LND mnemonic — and the TEST MODE banner above the panel
/// makes the distinction explicit.
const List<String> _kFakeSeedWords = [
  'abandon',
  'ability',
  'able',
  'about',
  'above',
  'absent',
  'absorb',
  'abstract',
  'absurd',
  'abuse',
  'access',
  'accident',
  'account',
  'accuse',
  'achieve',
  'acid',
  'acoustic',
  'acquire',
  'across',
  'act',
  'action',
  'actor',
  'actress',
  'actual',
];

enum _Stage { choice, display }

final _stageProvider = StateProvider<_Stage>((ref) => _Stage.choice);

/// Dev-only preview of the first-boot LND-seed reveal flow.
///
/// Mirrors the production `setup_view.dart` choice + display +
/// confirm states one-for-one, but with a hardcoded fake
/// mnemonic and no sudo / file I/O. Useful for iterating on
/// copy and layout without standing up a fresh install.
class SeedDemoView extends StatelessComponent {
  const SeedDemoView({super.key});

  @override
  Component build(BuildContext context) {
    final stage = context.watch(_stageProvider);
    return switch (stage) {
      _Stage.choice => const _ChoiceStage(),
      _Stage.display => const _DisplayStage(),
    };
  }
}

class _ChoiceStage extends StatelessComponent {
  const _ChoiceStage();

  void _backToMenu(BuildContext context) {
    context.read(_stageProvider.notifier).state = _Stage.choice;
    context.read(currentDevViewProvider.notifier).state = DevView.menu;
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            _backToMenu(context);
            return true;
          }
          final c = event.character?.toLowerCase();
          if (c == 'a') {
            context.read(_stageProvider.notifier).state = _Stage.display;
            return true;
          }
          if (c == 'b') {
            // Production flow advances to the setup summary; in
            // dev mode we just leave the test view.
            _backToMenu(context);
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Seed demo choice handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _TestModeBanner(),
            const SizedBox(height: 1),
            Text(
              'Lightning Wallet Setup',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              'IMPORTANT: This 24-word seed restores ONLY the',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'on-chain wallet. Lightning channels need a separate',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'channel.backup that LND updates automatically.',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Without BOTH, funds are lost if this disk fails.',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text('Choose:'),
            const SizedBox(height: 1),
            const Text('  [A] Show the seed on screen now'),
            const Text(
              '      Have pen and paper ready. Best in private —',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const Text(
              '      no cameras, recordings, or shoulder-surfers.',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const SizedBox(height: 1),
            const Text('  [B] Continue without showing'),
            const Text(
              '      Safer in public / livestreamed / recorded',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const Text(
              '      environments. Read the seed later with:',
              style: TextStyle(color: Color.fromRGB(150, 150, 180)),
            ),
            const Text(
              '        sudo cat /mnt/data/lnd/lnd-seed-mnemonic',
              style: TextStyle(color: Color.fromRGB(200, 200, 100)),
            ),
            const SizedBox(height: 1),
            Text(
              'Either choice: copy the words to durable offline',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'storage (paper or steel) as soon as practical. The',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'on-disk file is NOT a substitute for an offline backup.',
              style: const TextStyle(
                color: Color.fromRGB(255, 80, 80),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const Text(
              'Press [A] to show, [B] to continue, [Esc] back to menu.',
            ),
          ],
        ),
      ),
    );
  }
}

class _DisplayStage extends StatelessComponent {
  const _DisplayStage();

  void _backToMenu(BuildContext context) {
    context.read(_stageProvider.notifier).state = _Stage.choice;
    context.read(currentDevViewProvider.notifier).state = DevView.menu;
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        try {
          if (event.logicalKey == LogicalKey.escape) {
            _backToMenu(context);
            return true;
          }
          final c = event.character?.toLowerCase();
          if (c == 'y') {
            // Production flow wipes the in-memory seed and
            // advances to summary. In dev mode there's nothing
            // to wipe — the words are a const — so we just
            // exit back to the dev menu.
            _backToMenu(context);
            return true;
          }
          return false;
        } catch (e, st) {
          LogService.error('Seed demo display handler failed', e, st);
          return true;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _TestModeBanner(),
            const SizedBox(height: 1),
            Text(
              'Lightning Wallet Setup',
              style: const TextStyle(
                color: Color.fromRGB(247, 147, 26),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            const LndSeedPanel(words: _kFakeSeedWords),
            const SizedBox(height: 1),
            const Text(
              'Press Y when you have written the seed down, '
              '[Esc] back to menu.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Visible-from-orbit reminder that the words below are NOT
/// real and should never be backed up. Keeps a developer
/// inspecting the layout from accidentally treating the
/// preview as a live seed.
class _TestModeBanner extends StatelessComponent {
  const _TestModeBanner();

  @override
  Component build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: const BoxDecoration(color: Color.fromRGB(120, 60, 60)),
      child: const Text(
        ' DEV TEST MODE — seed below is fake, do NOT back up ',
        style: TextStyle(
          color: Color.fromRGB(255, 230, 230),
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
