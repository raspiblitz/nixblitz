import 'dart:convert';

import 'package:common/src/models/update_status.dart';

/// Result of [UpdateCheckService.probeUpstreamMovement]. Bundles the
/// inputs-ahead and plugins-ahead lists plus any per-entry errors
/// the probe collected (one bad URL doesn't sink the whole walk).
class UpstreamProbeResult {
  const UpstreamProbeResult({
    required this.inputsAhead,
    required this.pluginsAhead,
    required this.errors,
  });
  final List<InputAhead> inputsAhead;
  final List<PluginAhead> pluginsAhead;
  final List<String> errors;
}

/// Result of parsing `nix build --dry-run` stderr. Both lists hold
/// short derivation names ("the readable part" of
/// `/nix/store/HASH-NAME.drv` — e.g. `rustc-1.87.0`) so the UI can
/// show a compact summary without dragging store hashes around.
/// Lists are alphabetically sorted for stability.
class NixBuildPlan {
  const NixBuildPlan({required this.wouldBuild, required this.wouldFetch});

  /// Paths that would be compiled locally (cache miss / non-
  /// substitutable). Non-empty list = "huge update incoming."
  final List<String> wouldBuild;

  /// Paths that would be downloaded from a binary cache. Surfaced
  /// for completeness; not currently used by the TUI gating logic.
  final List<String> wouldFetch;
}

/// Parse the stderr output of `nix build --dry-run` into a
/// [NixBuildPlan]. Nix prints two stanzas when there's work to do:
///
/// ```
/// these 3 derivations will be built:
///   /nix/store/abc-rustc-1.87.0.drv
///   ...
/// these 12 paths will be fetched (456 MB):
///   /nix/store/xyz-foo.drv
///   ...
/// ```
///
/// Either stanza may be absent (or both — `noChanges`). Parsing is
/// lenient: unknown lines are ignored, and we only key off the
/// leading whitespace + `/nix/store/` marker for the path lines.
/// Singular `derivation` / `path` variants are accepted.
NixBuildPlan parseDryRunStderr(String stderr) {
  final lines = const LineSplitter().convert(stderr);
  final built = <String>[];
  final fetched = <String>[];
  // 0 = looking for a header; 1 = inside builds; 2 = inside fetches.
  var section = 0;
  for (final raw in lines) {
    final line = raw.trimRight();
    final t = line.trimLeft();
    // Stanza headers — match both "this/these N derivation(s) will
    // be built:" and the fetch counterpart.
    final builtRe = RegExp(
      r'^(?:this|these).*derivations? will be built:',
      caseSensitive: false,
    );
    final fetchRe = RegExp(
      r'^(?:this|these).*paths? will be fetched',
      caseSensitive: false,
    );
    if (builtRe.hasMatch(t)) {
      section = 1;
      continue;
    }
    if (fetchRe.hasMatch(t)) {
      section = 2;
      continue;
    }
    // Path lines: indented + start with /nix/store/. A blank line
    // or any other unindented line ends the current section.
    if (section != 0 && t.startsWith('/nix/store/')) {
      final name = _derivationShortName(t);
      if (section == 1) {
        built.add(name);
      } else {
        fetched.add(name);
      }
    } else if (line.isEmpty || !line.startsWith(' ')) {
      section = 0;
    }
  }
  built.sort();
  fetched.sort();
  return NixBuildPlan(wouldBuild: built, wouldFetch: fetched);
}

/// Strip `/nix/store/<hash>-` prefix and the trailing `.drv` from a
/// store path so the UI shows `rustc-1.87.0` instead of
/// `/nix/store/abc123…-rustc-1.87.0.drv`. Returns the input
/// unchanged when the shape doesn't match — defensive against
/// hypothetical future Nix output changes.
String _derivationShortName(String storePath) {
  final m = RegExp(r'^/nix/store/[^-]+-(.+)$').firstMatch(storePath);
  if (m == null) return storePath;
  var name = m.group(1)!;
  if (name.endsWith('.drv')) {
    name = name.substring(0, name.length - 4);
  }
  return name;
}

/// A root flake input declared as `inputs.X.follows = "Y/Z"` —
/// shares another input's lock, so there's no separate upstream
/// pin to probe. Surfaced for display only; consumers who do HEAD
/// probes (the check service) iterate [UpdateCheckService.parseRootInputs]
/// not this list.
class FollowsInput {
  const FollowsInput({required this.name, required this.target});
  final String name;
  final String target;
}

/// Record of a flake input we know how to query upstream against.
/// Returned by [UpdateCheckService.parseRootInputs].
class LockedInput {
  const LockedInput({
    required this.name,
    required this.type,
    required this.owner,
    required this.repo,
    required this.host,
    required this.ref,
    required this.lockedRev,
    required this.urlForDisplay,
  });

  final String name;
  final String type; // 'github' | 'git'
  final String owner;
  final String repo;
  final String? host; // populated for 'git' type
  final String? ref;
  final String lockedRev;
  final String urlForDisplay;
}
