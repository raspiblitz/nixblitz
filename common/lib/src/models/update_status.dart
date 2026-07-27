/// Result of the periodic update checker, surfaced on the dashboard
/// as an "X updates available" banner.
///
/// One section: [CheckResult]. The section may be absent (file
/// missing on a fresh install) or stale (last timer run failed).
/// The dashboard renders defensively off `checkResult` when present.
library;

import 'dart:convert';
import 'dart:io';

import 'package:common/src/models/sbom_change.dart';

/// Attribute name of the flake input that pins the running TUI's
/// own source — matches `templates/flake.nix:13`. Spelled out once
/// here so consumers (System Check panel, dashboard banner) don't
/// drift if the input is ever renamed.
const String kTuiInputName = 'nixblitz';

/// Where the periodic checker writes its result. systemd-tmpfiles
/// creates the directory with admin:admin ownership; the
/// `nixblitz check` command runs as `admin` and writes here, the
/// TUI reads from it.
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

/// Delete the on-disk status. Called after a successful Apply — the
/// cached CheckResult describes a pre-apply delta, so leaving it would
/// keep the dashboard banner claiming stale pending updates. Returns
/// true when a file was actually removed; missing file is a no-op.
bool clearUpdateStatus({String? path}) {
  final f = File(path ?? updateStatusPath);
  if (!f.existsSync()) return false;
  f.deleteSync();
  return true;
}

class UpdateStatus {
  const UpdateStatus({this.checkResult});

  factory UpdateStatus.empty() => const UpdateStatus();

  final CheckResult? checkResult;

  factory UpdateStatus.fromJson(Map<String, dynamic> json) => UpdateStatus(
    checkResult: json['check_result'] is Map<String, dynamic>
        ? CheckResult.fromJson(json['check_result'] as Map<String, dynamic>)
        : null,
  );

  Map<String, dynamic> toJson() => {
    if (checkResult != null) 'check_result': checkResult!.toJson(),
  };

  UpdateStatus copyWith({CheckResult? checkResult}) =>
      UpdateStatus(checkResult: checkResult ?? this.checkResult);
}

/// Outcome of one `nixblitz check` run. Combines what used to be
/// the lightweight upstream-HEAD probe ([inputsAhead],
/// [pluginsAhead]) with the heavier eval + `nvd diff`
/// ([diffText], [noChanges], [wouldBuild]).
///
/// Side-effects of the check write to the staging dir
/// (`/var/lib/nixblitz-tui/staging/`); this object is the cached
/// summary the dashboard reads.
class CheckResult {
  const CheckResult({
    required this.checkedAt,
    required this.ok,
    this.error,
    this.inputsAhead = const [],
    this.pluginsAhead = const [],
    this.diffText = '',
    this.noChanges = false,
    this.wouldBuild = const [],
    this.sbomChanges = const [],
    this.transcript = const [],
    this.lockInputsMoved = const [],
  });

  final DateTime checkedAt;

  /// True when the run completed without a fatal error. A check that
  /// bailed early because local builds would be needed still reports
  /// `ok: true` and populates [wouldBuild] — "needs compile" is not
  /// a failure mode.
  final bool ok;

  final String? error;

  /// Inputs whose upstream tip has moved past the locally-locked
  /// commit. Empty list ⇒ nothing to update on the flake side.
  final List<InputAhead> inputsAhead;

  /// Installed plugins (auto_update=true, pinnedRev != null) whose
  /// upstream HEAD has moved. Empty list ⇒ no plugin updates.
  final List<PluginAhead> pluginsAhead;

  /// `nvd diff` output. Empty when [noChanges] is true, [ok] is
  /// false, or [compileNeeded] is true (the check refuses to compile
  /// derivations just to render a diff — the operator triggers the
  /// actual build via Apply).
  final String diffText;

  /// True when the new toplevel store path matched
  /// `/run/current-system` — upstream pins moved but the resolved
  /// system didn't change.
  final bool noChanges;

  /// Derivation names that `nix build --dry-run` reported as "will
  /// be built" — not substitutable from any configured binary cache.
  /// Non-empty list means the check skipped its own `nix build` step
  /// to avoid pinning the CPU for a potentially multi-hour compile.
  final List<String> wouldBuild;

  /// Package-version changes a candidate (updated) system would bring vs the
  /// committed `sbom.cdx.json`. Populated only on the substitutable check
  /// path; empty otherwise (and when there is no committed SBOM baseline).
  final List<SbomChange> sbomChanges;

