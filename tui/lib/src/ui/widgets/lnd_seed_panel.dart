import 'package:nocterm/nocterm.dart';

/// Renders the LND aezeed mnemonic as a numbered 6×4 grid for
/// the operator to copy onto paper. Pure presentation — the
/// caller owns the seed bytes and the dismiss-on-confirm gate.
///
/// Layout (row-major, reads naturally left-to-right):
///
///   1. quartz       2. dolphin      3. evening     4. mountain
///   5. velvet       6. journey      7. liberty     8. mirror
///   9. salmon      10. eclipse     11. patient    12. crystal
///  13. orbit       14. vivid       15. crystal    16. bishop
///  17. nomad       18. forest      19. galaxy     20. cliff
///  21. theater     22. tundra      23. simple     24. anchor
///
/// Aezeed words are bounded at 8 characters per BIP-0039, so a
/// 16-column cell width fits the longest word plus the index
/// prefix without truncation.
class LndSeedPanel extends StatelessComponent {
  final List<String> words;

  const LndSeedPanel({super.key, required this.words});

  @override
  Component build(BuildContext context) {
    assert(
      words.length == 24,
      'LndSeedPanel expects exactly 24 aezeed words, got ${words.length}',
    );

    final rows = <Component>[];
    for (var row = 0; row < 6; row++) {
      final cells = <Component>[];
      for (var col = 0; col < 4; col++) {
        final idx = row * 4 + col;
        final label = '${(idx + 1).toString().padLeft(2)}. ${words[idx]}';
        cells.add(SizedBox(width: 16, child: Text(label)));
      }
      rows.add(Row(children: cells));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'WRITE THIS DOWN — your LND wallet seed',
          style: const TextStyle(
            color: Color.fromRGB(255, 80, 80),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 1),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          decoration: BoxDecoration(
            border: BoxBorder.all(color: const Color.fromRGB(247, 147, 26)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
        const SizedBox(height: 1),
        const Text('These 24 words restore the ON-CHAIN wallet only.'),
        const Text('Lightning channels need a separate Static Channel'),
        const Text('Backup — LND maintains channel.backup as channels'),
        const Text('open and close; back THAT file up too, or you lose'),
        const Text('funds locked in channels even with the seed.'),
        const SizedBox(height: 1),
        const Text('Anyone with these words controls every on-chain sat'),
        const Text('in the wallet. Write on paper, store offline, never'),
        const Text('type or photograph them.'),
        const SizedBox(height: 1),
        const Text(
          'Note: this is LND aezeed (NOT BIP-39). It restores into',
          style: TextStyle(color: Color.fromRGB(200, 200, 100)),
        ),
        const Text(
          'LND only — hardware wallets like Trezor/Ledger will not',
          style: TextStyle(color: Color.fromRGB(200, 200, 100)),
        ),
        const Text(
          'recognise these words.',
          style: TextStyle(color: Color.fromRGB(200, 200, 100)),
        ),
      ],
    );
  }
}
