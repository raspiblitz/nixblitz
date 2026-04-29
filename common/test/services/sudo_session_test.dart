import 'dart:typed_data';

import 'package:common/src/services/sudo_session.dart';
import 'package:test/test.dart';

class _FakeAuth implements SudoAuthBackend {
  _FakeAuth({required this.silentExit, this.passwordExits = const []});

  /// Exit code returned by `sudo -n -v`.
  int silentExit;

  /// Per-attempt exit codes for `sudo -S -v`. Consumed in order;
  /// running off the end throws.
  List<int> passwordExits;

  int silentCalls = 0;
  int passwordCalls = 0;
  int forgetCalls = 0;
  final List<Uint8List> passwordsSeen = [];

  @override
  Future<int> silentVerify() async {
    silentCalls++;
    return silentExit;
  }

  @override
  Future<int> passwordVerify(Uint8List password) async {
    passwordCalls++;
    // Snapshot before SudoSession zeroes the buffer.
    passwordsSeen.add(Uint8List.fromList(password));
    if (passwordCalls > passwordExits.length) {
      throw StateError(
        'fake passwordVerify called $passwordCalls times but only '
        '${passwordExits.length} exit codes were queued',
      );
    }
    return passwordExits[passwordCalls - 1];
  }

  @override
  Future<int> forget() async {
    forgetCalls++;
    return 0;
  }
}

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('SudoSession.ensureFresh', () {
    test('cached timestamp short-circuits silently', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(authBackend: auth);
      // Prime the cache with a successful verify.
      expect(await s.ensureFresh(), isTrue);
      expect(auth.silentCalls, 1);

      // Second call within freshThreshold must not touch the backend.
      expect(await s.ensureFresh(), isTrue);
      expect(auth.silentCalls, 1);
      expect(auth.passwordCalls, 0);
    });

    test('silent verify success caches timestamp', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(authBackend: auth);
      expect(await s.ensureFresh(), isTrue);
      expect(s.isFresh, isTrue);
      expect(auth.passwordCalls, 0);
    });

    test('silent verify fail + no callback returns false', () async {
      final auth = _FakeAuth(silentExit: 1);
      final s = SudoSession(authBackend: auth);
      expect(await s.ensureFresh(), isFalse);
      expect(auth.passwordCalls, 0);
    });

    test('silent fail + user cancels modal returns false', () async {
      final auth = _FakeAuth(silentExit: 1);
      final s = SudoSession(authBackend: auth);
      var prompts = 0;
      s.setPasswordCallback((_) async {
        prompts++;
        return null; // cancel
      });
      expect(await s.ensureFresh(), isFalse);
      expect(prompts, 1);
      expect(auth.passwordCalls, 0);
    });

    test('silent fail + correct password caches timestamp', () async {
      final auth = _FakeAuth(silentExit: 1, passwordExits: [0]);
      final s = SudoSession(authBackend: auth);
      s.setPasswordCallback((_) async => _bytes('hunter2'));
      expect(await s.ensureFresh(), isTrue);
      expect(auth.passwordCalls, 1);
      expect(s.isFresh, isTrue);
    });

    test('wrong password retries up to 3 times then fails', () async {
      final auth = _FakeAuth(silentExit: 1, passwordExits: [1, 1, 1]);
      final s = SudoSession(authBackend: auth);
      var prompts = 0;
      s.setPasswordCallback((_) async {
        prompts++;
        return _bytes('wrong');
      });
      expect(await s.ensureFresh(), isFalse);
      expect(prompts, 3);
      expect(auth.passwordCalls, 3);
    });

    test('wrong then correct succeeds within retry budget', () async {
      final auth = _FakeAuth(silentExit: 1, passwordExits: [1, 0]);
      final s = SudoSession(authBackend: auth);
      var prompts = 0;
      s.setPasswordCallback((_) async {
        prompts++;
        return _bytes(prompts == 1 ? 'wrong' : 'right');
      });
      expect(await s.ensureFresh(), isTrue);
      expect(auth.passwordCalls, 2);
      expect(s.isFresh, isTrue);
    });

    test('zeroes the password buffer after use', () async {
      final auth = _FakeAuth(silentExit: 1, passwordExits: [0]);
      final s = SudoSession(authBackend: auth);
      late Uint8List captured;
      s.setPasswordCallback((_) async {
        captured = _bytes('hunter2');
        return captured;
      });
      expect(await s.ensureFresh(), isTrue);
      // The buffer SudoSession received was zeroed in-place;
      // since we kept a reference to the same buffer, it's zeros.
      expect(captured, everyElement(equals(0)));
    });
  });

  group('SudoSession.forget', () {
    test('clears cache and calls sudo -K', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(authBackend: auth);
      expect(await s.ensureFresh(), isTrue);
      expect(s.isFresh, isTrue);

      await s.forget();
      expect(s.isFresh, isFalse);
      expect(auth.forgetCalls, 1);
    });

    test('is idempotent', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(authBackend: auth);
      await s.forget();
      await s.forget();
      expect(auth.forgetCalls, 2);
      expect(s.isFresh, isFalse);
    });
  });

  group('SudoSession freshness threshold', () {
    test('expires after freshThreshold and re-verifies silently', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(
        authBackend: auth,
        freshThreshold: const Duration(milliseconds: 50),
      );
      expect(await s.ensureFresh(), isTrue);
      expect(auth.silentCalls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(await s.ensureFresh(), isTrue);
      // Cache expired → silent verify ran a second time.
      expect(auth.silentCalls, 2);
    });
  });

  group('SudoSession keepalive', () {
    test('refreshes timestamp on the configured interval', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(
        authBackend: auth,
        keepaliveInterval: const Duration(milliseconds: 30),
      );
      s.startKeepalive();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      s.stopKeepalive();
      // Should have fired at least twice (~30ms each over 100ms).
      expect(auth.silentCalls, greaterThanOrEqualTo(2));
    });

    test('startKeepalive is idempotent', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(
        authBackend: auth,
        keepaliveInterval: const Duration(milliseconds: 30),
      );
      s.startKeepalive();
      s.startKeepalive(); // second call must not double-schedule
      await Future<void>.delayed(const Duration(milliseconds: 100));
      s.stopKeepalive();
      // Two timers would fire ~6 times; one timer ~3 times.
      expect(auth.silentCalls, lessThan(6));
    });

    test('failing silent verify in keepalive does not prompt', () async {
      final auth = _FakeAuth(silentExit: 1);
      final s = SudoSession(
        authBackend: auth,
        keepaliveInterval: const Duration(milliseconds: 30),
      );
      var prompts = 0;
      s.setPasswordCallback((_) async {
        prompts++;
        return null;
      });
      s.startKeepalive();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      s.stopKeepalive();
      expect(prompts, 0);
      expect(auth.passwordCalls, 0);
    });
  });
}
