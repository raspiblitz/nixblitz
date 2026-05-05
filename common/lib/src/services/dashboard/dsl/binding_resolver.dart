import 'package:common/src/services/log_service.dart';

const _placeholder = '—';
// Dedup by key only — tileId isn't threaded into resolveValue at this layer.
// Logs fire once per unique missing key name per process lifetime; the set is
// cleared on TUI restart.
final _missingKeyLogged = <String>{};

/// Resolve a manifest value (literal, directive map, or list of literals)
/// against the per-tile [data] map.
dynamic resolveValue(dynamic node, Map<String, dynamic> data) {
  if (node is Map &&
      node.length == 1 &&
      (node.keys.first as String).startsWith('\$')) {
    final directive = node.keys.first;
    final arg = node.values.first;
    return _evalDirective(directive, arg, data);
  }
  return node;
}

dynamic _evalDirective(
  String directive,
  dynamic arg,
  Map<String, dynamic> data,
) {
  try {
    switch (directive) {
      case '\$data':
        return _lookup(arg as String, data) ?? _placeholder;
      case '\$bytes':
        final v = _lookup(arg as String, data);
        if (v is num) return formatBytes(v.toInt());
        return _placeholder;
      case '\$duration':
        final v = _lookup(arg as String, data);
        if (v is num) return formatDuration(v.toInt());
        return _placeholder;
      case '\$pct':
        final v = _lookup(arg as String, data);
        if (v is num) {
          // Two decimal places to preserve sub-percent precision (0.99987 → 99.99%).
          return '${(v * 100).toStringAsFixed(2)}%';
        }
        return _placeholder;
      case '\$truncate':
        final spec = (arg as Map).cast<String, dynamic>();
        final s = _lookup(spec['key'] as String, data)?.toString();
        final len = (spec['len'] as num).toInt();
        if (s == null) return _placeholder;
        return s.length <= len ? s : '${s.substring(0, len - 1)}…';
      case '\$format':
        return _interpolate(arg as String, data);
      case '\$status':
        final spec = (arg as Map).cast<String, dynamic>();
        final on = spec['\$on'] as String;
        final v = _lookup(on, data)?.toString();
        if (v == null) return null;
        return spec[v];
      default:
        return _placeholder;
    }
  } catch (e) {
    LogService.warn('TileBinding: malformed directive \$$directive: $e');
    return _placeholder;
  }
}

dynamic _lookup(String key, Map<String, dynamic> data) {
  if (data.containsKey(key)) return data[key];
  if (_missingKeyLogged.add(key)) {
    LogService.warn('TileBinding: missing key "$key"');
  }
  return null;
}

String _interpolate(String template, Map<String, dynamic> data) {
  return template.replaceAllMapped(RegExp(r'\{([a-zA-Z0-9_]+)\}'), (m) {
    final key = m.group(1)!;
    final v = _lookup(key, data);
    return v?.toString() ?? _placeholder;
  });
}

/// Human-readable bytes (1000-base, network conventions): "5.4 GB" not "5.0 GiB".
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1000.0;
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}

/// Human-readable seconds → "1d 2h 3m" / "5m" / "0m" (sub-minute → "0m").
String formatDuration(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h ${m}m';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
