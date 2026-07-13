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
    this.secretFieldNames = const [],
  });

  /// Display name from `plugin.json` (e.g. "Tailscale", "LNBits").
  final String name;

  /// Long-form description from `plugin.json`. May be empty.
  final String description;

  /// Canonical source URL (the same string that ends up as
  /// [PluginMarker.url]). Surfaced so the operator can re-verify
  /// they're installing from where they intended.
  final String url;

  /// Branch / ref that the clone tracked.
  final String branch;

  /// 40-char SHA the clone landed at. Pinning to this rev is what
  /// makes "review the code first" feasible — once pinned, the
  /// plugin tree on disk can't change without a manifest update
  /// (which goes through `plugin update` + a follow-up consent).
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

  /// Names of `type: "secret"` fields in the manifest's
  /// config_schema. NixBlitz has no secret store: values typed into
  /// these fields land **cleartext** in the git-tracked
  /// `config.json` and become world-readable in `/nix/store` once
  /// the plugin module consumes them. The consent prompt must warn
  /// loudly when this list is non-empty so the operator knows what
  /// they're about to persist. Empty for the (recommended) plugins
  /// that take secrets via ephemeral action inputs instead.
  final List<String> secretFieldNames;
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
/// re-run of `plugin update` would just hit the same mismatch
/// again, which is the intended behaviour.
class PluginSignatureMismatch implements Exception {
  const PluginSignatureMismatch({
    required this.pluginId,
    required this.expected,
    required this.actual,
  });

  /// Plugin URL whose pin we tried to verify.
  final String pluginId;

  /// Fingerprint stored on the [PluginMarker] at install / last
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

/// Thrown by `PluginService.switchBranch` when the operator tries to
/// switch a plugin's branch while the plugin is pinned
/// (`autoUpdate == false`). Pin semantics are literal: the operator
/// asked for "don't move me," so we don't move them. Surfaces a clear
/// recovery path (`nixblitz plugin unpin <id>`).
class PluginPinnedException implements Exception {
  const PluginPinnedException({required this.pluginId});

  /// Plugin id whose marker has `autoUpdate == false`.
  final String pluginId;

  @override
  String toString() =>
      'plugin $pluginId is pinned; unpin it first '
      '(`nixblitz plugin unpin $pluginId`) before switching branches';
}

/// Signature of the consent callback `PluginService.install` invokes
/// after fetching the manifest. Return `true` to proceed, `false` to
/// abort (the install method then throws [PluginInstallCancelled]).
typedef PluginInstallConfirm =
    Future<bool> Function(PluginInstallPreview preview);
