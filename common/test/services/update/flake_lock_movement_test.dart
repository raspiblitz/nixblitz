import 'dart:convert';

import 'package:common/common.dart';
import 'package:test/test.dart';

/// Builds a flake.lock JSON string. [nodes] maps node key →
/// (narHash, rev?, pathForm). Path-form entries mimic the offline
/// installer's path-locked pins (no rev, `type: path`); the github
/// form mimics what `nix flake update` rewrites them into.
String _lock(
  Map<String, ({String narHash, String? rev, bool pathForm})> nodes,
) {
  final n = <String, dynamic>{
    'root': {
      'inputs': {for (final k in nodes.keys) k: k},
    },
  };
  nodes.forEach((key, spec) {
    n[key] = {
      'locked': {
        'narHash': spec.narHash,
        if (spec.pathForm) ...{
          'type': 'path',
          'path': '/nix/store/aaaa-source',
          'lastModified': 0,
        } else ...{
          'type': 'github',
          'owner': 'o',
          'repo': 'r',
          if (spec.rev != null) 'rev': spec.rev,
          'lastModified': 1753000000,
        },
      },
      'original': spec.pathForm
          ? {'type': 'path', 'path': '/nix/store/aaaa-source'}
          : {'type': 'github', 'owner': 'o', 'repo': 'r'},
    };
  });
  return jsonEncode({'nodes': n, 'root': 'root', 'version': 7});
}

void main() {
  const hashA = 'sha256-AAAA';
  const hashB = 'sha256-BBBB';
  const rev = '4d2d3ac96de2aaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  group('lockMovementRequiresStaging', () {
    test('pure path→github URL-form rewrite with identical narHashes is '
        'NOT movement (the offline-node first-check trap: byte-diff '
        'always, content-diff never)', () {
      final live = _lock({
        'nixpkgs': (narHash: hashA, rev: null, pathForm: true),
        'disko': (narHash: hashB, rev: null, pathForm: true),
      });
      final cand = _lock({
        'nixpkgs': (narHash: hashA, rev: 'abc', pathForm: false),
        'disko': (narHash: hashB, rev: 'def', pathForm: false),
      });
      expect(
        lockMovementRequiresStaging(
          liveLockRaw: live,
          candidateLockRaw: cand,
          runningGitHash: '4d2d3ac',
        ),
        isFalse,
      );
    });

    test('a non-nixblitz input with a changed narHash IS movement', () {
      final live = _lock({
        'nixpkgs': (narHash: hashA, rev: null, pathForm: true),
      });
      final cand = _lock({
        'nixpkgs': (narHash: hashB, rev: 'abc', pathForm: false),
      });
      expect(
        lockMovementRequiresStaging(
          liveLockRaw: live,
          candidateLockRaw: cand,
          runningGitHash: '4d2d3ac',
        ),
        isTrue,
      );
    });

    test('nixblitz-only narHash change whose candidate rev matches the '
        'running build is NOT movement (the baked path pin carries a '
        '.nixblitz-version-stamp the git source lacks, so its narHash '
        'differs even at identical code)', () {
      final live = _lock({
        'nixblitz': (narHash: hashA, rev: null, pathForm: true),
        'nixpkgs': (narHash: hashB, rev: null, pathForm: true),
      });
      final cand = _lock({
        'nixblitz': (narHash: 'sha256-STAMPLESS', rev: rev, pathForm: false),
        'nixpkgs': (narHash: hashB, rev: 'def', pathForm: false),
      });
      expect(
        lockMovementRequiresStaging(
          liveLockRaw: live,
          candidateLockRaw: cand,
          runningGitHash: '4d2d3ac',
        ),
        isFalse,
      );
    });

    test('nixblitz-only change with a DIFFERENT candidate rev IS movement '
        '(a real upstream nixblitz update)', () {
      final live = _lock({
        'nixblitz': (narHash: hashA, rev: null, pathForm: true),
      });
      final cand = _lock({
        'nixblitz': (narHash: hashB, rev: 'ffffffffffff', pathForm: false),
      });
      expect(
        lockMovementRequiresStaging(
          liveLockRaw: live,
          candidateLockRaw: cand,
          runningGitHash: '4d2d3ac',
        ),
        isTrue,
      );
    });

    test('nixblitz-only change with an unusable running hash is movement '
        '(conservative: dev/dirty builds cannot vouch for their rev)', () {
      final live = _lock({
        'nixblitz': (narHash: hashA, rev: null, pathForm: true),
      });
      final cand = _lock({
        'nixblitz': (narHash: hashB, rev: rev, pathForm: false),
      });
      for (final h in [null, 'local', '', '4d2d3ac-dirty']) {
        expect(
          lockMovementRequiresStaging(
            liveLockRaw: live,
            candidateLockRaw: cand,
            runningGitHash: h,
          ),
          isTrue,
          reason: 'hash=$h must be conservative',
        );
      }
    });

    test('an added or removed node is movement', () {
      final live = _lock({
        'nixpkgs': (narHash: hashA, rev: null, pathForm: true),
      });
      final cand = _lock({
        'nixpkgs': (narHash: hashA, rev: 'abc', pathForm: false),
        'newdep': (narHash: hashB, rev: 'xyz', pathForm: false),
      });
      expect(
        lockMovementRequiresStaging(
          liveLockRaw: live,
          candidateLockRaw: cand,
          runningGitHash: '4d2d3ac',
        ),
        isTrue,
      );
    });

    test('malformed lock JSON falls back to staging (old byte-gate '
        'behavior)', () {
      expect(
        lockMovementRequiresStaging(
          liveLockRaw: 'not json',
          candidateLockRaw: _lock({
            'nixpkgs': (narHash: hashA, rev: 'abc', pathForm: false),
          }),
          runningGitHash: '4d2d3ac',
        ),
        isTrue,
      );
    });

    test('identical documents are not movement', () {
      final l = _lock({
        'nixpkgs': (narHash: hashA, rev: 'abc', pathForm: false),
      });
      expect(
        lockMovementRequiresStaging(
          liveLockRaw: l,
          candidateLockRaw: l,
          runningGitHash: '4d2d3ac',
        ),
        isFalse,
      );
    });
  });
}
