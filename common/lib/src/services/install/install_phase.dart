/// Coarse phase of a `disko-install` run, derived from its plain output.
/// Failure is NOT a phase here — the view represents it via
/// `InstallStep.failed` on a non-zero exit.
enum InstallPhase {
  preparing,
  // Order matters: the tracker's monotonic guard compares enum indices,
  // so evaluating must sit before building.
  evaluating,
  building,
  partitioning,
  formatting,
  mounting,
  copying,
  loadingDb,
  installing,
  done,
}

/// Classify a single output line into a phase transition, or null when
/// the line implies no change. First match wins; ordered so the
/// load-bearing offline markers ("Copying store paths", "Loading nix
/// database") and end phases win over the coarser build/partition ones.
InstallPhase? installPhaseForLine(String line) {
  final l = line.toLowerCase();
  if (l.contains('disko-install succeeded')) return InstallPhase.done;
  // Nix evaluation of the full system is SILENT for minutes on a Pi 5
  // (single-threaded eval on a slow SoC) — without an explicit phase the
  // install looks hung right after the command echo. Enter it on the
  // TUI's own command echo and hold it through eval-time chatter.
  if (l.contains('disko-install --flake') ||
      l.contains('evaluation warning') ||
      l.contains('not writing modified lock file')) {
    return InstallPhase.evaluating;
  }
  if (l.contains('loading nix database')) return InstallPhase.loadingDb;
  if (l.contains('boot loader') || l.contains('nixos-install')) {
    return InstallPhase.installing;
  }
  // ONLY disko-install's own "Copying store paths" echo marks the real
  // store-to-disk copy (the xargs cp). Nix's lowercase "copying path
  // '…' from cache…" lines fire during build/eval — matching those
  // flipped the bar to copying prematurely and parked it at a few %
  // against the still-empty target disk (seen on a VM install).
  if (l.contains('copying store paths')) {
    return InstallPhase.copying;
  }
  if (l.contains('mkfs') || l.contains('formatting')) {
    return InstallPhase.formatting;
  }
  if (l.contains('mount ')) return InstallPhase.mounting;
  if (l.contains('sgdisk') || l.contains('wipefs') || l.contains('zpool')) {
    return InstallPhase.partitioning;
  }
  if (l.contains('building ')) return InstallPhase.building;
  if (l.contains('evaluating')) return InstallPhase.evaluating;
  return null;
}

/// Human label for a phase. For phases that `parseDiskoStep` already
/// labelled, the string is identical (preserving existing behaviour).
String phaseLabel(InstallPhase phase) => switch (phase) {
  InstallPhase.preparing => 'Starting...',
  InstallPhase.evaluating =>
    'Evaluating system configuration (quiet — takes minutes on a Pi)...',
  InstallPhase.building => 'Building install artifacts...',
  InstallPhase.partitioning => 'Partitioning disk...',
  InstallPhase.formatting => 'Formatting partitions...',
  InstallPhase.mounting => 'Mounting filesystems...',
  InstallPhase.copying => 'Copying NixOS store paths...',
  InstallPhase.loadingDb => 'Loading Nix database...',
  InstallPhase.installing => 'Installing bootloader...',
  InstallPhase.done => 'Finishing...',
};
