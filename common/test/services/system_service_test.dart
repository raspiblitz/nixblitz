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

  group('SystemService.parseToplevel', () {
    test('extracts a clean single-line store path', () {
      const out = '/nix/store/abc123def456-nixos-system-nixblitz-25.11';
      expect(SystemService.parseToplevel(out), out);
    });

    test('strips trailing newline', () {
      const out =
          '/nix/store/abc123def456-nixos-system-nixblitz-25.11\n';
      expect(
        SystemService.parseToplevel(out),
        '/nix/store/abc123def456-nixos-system-nixblitz-25.11',
      );
    });

    test('finds path embedded in noisy multi-line output', () {
      const out =
          'evaluating flake...\n'
          '/nix/store/xyz789-nixos-system-nixblitz-25.11\n'
          'done.\n';
      expect(
        SystemService.parseToplevel(out),
        '/nix/store/xyz789-nixos-system-nixblitz-25.11',
      );
    });

    test('returns null on output without a store path', () {
      expect(SystemService.parseToplevel('error: eval failed'), isNull);
      expect(SystemService.parseToplevel(''), isNull);
    });
  });
}
