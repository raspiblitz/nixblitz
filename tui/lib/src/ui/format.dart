/// Render a UTC-rooted relative-time string ("just now" / "5m ago" /
/// "3h ago" / "2d ago") for in-TUI captions. Unit boundaries are
/// chosen so the result fits naturally into a one-line banner —
/// minutes up to an hour, hours up to a day, days otherwise. The
/// caller is responsible for handling future timestamps if any.
String humanizeAge(DateTime t) {
  final diff = DateTime.now().toUtc().difference(t.toUtc());
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
