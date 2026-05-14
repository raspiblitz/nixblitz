/// Result of the periodic update checker, surfaced on the dashboard
/// as a "X updates available" banner. Two independent sections, each
/// updated by its own systemd timer:
///
/// - `lightweight`: cheap upstream-HEAD checks via GitHub / Forgejo
///   APIs. Daily-ish. Only knows "an input has moved", not what
///   packages changed.
/// - `heavy`: full `nix flake update` + eval + `nvd diff` in a temp
///   working copy. Weekly-ish. Captures the per-package version
///   delta in [HeavyCheck.diffText].
///
/// Both sections may be absent (file missing on a fresh install) or
/// stale (last timer run failed). The dashboard renders defensively
/// off whichever section is present.
library;

import 'dart:convert';
import 'dart:io';

/// Attribute name of the flake input that pins the running TUI's
/// own source — matches `templates/flake.nix:13`. Spelled out once
/// here so consumers (System Check panel, Update view's status
/// block, action_gating) don't drift if the input is ever renamed.
const String kTuiInputName = 'nixblitz';

/// Where the periodic checker writes its result. systemd-tmpfiles
/// creates the directory with admin:admin ownership; the
/// `nixblitz check {light,heavy}` commands run as `admin` and write
/// here, the TUI reads from it.
///
/// Overridable via the `NIXBLITZ_UPDATE_STATUS_PATH` env var so
/// running the binary on a dev box (no systemd-tmpfiles seeding the
/// dir) doesn't crash on path-create. Production NixOS runs leave
/// the env unset and use the default.
String get updateStatusPath {
  final override = Platform.environment['NIXBLITZ_UPDATE_STATUS_PATH'];
  if (override != null && override.isNotEmpty) return override;
  return '/var/lib/nixblitz-tui/update-status.json';
}

/// Read the on-disk status. Returns [UpdateStatus.empty] if the file
/// is missing or corrupt — never throws. Used by the dashboard
/// banner; cheap enough to call on every dashboard rebuild.
UpdateStatus readUpdateStatus({String? path}) {
  final f = File(path ?? updateStatusPath);
  if (!f.existsSync()) return UpdateStatus.empty();
  try {
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return UpdateStatus.fromJson(j);
  } catch (_) {
    return UpdateStatus.empty();
  }
}

class UpdateStatus {
  const UpdateStatus({this.lightweight, this.heavy});

  factory UpdateStatus.empty() => const UpdateStatus();

  final LightCheck? lightweight;
  final HeavyCheck? heavy;

  factory UpdateStatus.fromJson(Map<String, dynamic> json) => UpdateStatus(
    lightweight: json['lightweight'] is Map<String, dynamic>
        ? LightCheck.fromJson(json['lightweight'] as Map<String, dynamic>)
        : null,
    heavy: json['heavy'] is Map<String, dynamic>
        ? HeavyCheck.fromJson(json['heavy'] as Map<String, dynamic>)
        : null,
  );

  Map<String, dynamic> toJson() => {
    if (lightweight != null) 'lightweight': lightweight!.toJson(),
    if (heavy != null) 'heavy': heavy!.toJson(),
  };

  UpdateStatus copyWith({LightCheck? lightweight, HeavyCheck? heavy}) =>
      UpdateStatus(
        lightweight: lightweight ?? this.lightweight,
        heavy: heavy ?? this.heavy,
      );
}

class LightCheck {
  const LightCheck({
    required this.checkedAt,
    required this.ok,
    this.error,
    this.inputsAhead = const [],
    this.pluginsAhead = const [],
  });

  final DateTime checkedAt;

  /// True when the run completed without infrastructural errors
  /// (network, JSON parse, missing flake.lock). [inputsAhead] can
  /// be empty even when ok=true — that's the "everything up to date"
  /// case.
  final bool ok;

  /// Human-readable summary of why ok=false. Null on success.
  final String? error;

  /// Inputs whose upstream tip has moved past the locally-locked
  /// commit. Empty list ⇒ nothing to update.
  final List<InputAhead> inputsAhead;

