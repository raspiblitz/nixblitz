import 'dart:io';

import 'package:common/common.dart';
import 'package:test/test.dart';

/// Scripted fakes: each test declares what systemctl reports and how the
/// sudo probes behave, then asserts the returned phase AND how many sudo
/// calls were made (the deferral guarantee is call-count based).
class _Harness {
  // ensureFreshResult / testFileExists / catResult are set via
  // post-construction cascades in individual tests rather than passed
  // as constructor args, so the analyzer's call-site usage check can't
  // see them being exercised — silence the false positive.
  _Harness({
    required this.activeStates, // consumed one per poll() call
    // ignore: unused_element_parameter
    this.ensureFreshResult = true,
    // ignore: unused_element_parameter
    this.testFileExists = false,
    // ignore: unused_element_parameter
    this.catResult = (exitCode: 0, stdout: '', stderr: ''),
  });

  final List<String> activeStates;
  bool ensureFreshResult;
  bool testFileExists;
  ({int exitCode, String stdout, String stderr}) catResult;

  int systemctlCalls = 0;
  int ensureFreshCalls = 0;
  final List<List<String>> sudoCalls = [];

  late final LndSeedWaitService service = LndSeedWaitService(
    ensureSudoFresh: () async {
      ensureFreshCalls++;
      return ensureFreshResult;
    },
    runSudo: (args) async {
      sudoCalls.add(args);
      if (args.first == 'test') {
        return (exitCode: testFileExists ? 0 : 1, stdout: '', stderr: '');
      }
      if (args.first == 'cat') return catResult;
      return (exitCode: 0, stdout: '', stderr: '');
    },
    runProcess: (cmd, args) async {
      systemctlCalls++;
      final state =
          activeStates[systemctlCalls <= activeStates.length
              ? systemctlCalls - 1
              : activeStates.length - 1];
      return ProcessResult(0, 0, 'ActiveState=$state\nSubState=x\n', '');
    },
  );
}

const _seed24 =
    'ability ability ability ability ability ability ability ability '
    'ability ability ability ability ability ability ability ability '
    'ability ability ability ability ability ability ability ability';

void main() {
  group('LndSeedWaitService.poll', () {
    test('unit inactive → startingService, ZERO sudo activity', () async {
      final h = _Harness(activeStates: ['inactive']);
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.startingService);
      expect(s.lndState, ServiceState.stopped);
      expect(s.isTerminal, isFalse);
      expect(h.ensureFreshCalls, 0);
      expect(h.sudoCalls, isEmpty);
    });

    test('unit activating → startingService, still no sudo', () async {
      final h = _Harness(activeStates: ['activating']);
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.startingService);
      expect(h.ensureFreshCalls, 0);
    });

    test('unit failed → error set, phase startingService, no sudo', () async {
      final h = _Harness(activeStates: ['failed']);
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.startingService);
      expect(s.error, contains('lnd service failed'));
      expect(s.isTerminal, isTrue);
      expect(h.ensureFreshCalls, 0);
    });

    test('first active poll is announce-only: waitingForSeedFile with '
        'ZERO sudo calls; second active poll probes', () async {
      final h = _Harness(activeStates: ['active', 'active']);
      final first = await h.service.poll();
      expect(first.phase, SeedWaitPhase.waitingForSeedFile);
      expect(h.ensureFreshCalls, 0, reason: 'announce tick must not sudo');
      expect(h.sudoCalls, isEmpty);

      final second = await h.service.poll();
      expect(second.phase, SeedWaitPhase.waitingForSeedFile);
      expect(h.ensureFreshCalls, 1);
      expect(h.sudoCalls, [
        ['test', '-f', '/mnt/data/lnd/lnd-seed-mnemonic'],
      ]);
    });

    test('sudo cancelled → error, phase waitingForSeedFile', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..ensureFreshResult = false;
      await h.service.poll(); // announce
      final s = await h.service.poll();
      expect(s.error, 'Sudo authorization cancelled.');
      expect(s.phase, SeedWaitPhase.waitingForSeedFile);
      expect(s.isTerminal, isTrue);
    });

    test('file present + 24 words → done with seedWords', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..testFileExists = true
        ..catResult = (exitCode: 0, stdout: _seed24, stderr: '');
      await h.service.poll(); // announce
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.done);
      expect(s.seedWords, hasLength(24));
      expect(s.isTerminal, isTrue);
    });

    test('cat fails → error mentions exit code, phase readingSeed', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..testFileExists = true
        ..catResult = (exitCode: 1, stdout: '', stderr: 'denied');
      await h.service.poll();
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.readingSeed);
      expect(s.error, contains('exit 1'));
    });

    test('wrong word count → error, phase readingSeed', () async {
      final h = _Harness(activeStates: ['active', 'active'])
        ..testFileExists = true
        ..catResult = (exitCode: 0, stdout: 'only three words', stderr: '');
      await h.service.poll();
      final s = await h.service.poll();
      expect(s.phase, SeedWaitPhase.readingSeed);
      expect(s.error, contains('3 words'));
    });

    test(
      'systemctl runner throwing → error status, not an exception',
      () async {
        final service = LndSeedWaitService(
          ensureSudoFresh: () async => true,
          runSudo: (_) async => (exitCode: 0, stdout: '', stderr: ''),
          runProcess: (_, _) async =>
              throw const ProcessException('systemctl', []),
        );
        final s = await service.poll();
        expect(s.error, isNotNull);
        expect(s.isTerminal, isTrue);
      },
    );
  });
}
