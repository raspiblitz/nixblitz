import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:common/src/services/log_service.dart';

/// Returns the password as a [Uint8List], or null if the user
/// cancelled the prompt. The caller (SudoSession) takes ownership
/// of the buffer and zeroes it after use.
typedef PasswordPromptCallback = Future<Uint8List?> Function(String reason);

/// Pluggable backend for the privileged sudo invocations needed
/// by [SudoSession]'s auth state machine. Tests inject a fake.
abstract class SudoAuthBackend {
  /// Runs `sudo -n -v`. Returns the exit code. 0 = timestamp valid.
  Future<int> silentVerify();

  /// Runs `sudo -S -v`, writing [password]+`\n` to stdin. Returns
  /// the exit code. 0 = authenticated; non-zero = bad password.
  Future<int> passwordVerify(Uint8List password);

  /// Runs `sudo -K`. Returns the exit code (we don't actually care).
  Future<int> forget();
}

class _DefaultSudoAuthBackend implements SudoAuthBackend {
  @override
  Future<int> silentVerify() async {
    final r = await Process.run('sudo', ['-n', '-v']);
    return r.exitCode;
  }

  @override
  Future<int> passwordVerify(Uint8List password) async {
    final p = await Process.start('sudo', ['-S', '-v']);
    p.stdin.add(password);
    p.stdin.add(const [0x0A]);
    await p.stdin.close();
    return p.exitCode;
  }

  @override
  Future<int> forget() async {
    final r = await Process.run('sudo', ['-K']);
    return r.exitCode;
  }
}

/// Manages sudo authentication so the TUI can run privileged
/// commands non-interactively after a single password prompt
/// per session of activity.
///
/// Lifecycle (see docs/decisions/plugins.md sudo posture):
///   1. TUI startup registers a [PasswordPromptCallback] that
///      pops a modal overlay over the active view.
///   2. Before any privileged flow, callers `await ensureFresh()`.
///      Returns true if sudo's timestamp is valid (silent path)
///      or the user typed the right password (prompted path).
///      Returns false if the user cancelled the modal or all 3
///      retries failed.
///   3. Privileged flows use [runOneShot] / [runStreaming], which
///      prepend `-n` and rely on the cached timestamp.
///   4. A keepalive [Timer] runs `sudo -n -v` every ~10 min while
///      the TUI is open, refreshing the timestamp without ever
///      prompting.
///   5. On TUI shutdown, [forget] runs `sudo -K`.
class SudoSession {
  SudoSession({
    SudoAuthBackend? authBackend,
    Duration freshThreshold = const Duration(minutes: 4),
    // Must stay strictly less than the operator's sudo grace
    // window (default 5 min in stock sudoers) — once the
    // timestamp lapses, `sudo -n -v` fails silently and won't
    // refresh it, so any subsequent `sudo -n <cmd>` falls into
    // the password-required path. 3 min keeps the keepalive
    // comfortably inside the default grace; deployments that run
    // a tighter `timestamp_timeout` should pass an explicit
    // override.
    Duration keepaliveInterval = const Duration(minutes: 3),
  }) : _auth = authBackend ?? _DefaultSudoAuthBackend(),
       _freshThreshold = freshThreshold,
       _keepaliveInterval = keepaliveInterval;

  final SudoAuthBackend _auth;
  final Duration _freshThreshold;
  final Duration _keepaliveInterval;

  PasswordPromptCallback? _passwordCallback;
  DateTime? _lastAuthAt;
  Timer? _keepaliveTimer;

  void setPasswordCallback(PasswordPromptCallback cb) {
    _passwordCallback = cb;
  }

  /// True if a successful auth happened within [_freshThreshold].
  /// Used by tests + the keepalive timer to short-circuit.
  bool get isFresh =>
      _lastAuthAt != null &&
      DateTime.now().difference(_lastAuthAt!) < _freshThreshold;

  /// Ensures sudo's timestamp is fresh enough for a `-n` invocation.
  ///
  /// Tries three paths in order:
  ///   1. Cached timestamp younger than [_freshThreshold] → no-op.
  ///   2. `sudo -n -v` succeeds silently → cache the timestamp.
  ///   3. Prompt for password (up to 3 attempts) and run `sudo -S -v`.
  ///
  /// Returns false if the user cancels the prompt or 3 wrong
  /// attempts in a row exhaust the retry budget. Caller is
  /// responsible for surfacing that to the user as "operation
  /// cancelled" / "authentication failed".
  Future<bool> ensureFresh() async {
    if (isFresh) return true;

    final silentExit = await _auth.silentVerify();
    if (silentExit == 0) {
      _lastAuthAt = DateTime.now();
      startKeepalive();
      return true;
    }

    final cb = _passwordCallback;
    if (cb == null) {
      LogService.error(
        'SudoSession.ensureFresh: silent verify failed and no '
        'password callback registered',
      );
      return false;
    }

    for (var attempt = 1; attempt <= 3; attempt++) {
      final reason = attempt == 1
          ? 'Authorize sudo'
          : 'Authorize sudo (attempt $attempt of 3)';
      final pw = await cb(reason);
      if (pw == null) {
        // User cancelled the modal.
        LogService.info('SudoSession.ensureFresh: user cancelled prompt');
        return false;
      }
      try {
        final exit = await _auth.passwordVerify(pw);
        if (exit == 0) {
          _lastAuthAt = DateTime.now();
          startKeepalive();
          return true;
        }
        LogService.warn(
          'SudoSession.ensureFresh: auth attempt $attempt failed '
          '(exit=$exit)',
        );
      } finally {
        // Best-effort zeroize. Dart's GC may have already moved the
        // page, but this still defeats casual memory inspection.
        pw.fillRange(0, pw.length, 0);
      }
    }
    LogService.error('SudoSession.ensureFresh: all 3 password attempts failed');
    return false;
  }