  /// Bounded transcript of the check's own output — step headers plus
  /// each `nix`/`nvd` step's combined stdout+stderr, trimmed to the
  /// last ~200 lines of the whole run. Written on both success and
  /// failure so the TUI's log popup has something to show either way
  /// ("see the work it's doing"), not just on error. Empty when read
  /// from a status file written before this field existed.
  final List<String> transcript;

  /// Flake-input node names whose locked content actually moved in
  /// the candidate re-lock (semantic narHash diff, plugin inputs
  /// excluded). Drives the "NixBlitz" row on offline-installed nodes,
  /// where the rev probe cannot query the path-pinned nixblitz input
  /// and [inputsAhead] therefore stays empty even when an update was
  /// staged. Empty when nothing moved or the file predates the field.
  final List<String> lockInputsMoved;

  /// Convenience: true when [wouldBuild] is non-empty.
  bool get compileNeeded => wouldBuild.isNotEmpty;

  factory CheckResult.fromJson(Map<String, dynamic> j) => CheckResult(
    checkedAt: DateTime.parse(j['checked_at'] as String),
    ok: j['ok'] as bool? ?? true,
    error: j['error'] as String?,
    inputsAhead: ((j['inputs_ahead'] as List?) ?? const [])
        .map((e) => InputAhead.fromJson(e as Map<String, dynamic>))
        .toList(),
    pluginsAhead: ((j['plugins_ahead'] as List?) ?? const [])
        .map((e) => PluginAhead.fromJson(e as Map<String, dynamic>))
        .toList(),
    diffText: j['diff_text'] as String? ?? '',
    noChanges: j['no_changes'] as bool? ?? false,
    wouldBuild: (j['would_build'] as List?)?.cast<String>() ?? const <String>[],
    sbomChanges: ((j['sbom_changes'] as List?) ?? const [])
        .map((e) => SbomChange.fromJson(e as Map<String, dynamic>))
        .toList(),
    transcript: (j['transcript'] as List?)?.cast<String>() ?? const <String>[],
    lockInputsMoved:
        (j['lock_inputs_moved'] as List?)?.cast<String>() ?? const <String>[],
  );

  Map<String, dynamic> toJson() => {
    'checked_at': checkedAt.toIso8601String(),
    'ok': ok,
    if (error != null) 'error': error,
    if (inputsAhead.isNotEmpty)
      'inputs_ahead': inputsAhead.map((e) => e.toJson()).toList(),
    if (pluginsAhead.isNotEmpty)
      'plugins_ahead': pluginsAhead.map((e) => e.toJson()).toList(),
    'diff_text': diffText,
    'no_changes': noChanges,
    if (wouldBuild.isNotEmpty) 'would_build': wouldBuild,
    if (sbomChanges.isNotEmpty)
      'sbom_changes': sbomChanges.map((e) => e.toJson()).toList(),
    if (transcript.isNotEmpty) 'transcript': transcript,
    if (lockInputsMoved.isNotEmpty) 'lock_inputs_moved': lockInputsMoved,
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

/// Like [InputAhead] but for an installed plugin. The check probes
/// each `autoUpdate=true` plugin's upstream HEAD against the rev
/// recorded on its `PluginMarker` and emits one of these per plugin
/// that has moved.
///
/// Pinned plugins (`autoUpdate == false`) are intentionally skipped
/// — the operator opted out of automatic refreshes for them.
/// 7-char short rev for display; passes through anything already short.
String _shortRev(String rev) => rev.length > 7 ? rev.substring(0, 7) : rev;

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

  /// Manifest version recorded for the currently-installed rev. Null
  /// when the plugin's manifest had no `version` field — the
  /// operator's plugin tracks via SHA only.
  final String? currentVersion;

  /// Manifest version string at the new pin candidate.
  final String? upstreamVersion;

  /// True when the upstream version parses lower than the locally-
  /// pinned version (author cut a release, reverted, didn't re-bump).
  /// The check still emits a PluginAhead row so the operator sees
  /// the regression, but the dashboard renders it amber and refuses
  /// to auto-apply.
  final bool isDowngrade;

  /// True when the previously-pinned rev is no longer reachable on
  /// the upstream branch — the author force-pushed history. The
  /// check still proceeds; sign-key verification is the real
  /// security mechanism. Logged at WARN.
  final bool forcePushDetected;

  /// Operator-facing "from" label: the manifest version, or a short rev
  /// when the plugin tracks by SHA only (no `version` field).
  String get displayFrom => currentVersion ?? _shortRev(currentRev);

  /// Operator-facing "to" label — the new pin candidate.
  String get displayTo => upstreamVersion ?? _shortRev(upstreamRev);

  /// `from → to` for inline display on the Updates screen + details view.
  String get versionDelta => '$displayFrom → $displayTo';

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
