import 'package:test/test.dart';
import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/system_service.dart';

void main() {
  group('SystemService', () {
    test('parseServiceStatus parses active running', () {
      const output = 'ActiveState=active\nSubState=running\n';
      final status = SystemService.parseServiceStatus('bitcoind', output);
      expect(status.name, 'bitcoind');
      expect(status.state, ServiceState.running);
    });

    test('parseServiceStatus parses inactive dead', () {
      const output = 'ActiveState=inactive\nSubState=dead\n';
      final status = SystemService.parseServiceStatus('lnd', output);
      expect(status.name, 'lnd');
      expect(status.state, ServiceState.stopped);
    });

    test('parseServiceStatus parses failed', () {
      const output = 'ActiveState=failed\nSubState=failed\n';
      final status = SystemService.parseServiceStatus('cln', output);
      expect(status.name, 'cln');
      expect(status.state, ServiceState.failed);
    });

    test('parseServiceStatus handles activating', () {
      const output = 'ActiveState=activating\nSubState=start\n';
      final status = SystemService.parseServiceStatus('bitcoind', output);
      expect(status.state, ServiceState.activating);
    });
  });
}