  /// Invalidates the cached timestamp + runs `sudo -K`. Called
  /// on TUI shutdown so a stolen session can't pick up where the
  /// user left off. Idempotent.
  Future<void> forget() async {
    _lastAuthAt = null;
    stopKeepalive();
    try {
      await _auth.forget();
    } catch (e) {
      LogService.warn('SudoSession.forget: sudo -K failed: $e');
    }
  }

  /// Starts a background timer that refreshes the timestamp
  /// silently every [_keepaliveInterval] while the TUI is open.
  /// No-op if already running. Never prompts — if the silent
  /// refresh fails, the next `ensureFresh()` will pick up the
  /// expired timestamp and prompt.
  void startKeepalive() {
    if (_keepaliveTimer != null) return;
    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (_) async {
      try {
        final exit = await _auth.silentVerify();
        if (exit == 0) {
          _lastAuthAt = DateTime.now();
        } else {
          LogService.info(
            'SudoSession keepalive: silent verify exit=$exit '
            '(timestamp expired; next ensureFresh will prompt)',
          );
        }
      } catch (e) {
        LogService.warn('SudoSession keepalive: $e');
      }
    });
  }

  void stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  /// Buffered privileged invocation. Caller must `await ensureFresh()`
  /// first. Adds `-n` to sudo's args so a missing timestamp fails
  /// fast instead of hanging on stdin.
  ///
  /// Optional [stdinBytes] is written once and the stream closed —
  /// used by `chpasswd` ("admin:newpw\n") and similar.
  Future<({int exitCode, String stdout, String stderr})> runOneShot(
    List<String> args, {
    Duration timeout = const Duration(seconds: 30),
    Uint8List? stdinBytes,
  }) async {
    Process proc;
    try {
      proc = await Process.start('sudo', ['-n', ...args]);
    } catch (e, st) {
      LogService.error('SudoSession.runOneShot: spawn failed', e, st);
      return (exitCode: 127, stdout: '', stderr: 'spawn failed: $e');
    }

    if (stdinBytes != null) {
      proc.stdin.add(stdinBytes);
    }
    await proc.stdin.close();

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    proc.stdout
        .transform(const SystemEncoding().decoder)
        .listen(
          stdoutBuf.write,
          onDone: () => stdoutDone.isCompleted ? null : stdoutDone.complete(),
          cancelOnError: true,
        );
    proc.stderr
        .transform(const SystemEncoding().decoder)
        .listen(
          stderrBuf.write,
          onDone: () => stderrDone.isCompleted ? null : stderrDone.complete(),
          cancelOnError: true,
        );

    var timedOut = false;
    final termTimer = Timer(timeout, () {
      timedOut = true;
      proc.kill(ProcessSignal.sigterm);
    });

    final actual = await proc.exitCode;
    await stdoutDone.future;
    await stderrDone.future;
    termTimer.cancel();

    return (
      exitCode: timedOut ? 124 : actual,
      stdout: stdoutBuf.toString(),
      stderr: stderrBuf.toString(),
    );
  }

  /// Streaming privileged invocation. Caller must `await ensureFresh()`
  /// first. Returns the same record shape that `SystemService.rebuild`
  /// uses (output stream + exit-code future), so the existing
  /// ScrollableLog rendering works unchanged.
  ({Stream<String> output, Future<int> exitCode}) runStreaming(
    List<String> args,
  ) {
    final controller = StreamController<String>();

    final exitCodeFuture = () async {
      Process proc;
      try {
        proc = await Process.start('sudo', ['-n', ...args]);
      } catch (e, st) {
        LogService.error('SudoSession.runStreaming: spawn failed', e, st);
        controller.add('failed to spawn: $e\n');
        await controller.close();
        return 127;
      }

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      proc.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => controller.add('$line\n'),
            onDone: () => stdoutDone.isCompleted ? null : stdoutDone.complete(),
            cancelOnError: true,
          );
      proc.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => controller.add('$line\n'),
            onDone: () => stderrDone.isCompleted ? null : stderrDone.complete(),
            cancelOnError: true,
          );

      final code = await proc.exitCode;
      await stdoutDone.future;
      await stderrDone.future;
      await controller.close();
      return code;
    }();

    return (output: controller.stream, exitCode: exitCodeFuture);
  }
}
