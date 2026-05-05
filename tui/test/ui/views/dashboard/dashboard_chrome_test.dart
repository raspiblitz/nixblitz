import 'package:test/test.dart';
import 'package:tui/src/ui/views/dashboard/dashboard_chrome.dart';

void main() {
  group('renderChromeText', () {
    test('first line shows hostname · platform · network', () {
      final out = renderChromeText(
        hostname: 'nixblitz-pi5',
        platform: 'raspi5',
        network: 'mainnet',
        uptimeSec: null,
        appliedAgo: null,
      );
      expect(out, contains('nixblitz-pi5'));
      expect(out, contains('raspi5'));
      expect(out, contains('mainnet'));
    });

    test('second line shows uptime + applied when available', () {
      final out = renderChromeText(
        hostname: 'h',
        platform: 'p',
        network: 'main',
        uptimeSec: 3700,
        appliedAgo: const Duration(hours: 2),
      );
      expect(out, contains('uptime 1h 1m'));
      expect(out, contains('applied 2h ago'));
    });

    test('falls back gracefully when secondary info missing', () {
      final out = renderChromeText(
        hostname: 'h',
        platform: 'p',
        network: 'main',
        uptimeSec: null,
        appliedAgo: null,
      );
      // First line present.
      expect(out.split('\n').first, contains('h'));
      expect(out.split('\n').first, contains('main'));
    });

    test('appliedAgo formatting: minutes / hours / days', () {
      String out(Duration d) => renderChromeText(
        hostname: 'h',
        platform: 'p',
        network: 'main',
        uptimeSec: 0,
        appliedAgo: d,
      );
      expect(out(const Duration(minutes: 30)), contains('applied 30m ago'));
      expect(out(const Duration(hours: 5)), contains('applied 5h ago'));
      expect(out(const Duration(days: 3)), contains('applied 3d ago'));
      expect(out(const Duration(seconds: 30)), contains('applied <1m ago'));
    });
  });
}
