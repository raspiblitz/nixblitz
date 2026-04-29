// common/lib/src/services/git_service.dart
import 'dart:io';

/// Result of `git verify-commit` / `git log --format=%G…`. See
/// [GitService.verifyCommit].
///
/// The trust model interpretation lives in
/// `docs/decisions/plugin-trust-models.md` Approach A: the
/// fingerprint is what we pin / TOFU on, and the status code
/// distinguishes "signed by a key the operator's git keyring
/// recognises" from "signed but unverified" from "unsigned."
class GitSignature {
  const GitSignature({
    required this.status,
    required this.fingerprint,
    required this.signer,
    required this.primaryKeyFingerprint,
  });

  /// One-letter code from `--format=%G?`:
  ///
  /// - `'G'` — good signature, key matched against the operator's
  ///   keyring / `allowed_signers` file.
  /// - `'U'` — good signature with **unknown validity** (signature
  ///   verifies cryptographically but the key isn't in the
  ///   operator's trusted set). Useful as a fingerprint for TOFU.
  /// - `'X'` / `'Y'` / `'R'` — good signature, but expired /
  ///   expired-key / revoked-key respectively.
  /// - `'B'` — bad signature.
  /// - `'E'` — verification failed for another reason
  ///   (missing key, etc.).
  /// - `'N'` — no signature on the commit.
  final String status;

  /// Key fingerprint from `--format=%GF`. SSH: SHA256 fingerprint
  /// (`SHA256:abc…`). GPG: long key id. Empty when [status] is
  /// `'N'` or git couldn't surface the fingerprint.
  final String fingerprint;

  /// Signer identity from `--format=%GS`. For SSH-signed commits
  /// this is often empty (SSH commit signatures don't carry an
  /// embedded user id by default). For GPG, the primary uid.
  final String signer;

  /// GPG primary-key fingerprint from `--format=%GP`. Useful when
  /// a project rotates signing subkeys but the primary stays
  /// stable. Empty for SSH signatures.
  final String primaryKeyFingerprint;

  /// True when the commit carries any signature (verifiable or
  /// not).
  bool get isPresent => status != 'N' && status != '' && status != 'E';

  /// True when the signature is good AND validates against the
  /// operator's local keyring / allowed_signers file. `'U'` is
  /// excluded — it means "cryptographically valid but the key
  /// isn't trusted."
  bool get isVerified => status == 'G';

  /// True when the signature is cryptographically good but the
  /// signer's key isn't in the operator's trusted set. Common for
  /// SSH-signed commits when `~/.ssh/allowed_signers` doesn't
  /// list the publisher.
  bool get isUnknownTrust => status == 'U';
}

class GitService {
  GitService({
    required this.repoDir,
    this.environment,
    this.extraConfigArgs = const [],
  });

  final String repoDir;

  /// Optional environment overrides for every spawned `git` process.
  /// Merged into the parent environment (Dart's
  /// `Process.run(includeParentEnvironment: true)` is the default).
  /// Production callers leave this null; tests pass a hermetic map
  /// so the user's `~/.gitconfig`, ssh-agent state, and
  /// askpass setup don't leak into the test harness — see
  /// `common/test/test_helpers/git_isolation.dart`.
  final Map<String, String>? environment;

  /// `-c key=value` pairs prepended before every git subcommand.
  /// Same purpose as [environment]: lets tests force
  /// `commit.gpgsign=false`, etc., without touching production
  /// behaviour at user-Apply time.
  final List<String> extraConfigArgs;

  /// Prepend the per-instance `-c` overrides to a subcommand argv.
  List<String> _g(List<String> args) => [...extraConfigArgs, ...args];

