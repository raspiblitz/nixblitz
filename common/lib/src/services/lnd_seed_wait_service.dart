import 'dart:io';

import 'package:common/src/models/service_status.dart';
import 'package:common/src/services/log_service.dart';
import 'package:common/src/services/system_service.dart' show SystemService;

typedef SudoResult = ({int exitCode, String stdout, String stderr});

/// Which checklist row is currently in progress. Failure is NOT a phase:
/// on failure [SeedWaitStatus.error] is set while [SeedWaitStatus.phase]
/// keeps pointing at the row that failed, so the UI can mark that row ✗.
enum SeedWaitPhase { startingService, waitingForSeedFile, readingSeed, done }

class SeedWaitStatus {
  final SeedWaitPhase phase;
  final ServiceState lndState;
  final String? error;

  /// Present only when [phase] == done. The caller (setup view) moves
  /// these into its own instance state and drops this object — the
  /// service never retains them (see below).
  final List<String>? seedWords;

  const SeedWaitStatus({
    required this.phase,
    this.lndState = ServiceState.unknown,
    this.error,
    this.seedWords,
  });

  bool get isTerminal => phase == SeedWaitPhase.done || error != null;
}

/// One short-lived poll pass per call — composed by the setup view's
/// existing 2 s timer. Guarantees:
///
///  1. No sudo subprocess runs while the lnd unit is not active
///     (the unprivileged `systemctl show` gate comes first).
///  2. The first poll after the unit turns active is announce-only:
///     it returns without touching sudo, giving the UI a full tick to
///     render the "will ask for sudo" warning before the prompt can
///     appear.
///
/// Stateful only in `_sudoAnnounced`; the seed itself is returned, not
/// retained.
class LndSeedWaitService {
  LndSeedWaitService({
    required this.ensureSudoFresh,
    required this.runSudo,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
    this.seedPath = '/mnt/data/lnd/lnd-seed-mnemonic',
    this.unit = 'lnd',
  }) : _runProcess = runProcess ?? _defaultRunProcess;

  final Future<bool> Function() ensureSudoFresh;
  final Future<SudoResult> Function(List<String> args) runSudo;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final String seedPath;
  final String unit;

  bool _sudoAnnounced = false;

  static Future<ProcessResult> _defaultRunProcess(
    String cmd,
    List<String> args,
  ) => Process.run(cmd, args);

  Future<SeedWaitStatus> poll() async {
    try {
      return await _pollInner();
    } catch (e, st) {
      LogService.error('LndSeedWaitService.poll failed', e, st);
      return SeedWaitStatus(
        phase: SeedWaitPhase.startingService,
        error: 'Seed wait failed: $e',
      );
    }
  }

  Future<SeedWaitStatus> _pollInner() async {
    // Unprivileged gate first — never sudo before the unit is active.
    final show = await _runProcess('systemctl', [
      'show',
      unit,
      '--property=ActiveState,SubState',
      '--no-pager',
    ]);
    final state = SystemService.parseServiceStatus(
      unit,
      show.stdout as String,
    ).state;

    if (state == ServiceState.failed) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.startingService,
        lndState: state,
        error: 'lnd service failed to start — press [l] for the LND log.',
      );
    }
    if (state != ServiceState.running) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.startingService,
        lndState: state,
      );
    }

    // Announce-only tick: the UI gets one full poll interval showing
    // the sudo warning before the first privileged call can prompt.
    if (!_sudoAnnounced) {
      _sudoAnnounced = true;
      return SeedWaitStatus(
        phase: SeedWaitPhase.waitingForSeedFile,
        lndState: state,
      );
    }

    final ok = await ensureSudoFresh();
    if (!ok) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.waitingForSeedFile,
        lndState: state,
        error: 'Sudo authorization cancelled.',
      );
    }

    final probe = await runSudo(['test', '-f', seedPath]);
    if (probe.exitCode != 0) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.waitingForSeedFile,
        lndState: state,
      );
    }

    final res = await runSudo(['cat', seedPath]);
    if (res.exitCode != 0) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.readingSeed,
        lndState: state,
        error:
            'Could not read seed file (exit ${res.exitCode}): '
            '${res.stderr.trim()}',
      );
    }

    final words = res.stdout
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.length != 24) {
      return SeedWaitStatus(
        phase: SeedWaitPhase.readingSeed,
        lndState: state,
        error:
            'Seed file has ${words.length} words; expected 24. '
            'Aborting display.',
      );
    }

    return SeedWaitStatus(
      phase: SeedWaitPhase.done,
      lndState: state,
      seedWords: words,
    );
  }
}
