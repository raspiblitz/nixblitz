{lib, ...}: {
  # Read-only view of `config.json`'s `app_configs.*` block, exposed
  # at the NixOS-config level so plugins can do cross-app reads
  # without depending on a plugin ABI extension.
  #
  # E.g. blitz-api checks `config.nixblitz.appConfigs.lnd.enabled or
  # false` to decide whether to wire LND's admin macaroon. Replaces
  # the `config.features.apps.<id>.{enable,network}` accessor that
  # came out with the bitcoind/lnd/cln plugin extraction — that
  # wiring assumed every core app had a NixOS-options frontend, but
  # extracted plugins no longer declare those options.
  #
  # Type is deliberately loose (`attrsOf attrs`) — the shape of each
  # app's block is whatever its plugin's `config_schema` declares,
  # and we don't want to repeat that schema here. Plugins read
  # individual keys with `or default` fallbacks.
  #
  # The option is FED from `templates/hosts/installed.nix`'s `apps =
  # cfg.app_configs or {}` let-binding (single source of truth — the
  # same map the helpers `appOpt` / `appEnabled` consume).
  options.nixblitz.appConfigs = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.unspecified);
    default = {};
    description = ''
      The `app_configs.*` block from `~/nixblitz/config.json`,
      exposed for cross-plugin reads. Plugins access individual
      keys via `config.nixblitz.appConfigs.<id>.<key> or default`.
    '';
  };
}