  Future<bool> init() async {
    final result = await Process.run(
      'git',
      _g(['init']),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (result.exitCode != 0) return false;
    await Process.run(
      'git',
      _g(['config', 'user.email', 'nixblitz@localhost']),
      workingDirectory: repoDir,
      environment: environment,
    );
    await Process.run(
      'git',
      _g(['config', 'user.name', 'NixBlitz']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return true;
  }

  Future<bool> commit(String filePath, String message) async {
    final add = await Process.run(
      'git',
      _g(['add', filePath]),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (add.exitCode != 0) return false;
    final commit = await Process.run(
      'git',
      _g(['commit', '-m', message]),
      workingDirectory: repoDir,
      environment: environment,
    );
    return commit.exitCode == 0;
  }

  Future<bool> revertLast() async {
    final result = await Process.run(
      'git',
      _g(['revert', '--no-edit', 'HEAD']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.exitCode == 0;
  }

  Future<String> log({int count = 10}) async {
    final result = await Process.run(
      'git',
      _g(['log', '--oneline', '-$count']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.stdout as String;
  }

  /// Diff the working tree against HEAD (tracked files only). Pass a path to
  /// restrict the diff. Always returns uncolored text suitable for rendering
  /// in a plain [ScrollableLog].
  Future<String> diff({String? path}) async {
    final args = ['diff', '--no-color', ?path];
    final result = await Process.run(
      'git',
      _g(args),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.stdout as String;
  }

  /// List of `XY path` lines from `git status --porcelain`. Each line
  /// describes one tracked or untracked file that differs from HEAD.
  Future<List<String>> status() async {
    final result = await Process.run(
      'git',
      _g(['status', '--porcelain']),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (result.exitCode != 0) return const [];
    return (result.stdout as String)
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Stage every change (tracked or untracked) and commit with [message].
  /// Returns true only if the commit was created; `git add` failing or
  /// nothing-to-commit both yield false.
  Future<bool> commitAll(String message) async {
    final add = await Process.run(
      'git',
      _g(['add', '-A']),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (add.exitCode != 0) return false;
    final commit = await Process.run(
      'git',
      _g(['commit', '-m', message]),
      workingDirectory: repoDir,
      environment: environment,
    );
    return commit.exitCode == 0;
  }

  /// Stage [paths] (relative to [repoDir]) and commit with [message].
  /// Useful when an automated step should commit *only* the files it
  /// touched, leaving any unrelated working-tree edits the user may
  /// have for their own Apply step. Returns true only when a commit
  /// was created.
  Future<bool> commitPaths(List<String> paths, String message) async {
    if (paths.isEmpty) return false;
    final add = await Process.run(
      'git',
      _g(['add', ...paths]),
      workingDirectory: repoDir,
      environment: environment,
    );
    if (add.exitCode != 0) return false;
    final commit = await Process.run(
      'git',
      _g(['commit', '-m', message]),
      workingDirectory: repoDir,
      environment: environment,
    );
    return commit.exitCode == 0;
  }

  /// Inspect the signature on [ref] (default `HEAD`). Returns a
  /// [GitSignature] with the status code, key fingerprint, and
  /// signer identity. Never throws on unsigned input — returns a
  /// `GitSignature` with `status: 'N'` and empty fields.
  ///
  /// **Production callers should construct [GitService] without
  /// passing [environment]** so the operator's actual GPG / SSH
  /// configuration (notably `~/.gitconfig` and
  /// `~/.ssh/allowed_signers`) is visible to git. Tests using the
  /// hermetic env helper get unsigned results by design.
  Future<GitSignature> verifyCommit({String ref = 'HEAD'}) async {
    // First pass: respect the operator's actual git config. If
    // they have `gpg.ssh.allowedSignersFile` set up with the
    // signer's key listed, this returns status `G` (verified).
    final parsed = await _runVerifyFormat(ref);
    if (parsed == null) {
      return const GitSignature(
        status: 'N',
        fingerprint: '',
        signer: '',
        primaryKeyFingerprint: '',
      );
    }
    if (parsed.fingerprint.isNotEmpty) return parsed;

    // First pass surfaced no fingerprint. This collapses two
    // distinct cases into the same shape: genuinely unsigned, OR
    // signed by an SSH key but git refused to look because
    // `gpg.ssh.allowedSignersFile` isn't configured (a fresh
    // operator account has no allowed_signers, and git emits a
    // warning + reports `N` for the *signed* commit). Retry once
    // with a temp empty allowed_signers so SSH verification at
    // least runs to the point where it surfaces the fingerprint
    // as `U` (good signature, unknown trust). For genuinely
    // unsigned commits the retry is harmless — still `N`. For
    // GPG-signed commits the SSH config doesn't change git's GPG
    // path, so they're unaffected.
    final tmp = File(
      '${Directory.systemTemp.path}/'
      'nixblitz-empty-signers-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      tmp.writeAsStringSync('');
      final retry = await _runVerifyFormat(
        ref,
        prependConfig: ['-c', 'gpg.ssh.allowedSignersFile=${tmp.path}'],
      );
      if (retry != null && retry.fingerprint.isNotEmpty) return retry;
    } catch (_) {
      // Retry is best-effort. Fall through to the first-pass result.
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
    return parsed;
  }

  /// Run `git log -1 --format=%G?…<NUL>%GF…<NUL>%GS…<NUL>%GP` and
  /// shape the result. Returns null on non-zero exit. The
  /// [prependConfig] hook is for [verifyCommit]'s SSH fallback —
  /// callers other than verifyCommit shouldn't need it.
  Future<GitSignature?> _runVerifyFormat(
    String ref, {
    List<String> prependConfig = const [],
  }) async {
    // %x00 (NUL) separator avoids any collision with content the
    // signer / key fields might contain.
    final r = await Process.run(
      'git',
      [
        ...prependConfig,
        ..._g(['log', '-1', '--format=%G?%x00%GF%x00%GS%x00%GP', ref]),
      ],
      workingDirectory: repoDir,
      environment: environment,
    );
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String).trimRight();
    final parts = out.split('\u0000');
    while (parts.length < 4) {
      parts.add('');
    }
    return GitSignature(
      status: parts[0].isEmpty ? 'N' : parts[0],
      fingerprint: parts[1],
      signer: parts[2],
      primaryKeyFingerprint: parts[3],
    );
  }

  /// Returns the current `HEAD` SHA, or null if `git rev-parse` fails
  /// (e.g. an empty repo, missing `.git`). Tests can use this to
  /// detect commits made between two points without parsing log
  /// output.
  Future<String?> headRef() async {
    try {
      final r = await Process.run(
        'git',
        _g(['rev-parse', 'HEAD']),
        workingDirectory: repoDir,
        environment: environment,
      );
      if (r.exitCode != 0) return null;
      return (r.stdout as String).trim();
    } catch (_) {
      return null;
    }
  }

  /// Revert the working tree to match HEAD, wiping any uncommitted changes.
  /// Untracked files are left in place.
  Future<bool> discardAll() async {
    final result = await Process.run(
      'git',
      _g(['checkout', '--', '.']),
      workingDirectory: repoDir,
      environment: environment,
    );
    return result.exitCode == 0;
  }
}
