import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:common/common.dart';

const _supportedPlatforms = {'x86', 'pi5'};

/// `nixblitz init` — bootstraps a build-host profile at [baseDir]
/// without entering the TUI:
///
/// - Writes the embedded NixOS module templates.
/// - Writes a minimal `config.json` with the chosen platform and
///   `setup_step_completed = "summary"` so the next `nixblitz`
///   launch routes straight to the dashboard (skipping the wizard,
///   which requires an installer environment).
/// - Initialises a git repo and records the initial commit.
///
/// Intended for operators using a regular NixOS workstation (not the
/// live ISO) as a build profile — e.g. populating an Attic binary
/// cache via `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`.
class InitCommand extends Command<int> {
  InitCommand(this.baseDir) {
    argParser
      ..addOption(
        'platform',
        defaultsTo: 'x86',
        allowed: _supportedPlatforms.toList(),
        help: 'Target platform for the build profile (x86 or pi5).',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing config.json.',
      );
  }

  final String baseDir;

  @override
  final String name = 'init';

  @override
  final String description =
      'Bootstrap a build-host profile at ~/nixblitz/ (skips the TUI).';

  @override
  Future<int> run() {
    final args = argResults!;
    return _runInit(
      baseDir,
      platform: args['platform'] as String,
      force: args['force'] as bool,
    );
  }
}

Future<int> _runInit(
  String baseDir, {
  required String platform,
  required bool force,
}) async {
  if (!_supportedPlatforms.contains(platform)) {
    stderr.writeln(
      'unknown platform: $platform (expected one of: '
      '${_supportedPlatforms.join(", ")})',
    );
    return 2;
  }

  final configService = ConfigService(baseDir: baseDir);
  if (configService.configExists() && !force) {
    stderr.writeln(
      'refusing to overwrite existing $baseDir/config.json '
      '(pass --force to replace)',
    );
    return 1;
  }

  try {
    final manifest = BranchManifest.fromJson(
      jsonDecode(EmbeddedTemplates.nixblitzBranchesJson)
          as Map<String, dynamic>,
    );
    final scaffold = ScaffoldService(targetDir: baseDir);
    if (scaffold.needsScaffold()) {
      await scaffold.scaffold(manifest: manifest);
    } else {
      // Existing dir (e.g. partial init or --force on a populated
      // dir): refresh templates so the on-disk Nix matches the
      // bundled set; the binary it shipped with is the source of
      // truth.
      scaffold.refreshTemplatesSync(manifest: manifest);
    }

    final config = NixblitzConfig(
      system: SystemConfig.defaults().copyWith(platform: platform),
      appConfigs: const {},
    ).copyWith(setupStepCompleted: () => 'summary');
    configService.writeConfigSync(config);

    // hosts/installed.nix imports ../hardware-configuration.nix. The
    // install wizard generates it via `nixos-generate-config` on the
    // target box; on a build host, that machine's hwconfig would be
    // wrong for the target anyway. Write an empty stub so evaluation
    // succeeds and the operator can replace it if they want to deploy
    // the resulting closure to actual hardware.
    final hwConfigPath = '$baseDir/hardware-configuration.nix';
    if (!File(hwConfigPath).existsSync() || force) {
      File(hwConfigPath).writeAsStringSync(
        '# Placeholder written by `nixblitz init`.\n'
        '#\n'
        '# For a build-only workflow (Attic cache population,\n'
        '# cross-target evaluation), this empty stub is enough — the\n'
        '# flake-level `nixosSystem` call sets the target architecture\n'
        '# and disko owns the filesystem layout. To deploy the resulting\n'
        '# closure to real hardware, replace this file with the output of\n'
        '#   sudo nixos-generate-config --show-hardware-config\n'
        '# run on the target.\n'
        '{...}: {}\n',
      );
    }

    final git = GitService(repoDir: baseDir);
    final isAlreadyRepo = Directory('$baseDir/.git').existsSync();
    if (!isAlreadyRepo) {
      if (!await git.init()) {
        stderr.writeln('git init failed in $baseDir');
        return 1;
      }
    }

    final addResult = await Process.run('git', [
      'add',
      '.',
    ], workingDirectory: baseDir);
    if (addResult.exitCode != 0) {
      stderr.writeln('git add failed: ${addResult.stderr}');
      return 1;
    }
    final commitMessage = isAlreadyRepo
        ? 'Re-init NixBlitz build profile (--force)'
        : 'Initial configuration (schema v$currentConfigVersion)';
    final commitResult = await Process.run('git', [
      'commit',
      '--allow-empty',
      '-m',
      commitMessage,
    ], workingDirectory: baseDir);
    if (commitResult.exitCode != 0) {
      stderr.writeln('git commit failed: ${commitResult.stderr}');
      return 1;
    }

    stdout.writeln(
      'Initialized NixBlitz profile at $baseDir (platform: $platform).',
    );
    stdout.writeln(
      'Next: edit $baseDir/config.json or run `nixblitz` to configure '
      'and `sudo nixos-rebuild build --flake $baseDir#<host>` to build.',
    );
    return 0;
  } catch (e, st) {
    stderr.writeln('error: $e');
    stderr.writeln(st);
    return 1;
  }
}
