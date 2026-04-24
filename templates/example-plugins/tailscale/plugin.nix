{
  # Minimal tailscale dogfood for NixBlitz plugin system Phase 1.
  # Enables the tailscaled daemon and ships the `tailscale` CLI.
  # After rebuild, run `sudo tailscale up` on the node to join a
  # tailnet.
  services.tailscale.enable = true;
}
