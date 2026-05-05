import 'package:nocterm/nocterm.dart';

/// Resolve a manifest color string to a concrete nocterm [Color].
///
/// Accepts:
/// - Semantic names: `ok`, `warn`, `error`, `accent`, `muted`, `default`.
/// - `#rrggbb` hex strings (case-insensitive).
/// - `null` → default theme color (current foreground).
///
/// Unknown inputs fall back to the default; we do not throw, because a
/// plugin author's typo should not crash the dashboard.
Color resolveTileColor(String? name, {required Color accent}) {
  if (name == null) return _defaultColor;
  if (name.startsWith('#')) {
    final parsed = parseHex(name);
    if (parsed != null) return parsed;
    return _defaultColor;
  }
  switch (name) {
    case 'ok':
      return _ok;
    case 'warn':
      return _warn;
    case 'error':
      return _error;
    case 'accent':
      return accent;
    case 'muted':
      return _muted;
    case 'default':
      return _defaultColor;
  }
  return _defaultColor;
}

/// Parses `#rrggbb`. Returns null if input is not a valid 6-digit hex.
Color? parseHex(String s) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(s)) return null;
  final n = int.parse(s.substring(1), radix: 16);
  return Color.fromRGB((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
}

const _ok = Color.fromRGB(0x4c, 0xaf, 0x50);
const _warn = Color.fromRGB(0xff, 0xa7, 0x26);
const _error = Color.fromRGB(0xef, 0x53, 0x50);
const _muted = Color.fromRGB(0x9e, 0x9e, 0x9e);
const _defaultColor = Color.fromRGB(0xee, 0xee, 0xee);
