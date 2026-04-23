{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.features.apps.bitcoind;
in {
  options.features.apps.bitcoind = {
    enable = lib.mkEnableOption "Bitcoin daemon";
    network = lib.mkOption {
      # testnet / signet are parked until nix-bitcoin grows section-aware
      # config generation (top-level rpcbind/rpcport are rejected by
      # Bitcoin Core on non-main networks). See IDEAS.md.
      type = lib.types.enum ["mainnet" "regtest"];
      default = "mainnet";
      description = "Bitcoin network to connect to.";
    };
    pruned = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to prune the blockchain.";
    };
    pruneSizeGb = lib.mkOption {
      type = lib.types.int;
      default = 550;
      description = "Prune target size in GB (minimum 550).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.bitcoind = {
      enable = true;
      dataDir = "/mnt/data/bitcoind";
      regtest = cfg.network == "regtest";
      prune = if cfg.pruned then cfg.pruneSizeGb * 1000 else 0;
      # nix-bitcoin writes `[regtest]` and the regtest-scoped options
      # before our extraConfig, so anything here lands inside the
      # regtest section.
      extraConfig = lib.optionalString (cfg.network == "regtest") ''
        # Regtest has no real tx activity for bitcoind to infer fee
        # rates from; without a fallback, sendtoaddress / fundrawtx
        # refuse with "Fee estimation failed. Fallbackfee is disabled."
        # 0.0002 BTC/kvB ≈ 20 sat/vB, plenty for test flows.
        fallbackfee=0.0002
      '';
    };
  };
}
