/// Coarse phase of a `disko-install` run, derived from its plain output.
/// Failure is NOT a phase here — the view represents it via
/// `InstallStep.failed` on a non-zero exit.
enum InstallPhase {
  preparing,
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
  if (l.contains('loading nix database')) return InstallPhase.loadingDb;
  if (l.contains('boot loader') || l.contains('nixos-install')) {
    return InstallPhase.installing;
  }
  // "Copying store paths" (disko-install echo) OR nix's "copying path '...'".
  if (l.contains('copying store paths') || l.contains('copying')) {
    return InstallPhase.copying;
  }
  if (l.contains('mkfs') || l.contains('formatting')) {
    return InstallPhase.formatting;
  }
  if (l.contains('mount ')) return InstallPhase.mounting;
  if (l.contains('sgdisk') || l.contains('wipefs') || l.contains('zpool')) {
    return InstallPhase.partitioning;
  }
  if (l.contains('building ') || l.contains('evaluating')) {
    return InstallPhase.building;
  }
  return null;
}

/// Human label for a phase. For phases that `parseDiskoStep` already
/// labelled, the string is identical (preserving existing behaviour).
String phaseLabel(InstallPhase phase) => switch (phase) {
  InstallPhase.preparing => 'Starting...',
  InstallPhase.building => 'Building install artifacts...',
  InstallPhase.partitioning => 'Partitioning disk...',
  InstallPhase.formatting => 'Formatting partitions...',
  InstallPhase.mounting => 'Mounting filesystems...',
  InstallPhase.copying => 'Copying NixOS store paths...',
  InstallPhase.loadingDb => 'Loading Nix database...',
  InstallPhase.installing => 'Installing bootloader...',
  InstallPhase.done => 'Finishing...',
};
