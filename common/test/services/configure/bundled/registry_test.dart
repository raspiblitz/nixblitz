import 'package:common/src/services/configure/bundled/registry.dart';
import 'package:test/test.dart';

void main() {
  group('bundledAppManifests', () {
    test('is empty after bitcoind/lnd/cln were extracted to plugins', () {
      // bitcoind, lnd, cln, blitz_api, blitz_web all live as plugins
      // (nixblitz_official_plugins/{bitcoind,lnd,cln,blitz-api,blitz-web}).
      // Nothing ships as a built-in app any more.
      expect(bundledAppManifests, isEmpty);
    });
  });
}
