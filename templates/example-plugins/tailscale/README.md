# nixblitz-tailscale

Dogfood plugin for the NixBlitz plugin system (Phase 1). Enables
Tailscale (`services.tailscale.enable = true`) so a node can join
a tailnet.

This plugin lives in-tree at `templates/example-plugins/tailscale/`
until the plugin fetch + install path is proven end-to-end. Once
stable, publish to a standalone repo
(`forge.f44.fyi/f44/nixblitz-tailscale`) and remove this copy.

## Install (dev loop)

```bash
# One-time: seed a local git repo so `git clone` works.
cd templates/example-plugins/tailscale
git init -b main
git add -A
git commit -m initial
cd -

# Install against the local copy (file:// needs --insecure).
nixblitz plugin add \
  "file://$(realpath templates/example-plugins/tailscale)" \
  --insecure -y

# Then run Apply in the TUI to commit + `nixos-rebuild switch`.
```

## After install

`sudo tailscale up` on the node to authenticate.
