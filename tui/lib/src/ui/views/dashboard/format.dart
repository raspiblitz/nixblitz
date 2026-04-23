/// Small formatters shared by dashboard tiles.
library;

String humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  double v = bytes / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[u]}';
}

String humanDuration(Duration d) {
  final days = d.inDays;
  final hours = d.inHours.remainder(24);
  final minutes = d.inMinutes.remainder(60);
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}

String humanPercent(double frac) => '${(frac * 100).toStringAsFixed(0)}%';

/// Group digits in a sats integer: 1234567 → "1_234_567". Underscores
/// are BIP-style; easy to eye-parse in a narrow column.
String humanSats(int sats) {
  final s = sats.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('_');
    buf.write(s[i]);
  }
  return buf.toString();
}
