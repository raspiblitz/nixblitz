import 'package:nocterm/nocterm.dart';

/// Single-source-of-truth warning callout shown on the install
/// wizard's first screen and the first-boot setup's first screen.
/// NixBlitz is pre-1.0, hasn't been audited, and the operator is
/// about to either wipe a disk or commit a config that controls
/// real Lightning channels — make sure they understand the risk
/// before they get there.
///
/// Yellow-on-bordered panel, mirrors the website hero callout and
/// the dashboard's drift-banner / pending-marker hue. Wrapping the
/// markup once here keeps the copy identical across surfaces; if
/// the wording needs to change, change it here.
class ExperimentalWarning extends StatelessComponent {
  const ExperimentalWarning({super.key});

  static const _kWarn = Color.fromRGB(220, 180, 100);

  @override
  Component build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      decoration: BoxDecoration(
        border: BoxBorder.all(color: _kWarn),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            '[!] highly experimental — under construction',
            style: TextStyle(color: _kWarn, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 1),
          Text(
            "NixBlitz has NOT received a thorough security review.",
            style: TextStyle(color: _kWarn),
          ),
          Text(
            "Don't use it for production funds. Run on regtest in",
            style: TextStyle(color: _kWarn),
          ),
          Text(
            "a VM or on dedicated hardware you're okay reinstalling.",
            style: TextStyle(color: _kWarn),
          ),
          Text(
            'Things will break.',
            style: TextStyle(color: _kWarn),
          ),
        ],
      ),
    );
  }
}
