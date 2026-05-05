import 'package:common/src/services/dashboard/dsl/binding_resolver.dart';
import 'package:nocterm/nocterm.dart';

class DashboardChrome extends StatelessComponent {
  final String hostname;
  final String platform;
  final String network;
  final int? uptimeSec;
  final Duration? appliedAgo;

  const DashboardChrome({
    required this.hostname,
    required this.platform,
    required this.network,
    this.uptimeSec,
    this.appliedAgo,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final l1 = '$hostname  ·  $platform  ·  $network';
    final parts = <String>[];
    if (uptimeSec != null) parts.add('uptime ${formatDuration(uptimeSec!)}');
    if (appliedAgo != null)
      parts.add('applied ${_appliedAgoLabel(appliedAgo!)} ago');
    final l2 = parts.join('  ·  ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Text(l1), if (l2.isNotEmpty) Text(l2)],
    );
  }
}

String _appliedAgoLabel(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d';
  if (d.inHours > 0) return '${d.inHours}h';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '<1m';
}

/// Test helper.
String renderChromeText({
  required String hostname,
  required String platform,
  required String network,
  required int? uptimeSec,
  required Duration? appliedAgo,
}) {
  final l1 = '$hostname  ·  $platform  ·  $network';
  final parts = <String>[];
  if (uptimeSec != null) parts.add('uptime ${formatDuration(uptimeSec)}');
  if (appliedAgo != null)
    parts.add('applied ${_appliedAgoLabel(appliedAgo)} ago');
  final l2 = parts.join('  ·  ');
  return '$l1\n$l2';
}
