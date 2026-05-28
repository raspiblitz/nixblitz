# Test fixture — stands in for the `nixos-generate-config` output
# that install writes to ~/nixblitz/. The host module imports it
# unconditionally; for an eval-only config check it can be empty,
# because disko (enabled by installed.nix for platform x86)
# generates fileSystems + sets boot.loader.grub. See
# docs/superpowers/specs/2026-05-19-config-channel-verification-design.md.
{...}: {}
