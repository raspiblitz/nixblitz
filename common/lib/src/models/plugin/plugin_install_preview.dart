import 'package:common/src/services/git_service.dart';

/// Snapshot of what `PluginService.install` is about to land. Built
/// after the source repo is cloned + manifest parsed but before
/// any files are copied into the operator's tree, then handed to a
/// confirm callback so the CLI / TUI can surface the metadata for
/// consent.
///
/// **Important framing.** Confirming an install is equivalent to
/// granting the plugin author root on the node. `plugin.nix` is
/// arbitrary Nix code that runs at `nixos-rebuild` time as root —
/// it can declare any systemd service, activation script, or
/// derivation it wants, including ones that exfiltrate secrets or
/// open backdoors. The fields here are *metadata*, not a sandbox.
/// Do not surface them in a way that implies otherwise.
class PluginInstallPreview {
  const PluginInstallPreview({
    required this.name,
    required this.description,
    required this.url,
    required this.branch,
    required this.pinnedRev,
    required this.schemaVersion,
    required this.signature,
  });

  /// Display name from `manifest.json` (e.g. "Tailscale", "LNBits").
  final String name;

  /// Long-form description from `manifest.json`. May be empty.
  final String description;

  /// Canonical source URL (the same string that ends up as
  /// [PluginEntry.id] / [PluginEntry.url]). Surfaced so the operator
  /// can re-verify they're installing from where they intended.
  final String url;

  /// Branch / ref that the clone tracked.
  final String branch;

  /// 40-char SHA the clone landed at. Pinning to this rev is what
  /// makes "review the code first" feasible — once pinned, the
  /// plugin tree on disk can't change without a manifest update
  /// (which goes through `plugin refresh` + a follow-up consent).
  final String pinnedRev;

  /// `manifest.schema_version`. Affects how the loader interprets
  /// the rest of the manifest, so worth surfacing at consent time.
  final int schemaVersion;

  /// Signature on the commit at [pinnedRev]. The CLI / TUI renders
  /// this in the consent prompt — `signed by SSH key SHA256:abc…`
  /// when present, "(unsigned)" when not. The fingerprint is what
  /// the install pins for TOFU; subsequent refreshes that don't
  /// match are escalated to re-consent. See
  /// `docs/decisions/plugin-trust-models.md` Approach A.
  final GitSignature signature;
}

/// Thrown by `PluginService.install` when the operator declines the
/// confirm prompt. Caught by the CLI / TUI and rendered as a clean
/// "aborted" message. Tmpdir cleanup happens in the install method's
/// `finally` block regardless.
class PluginInstallCancelled implements Exception {
  const PluginInstallCancelled();

  @override
  String toString() => 'plugin install cancelled by user';
}

/// Thrown by `PluginService.refresh` when the new commit's signing
/// key doesn't match the fingerprint pinned at install time
/// (Approach A in `docs/decisions/plugin-trust-models.md`).
///
/// Surfaces as a hard refresh failure so the operator must
/// explicitly re-consent — typically via `plugin remove <id>` +
/// `plugin add <url>` — before the new key is accepted. A bare
/// re-run of `plugin refresh` would just hit the same mismatch
/// again, which is the intended behaviour.
class PluginSignatureMismatch implements Exception {
  const PluginSignatureMismatch({
    required this.pluginId,
    required this.expected,
    required this.actual,
  });

  /// Plugin URL whose pin we tried to verify.
  final String pluginId;

  /// Fingerprint stored on the [PluginEntry] at install / last
  /// successful refresh.
  final String expected;

  /// Fingerprint observed on the new HEAD. Null when the new
  /// commit is unsigned — also a mismatch worth flagging since
  /// "publisher stopped signing" is suspicious in the same way as
  /// "publisher swapped keys."
  final String? actual;

  @override
  String toString() {
    final actualStr = actual ?? '(unsigned)';
    return 'plugin signature changed for $pluginId: '
        'expected=$expected actual=$actualStr';
  }
}

/// Signature of the consent callback `PluginService.install` invokes
/// after fetching the manifest. Return `true` to proceed, `false` to
/// abort (the install method then throws [PluginInstallCancelled]).
typedef PluginInstallConfirm = Future<bool> Function(
  PluginInstallPreview preview,
);
