import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:common/common.dart';
import 'package:tui/src/dev/dev_app.dart';

const String version = '0.1.0-dev';

void main(List<String> arguments) {
  final homeDir = Platform.environment['HOME'] ?? '/root';
  LogService.init(homeDir);
  LogService.info('nixblitz_dev v$version started');

  NoctermError.onError = (details) {
    LogService.error(
      'Nocterm: ${details.context ?? "unknown context"}',
      details.exception,
      details.stack,
    );
  };

  runZonedGuarded(
    () {
      runApp(const DevApp());
    },
    (error, stackTrace) {
      LogService.error('Uncaught error', error, stackTrace);
    },
  );
}