  /// Installed plugins (auto_update=true, pinnedRev != null) whose
  /// upstream HEAD has moved past the rev recorded in `config.json`.
  /// Empty list ⇒ nothing to update.
  final List<PluginAhead> pluginsAhead;

  factory LightCheck.fromJson(Map<String, dynamic> j) => LightCheck(
    checkedAt: DateTime.parse(j['checked_at'] as String),
    ok: j['ok'] as bool? ?? true,
    error: j['error'] as String?,
    inputsAhead: ((j['inputs_ahead'] as List?) ?? const [])
        .map((e) => InputAhead.fromJson(e as Map<String, dynamic>))
        .toList(),
    pluginsAhead: ((j['plugins_ahead'] as List?) ?? const [])
        .map((e) => PluginAhead.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'checked_at': checkedAt.toIso8601String(),
    'ok': ok,
    if (error != null) 'error': error,
    'inputs_ahead': inputsAhead.map((e) => e.toJson()).toList(),
    'plugins_ahead': pluginsAhead.map((e) => e.toJson()).toList(),
  };
}

/// One flake input whose upstream HEAD differs from our locked rev.
class InputAhead {
  const InputAhead({
    required this.name,
    required this.currentRev,
    required this.upstreamRev,
    required this.url,
  });

  /// Input attribute name from `flake.nix` (e.g. `nixpkgs`).
  final String name;

  /// 40-char SHA we currently have locked.
  final String currentRev;

  /// 40-char SHA the upstream branch / ref is at now.
  final String upstreamRev;

  /// Original URL string (helpful when surfacing the source of an
  /// update in the dashboard).
  final String url;

  factory InputAhead.fromJson(Map<String, dynamic> j) => InputAhead(
    name: j['name'] as String,
    currentRev: j['current_rev'] as String,
    upstreamRev: j['upstream_rev'] as String,
    url: j['url'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'current_rev': currentRev,
    'upstream_rev': upstreamRev,
    'url': url,
  };
}

/// Like [InputAhead] but for an installed plugin. The lightweight
/// check probes each `autoUpdate=true` plugin's upstream HEAD
/// against the rev recorded on its [PluginMarker] and emits one of
/// these per plugin that has moved.
///
/// Pinned plugins (`autoUpdate == false`) are intentionally skipped
/// — the operator opted out of automatic refreshes for them.
class PluginAhead {
  const PluginAhead({
    required this.pluginId,
    required this.currentRev,
    required this.upstreamRev,
    required this.url,
    this.currentVersion,
    this.upstreamVersion,
    this.isDowngrade = false,
    this.forcePushDetected = false,
  });

  /// Matches `PluginMarker.id` — the on-disk directory under
  /// `~/nixblitz/plugins/`, also the join key the plugins menu uses.
  final String pluginId;

  /// Full SHA we have locked in the plugin's marker file.
  final String currentRev;

  /// Full SHA the upstream branch is at now.
  final String upstreamRev;

  /// Source URL (clone URL); useful for surfacing where an update came
  /// from in the plugins menu.
  final String url;

  /// Manifest version recorded for the currently-installed rev (the
  /// `version` string captured at install time). Null when the
  /// plugin's manifest had no `version` field — the operator's
  /// plugin tracks via SHA only.
  final String? currentVersion;

  /// Manifest version string at the new pin candidate. Null when
  /// upstream has no `version` field. Together with [currentVersion],
  /// drives the per-plugin "1.2.0 → 1.2.4" display in Configure →
  /// Plugins; raw strings (not `Version`) so the JSON status file
  /// stays portable.
  final String? upstreamVersion;

  /// True when the upstream version parses lower than the locally-
  /// pinned version (author cut a release, reverted, didn't re-bump).
  /// The lightweight check still emits a PluginAhead row so the
  /// operator sees the regression, but the dashboard renders it
  /// amber and refuses to auto-apply. `nixblitz plugin refresh
  /// --force ID` opts in to a deliberate rollback. See
  /// `docs/decisions/2026-05-14-plugin-version-tracking.md` §5.
  final bool isDowngrade;

