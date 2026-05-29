import 'dart:io';

import 'package:common/src/models/plugin/app_version_command.dart';
import 'package:common/src/services/plugin/plugin_app_version_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('app-version-test-');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Write `<tmp>/plugins/<id>/app-version.sh` with [body].
  void writeScript(String id, String body) {
    final dir = Directory('${tmp.path}/plugins/$id')
      ..createSync(recursive: true);
    File(
      '${dir.path}/app-version.sh',
    ).writeAsStringSync('#!/usr/bin/env bash\n$body\n');
  }

  final cmd = AppVersionCommand(command: 'bash', args: ['app-version.sh']);

  test('returns the trimmed stdout on success', () async {
    writeScript('p', 'echo "Bitcoin Core 27.0"');
    final v = await readPluginAppVersion(
      baseDir: tmp.path,
      pluginId: 'p',
      cmd: cmd,
    );
    expect(v, 'Bitcoin Core 27.0');
  });

  test('takes the first non-empty line', () async {
    writeScript('p', 'echo ""; echo ""; echo "tailscale 1.2.3"; echo "extra"');
    final v = await readPluginAppVersion(
      baseDir: tmp.path,
      pluginId: 'p',
      cmd: cmd,
    );
    expect(v, 'tailscale 1.2.3');
  });

  test('returns null on non-zero exit', () async {
    writeScript('p', 'echo "x"; exit 1');
    final v = await readPluginAppVersion(
      baseDir: tmp.path,
      pluginId: 'p',
      cmd: cmd,
    );
    expect(v, isNull);
  });

  test('returns null on empty output', () async {
    writeScript('p', 'true');
    final v = await readPluginAppVersion(
      baseDir: tmp.path,
      pluginId: 'p',
      cmd: cmd,
    );
    expect(v, isNull);
  });

  test('returns null when the command does not exist', () async {
    Directory('${tmp.path}/plugins/p').createSync(recursive: true);
    final v = await readPluginAppVersion(
      baseDir: tmp.path,
      pluginId: 'p',
      cmd: AppVersionCommand(command: 'definitely-not-a-real-binary-xyz'),
    );
    expect(v, isNull);
  });

  test('returns null on timeout (slow command is killed)', () async {
    writeScript('p', 'sleep 5; echo "late"');
    final v = await readPluginAppVersion(
      baseDir: tmp.path,
      pluginId: 'p',
      cmd: cmd,
      timeout: const Duration(milliseconds: 200),
    );
    expect(v, isNull);
  });
}
