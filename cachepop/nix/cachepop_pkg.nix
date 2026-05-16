{
  lib,
  writeShellApplication,
  nixVersions,
  jq,
  attic-client,
  git,
  coreutils,
  gawk,
  nixblitz,
}:
writeShellApplication {
  name = "cachepop";

  # nixblitz is on the runtime PATH because cachepop's `init` and
  # `plugin add` subcommands shell out to it; without that, the build
  # host needs to either install nixblitz separately or symlink it in.
  # The version pinned here is whatever `self.packages.${system}.nixblitz`
  # resolved to, so cachepop and the TUI move forward together.
  #
  # nixVersions.latest (vs pkgs.nix) is used so `nix flake update` and
  # `nix build --json` honour the modern flake-output schema the rest
  # of the project assumes. attic-client (not the server) is the
  # `attic` push CLI.
  runtimeInputs = [
    nixVersions.latest
    jq
    attic-client
    git
    coreutils
    gawk
    nixblitz
  ];

  text = builtins.readFile ../bin/cachepop;

  meta = with lib; {
    description = "Attic cache populator for nixblitz build hosts";
    license = licenses.mit;
    mainProgram = "cachepop";
  };
}
