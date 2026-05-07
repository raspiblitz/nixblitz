import 'package:common/common.dart';

/// Render a [GitSignature] as a single-line string for the install
/// consent prompt — shared between the CLI's `_askConsent` and the
/// TUI's [PluginInstallView] so both surfaces agree on how a
/// signature looks. Three relevant flavours, plus a generic
/// fall-through:
///
/// - `signed by SSH key SHA256:abc…   (alice@example.com)` — fully
///   verified against the operator's keyring.
/// - `signed by SSH key SHA256:abc… [unverified key]` — good
///   signature, key not in operator's `allowed_signers`. Still
///   pinnable for TOFU.
/// - `(unsigned)` — no signature on the commit. The install can
///   still proceed; subsequent refreshes won't be able to detect
///   key changes.
///
/// The trust-model background lives in
/// `docs/decisions/plugin-trust-models.md` Approach A.
String describeSignature(GitSignature s) {
  if (!s.isPresent) return '(unsigned)';
  final fp = s.fingerprint.isEmpty ? '(no fingerprint)' : s.fingerprint;
  final identity = s.signer.isEmpty ? '' : '   (${s.signer})';
  switch (s.status) {
    case 'G':
      return 'signed by $fp$identity';
    case 'U':
      return 'signed by $fp$identity [unverified key]';
    case 'X':
      return 'signed by $fp$identity [signature expired]';
    case 'Y':
      return 'signed by $fp$identity [signing key expired]';
    case 'R':
      return 'signed by $fp$identity [signing key revoked]';
    case 'B':
      return 'BAD signature ($fp)';
    default:
      return 'signed (status=${s.status}, fp=$fp)';
  }
}
