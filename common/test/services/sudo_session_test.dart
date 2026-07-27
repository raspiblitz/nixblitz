import 'dart:typed_data';

import 'package:common/src/services/sudo_session.dart';
import 'package:test/test.dart';

class _FakeAuth implements SudoAuthBackend {
  _FakeAuth({
    required this.silentExit,
    this.passwordExits = const [],
    this.silentDelay = Duration.zero,
  });

  /// Exit code returned by `sudo -n -v`.
  int silentExit;

  /// Per-attempt exit codes for `sudo -S -v`. Consumed in order;
  /// running off the end throws.
  List<int> passwordExits;

  /// Artificial latency for [silentVerify] — lets tests overlap
  /// concurrent ensureFresh calls deterministically.
  Duration silentDelay;

  int silentCalls = 0;
  int passwordCalls = 0;
  int forgetCalls = 0;
  final List<Uint8List> passwordsSeen = [];

  @override
  Future<int> silentVerify() async {
    silentCalls++;
    if (silentDelay > Duration.zero) {
      await Future<void>.delayed(silentDelay);
    }
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
    test('always re-verifies against sudo, even right after a success '
        '(a Dart-side freshness cache diverges from the kernel when the '
        'node invalidates the timestamp mid-session — seen live: the '
        'wizard journal popup got a stale "fresh" answer and every '
        'sudo -n died with "a password is required" without ever '
        'prompting)', () async {
      final auth = _FakeAuth(silentExit: 0);
      final s = SudoSession(authBackend: auth);
      expect(await s.ensureFresh(), isTrue);
      expect(auth.silentCalls, 1);

      // Immediately after: must consult sudo again, not a cache.
      expect(await s.ensureFresh(), isTrue);
      expect(auth.silentCalls, 2);
      expect(auth.passwordCalls, 0);
    });

    test(
      'stale success followed by OS-side invalidation prompts again',
      () async {
        final auth = _FakeAuth(silentExit: 0);
        final s = SudoSession(authBackend: auth);
        var prompts = 0;
        s.setPasswordCallback((_) async {
          prompts++;
          return _bytes('hunter2');
        });
        expect(await s.ensureFresh(), isTrue);
        expect(prompts, 0);

        // Timestamp dies behind our back (rebuild, sudo -K, timeout…).
        auth.silentExit = 1;
        auth.passwordExits = [0];
        expect(await s.ensureFresh(), isTrue);
        expect(prompts, 1);
      },
    );

    test('concurrent callers share one in-flight verification', () async {
      final auth = _FakeAuth(
        silentExit: 0,
        silentDelay: const Duration(milliseconds: 40),
      );
      final s = SudoSession(authBackend: auth);
      // Seed poll + journal popup both tick every 2s; unserialized
      // they race the single password-callback slot.
      final results = await Future.wait([s.ensureFresh(), s.ensureFresh()]);
      expect(results, [true, true]);
      expect(auth.silentCalls, 1);
    });

    test('concurrent callers share one password prompt', () async {
      final auth = _FakeAuth(
        silentExit: 1,
        passwordExits: [0],
        silentDelay: const Duration(milliseconds: 40),
      );
      final s = SudoSession(authBackend: auth);
      var prompts = 0;
      s.setPasswordCallback((_) async {
        prompts++;
        return _bytes('hunter2');
      });
      final results = await Future.wait([s.ensureFresh(), s.ensureFresh()]);
      expect(results, [true, true]);
      expect(prompts, 1);
      expect(auth.passwordCalls, 1);
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
