// Generates shell completion scripts for the `nixblitz` binary into
// `tui/completions/nixblitz.{bash,zsh}`. Committed to the repo so the
// Nix package install hook can drop them at the standard NixOS paths
// (`$out/share/bash-completion/completions/nixblitz`,
// `$out/share/zsh/site-functions/_nixblitz`) without needing the
// binary to run install-completion-files at first launch.
//
// The scripts are generic shell stubs that call
// `nixblitz completion -- "${words[@]}"` at runtime; cli_completion's
// `HandleCompletionRequestCommand` does the actual command-tree
// completion server-side. That means these files change only when
// cli_completion's template changes (rare, on package upgrade), not
// when our command tree changes.
//
// Run: `just gen-completions`

import 'dart:io';

import 'package:cli_completion/installer.dart';
import 'package:path/path.dart' as p;

const _executableName = 'nixblitz';

void main(List<String> args) {
  // Resolve repo root relative to this script's location so the
  // generator works regardless of cwd (it's invoked from `just`).
  final repoRoot = _resolveRepoRoot();
  final outDir = p.join(repoRoot, 'tui', 'completions');
  Directory(outDir).createSync(recursive: true);

  for (final shell in [SystemShell.bash, SystemShell.zsh]) {
    final config = ShellCompletionConfiguration.fromSystemShell(shell);
    final script = config.scriptTemplate(_executableName);
    final outPath = p.join(outDir, '$_executableName.${shell.name}');
    File(outPath).writeAsStringSync(script);
    stdout.writeln('wrote $outPath (${script.length} bytes)');
  }
}

/// Walk up from this script's path until a directory with `flake.nix`
/// + `tui/` is found. Falls back to `Directory.current` if the walk
/// hits the filesystem root.
String _resolveRepoRoot() {
  var dir = Directory(p.dirname(Platform.script.toFilePath()));
  while (true) {
    if (File(p.join(dir.path, 'flake.nix')).existsSync() &&
        Directory(p.join(dir.path, 'tui')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      // Hit /, give up — caller will see the path errors.
      return Directory.current.path;
    }
    dir = parent;
  }
}