  /// True when the previously-pinned rev (the SHA in [currentRev])
  /// is no longer reachable on the upstream branch — the author
  /// force-pushed history. The check still proceeds (we don't refuse
  /// updates on this signal; sign-key verification is the real
  /// security mechanism), but surfaces a banner so the operator
  /// knows their pin's history was rewritten. Logged at WARN.
  final bool forcePushDetected;

  factory PluginAhead.fromJson(Map<String, dynamic> j) => PluginAhead(
    // Accept the legacy `dir_name` key as well as the current
    // `plugin_id` so a status file written by an older TUI keeps
    // round-tripping cleanly.
    pluginId: (j['plugin_id'] as String?) ?? (j['dir_name'] as String? ?? ''),
    currentRev: j['current_rev'] as String,
    upstreamRev: j['upstream_rev'] as String,
    url: j['url'] as String? ?? '',
    currentVersion: j['current_version'] as String?,
    upstreamVersion: j['upstream_version'] as String?,
    isDowngrade: (j['is_downgrade'] as bool?) ?? false,
    forcePushDetected: (j['force_push_detected'] as bool?) ?? false,
  );

  Map<String, dynamic> toJson() => {
    'plugin_id': pluginId,
    'current_rev': currentRev,
    'upstream_rev': upstreamRev,
    'url': url,
    if (currentVersion != null) 'current_version': currentVersion,
    if (upstreamVersion != null) 'upstream_version': upstreamVersion,
    if (isDowngrade) 'is_downgrade': true,
    if (forcePushDetected) 'force_push_detected': true,
  };
}

class HeavyCheck {
  const HeavyCheck({
    required this.checkedAt,
    required this.ok,
    this.error,
    this.diffText = '',
    this.noChanges = false,
    this.wouldBuild = const [],
  });

  final DateTime checkedAt;

  /// True when the eval (+ nvd diff, when reached) completed
  /// cleanly. False ⇒ the new lock would not even evaluate — see
  /// [error]. NOTE: a heavy check that bailed early because local
  /// builds would be needed still reports `ok: true` and populates
  /// [wouldBuild]; "needs compile" is not a failure mode.
  final bool ok;

  final String? error;

  /// `nvd diff` output. Empty when [noChanges] is true, [ok] is
  /// false, or [compileNeeded] is true (in which case the heavy
  /// check refused to compile derivations just to render a diff —
  /// the operator triggers the actual build via Apply).
  final String diffText;

  /// True when the new toplevel store path matched
  /// `/run/current-system` — the upstream pins moved but the resolved
  /// system didn't change.
  final bool noChanges;

  /// Derivation names (e.g. `rustc-1.87.0`, `cargo-foo-0.1.0`) that
  /// `nix build --dry-run` reported as "will be built" — i.e. not
  /// substitutable from any configured binary cache. Non-empty list
  /// means the heavy check skipped its own `nix build` step to
  /// avoid pinning the CPU for what's potentially a multi-hour
  /// compile; the operator decides whether to proceed via
  /// `nixos-rebuild switch` (System → Apply).
  ///
  /// Names are short ("derivation name", the part after the store
  /// hash) so a list of a few dozen still fits a sensible UI. The
  /// list is sorted alphabetically for stability across runs.
  final List<String> wouldBuild;

  /// True when [wouldBuild] is non-empty. Convenience for the UI
  /// gating logic so callers don't need to remember the
  /// "empty list = no compile" convention.
  bool get compileNeeded => wouldBuild.isNotEmpty;

  factory HeavyCheck.fromJson(Map<String, dynamic> j) => HeavyCheck(
    checkedAt: DateTime.parse(j['checked_at'] as String),
    ok: j['ok'] as bool? ?? true,
    error: j['error'] as String?,
    diffText: j['diff_text'] as String? ?? '',
    noChanges: j['no_changes'] as bool? ?? false,
    wouldBuild: (j['would_build'] as List?)?.cast<String>() ?? const <String>[],
  );

  Map<String, dynamic> toJson() => {
    'checked_at': checkedAt.toIso8601String(),
    'ok': ok,
    if (error != null) 'error': error,
    'diff_text': diffText,
    'no_changes': noChanges,
    if (wouldBuild.isNotEmpty) 'would_build': wouldBuild,
  };
}
