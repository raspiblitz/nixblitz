set shell := ["nu", "-c"]

set positional-arguments

# Lists available commands
default:
	just --list

# Run all Dart tests
test trace="":
  #!/usr/bin/env nu
  if ("{{trace}}" == "-t" or "{{trace}}" == "--trace") {
    cd common
    $env.DART_VM_OPTIONS = "--enable-asserts"
    dart test
  } else if ("{{trace}}" == "") {
    cd common
    dart test
  } else {
    print "Unknown argument '{{trace}}'. Pass '-t' for verbose or nothing for default."
  }

# Run dart analyze on all packages
analyze:
  #!/usr/bin/env nu
  cd common; dart analyze
  cd ../tui; dart analyze

# Format all Dart code
format:
  dart format .

# Run the TUI
run:
  cd tui; dart run bin/nixblitz.dart

# Run the dev TUI (separate entry point with widget/view demos)
run-dev:
  cd tui; dart run bin/nixblitz_dev.dart

# Generate Nix lock files from pubspec.lock
gen-locks: gen-workspace-lock gen-workspace-graph

# Generate workspace pubspec lock JSON for Nix
gen-workspace-lock:
  nu scripts/gen_workspace_lock.nu

# Generate workspace dependency graph JSON for Nix
gen-workspace-graph:
  python3 scripts/gen_workspace_graph.py

# Regenerate embedded templates from templates/ directory
gen-templates:
  dart run scripts/gen_embedded_templates.dart

# Boot a NixOS ISO in QEMU for testing the installer
vm-boot:
  #!/usr/bin/env nu
  # let iso = "/home/f44/Downloads/nixos-graphical-25.11.6561.1267bb4920d0-x86_64-linux.iso"
  let iso = "/home/f44/Downloads/nixos-minimal-25.11.9418.c7f47036d3df-x86_64-linux.iso"

  if not ($iso | path exists) {
    print $"ISO not found at ($iso)"
    exit 1
  }

  if not ('nixblitz-disk.qcow2' | path exists) {
    print "Creating 150G disk image 'nixblitz-disk.qcow2'..."
    qemu-img create -f qcow2 nixblitz-disk.qcow2 150G
  }

  print "Booting NixOS installer VM..."
  print "  SSH: ssh -p 10022 nixos@localhost"
  print "  Disk: nixblitz-disk.qcow2 (virtio)"
  (qemu-system-x86_64 -enable-kvm -m 8192 -smp 4
    -netdev user,id=mynet0,hostfwd=tcp::10022-:22
    -device virtio-net-pci,netdev=mynet0
    -drive file=nixblitz-disk.qcow2,if=none,id=virtio0,format=qcow2
    -device virtio-blk-pci,drive=virtio0
    -cdrom $iso)

# Boot the installed system from the qcow2 disk (no ISO)
vm-run:
  #!/usr/bin/env nu
  if not ('nixblitz-disk.qcow2' | path exists) {
    print "Disk image 'nixblitz-disk.qcow2' not found. Run 'just vm-boot' first."
    exit 1
  }

  print "Booting installed NixOS VM..."
  print "  SSH: ssh -p 10022 admin@localhost"
  (qemu-system-x86_64 -enable-kvm -m 8192 -smp 4
    -netdev user,id=mynet0,hostfwd=tcp::10022-:22
    -device virtio-net-pci,netdev=mynet0
    -drive file=nixblitz-disk.qcow2,if=none,id=virtio0,format=qcow2
    -device virtio-blk-pci,drive=virtio0)

# Deploy unwrapped nixblitz binary to VM for quick testing (no disko)
vm-deploy:
  #!/usr/bin/env nu
  let unwrapped = (nix build .#nixblitz-unwrapped --print-out-paths | str trim)
  print $"Deploying ($unwrapped)/bin/nixblitz-bin to VM..."
  ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no nixos@localhost -p 10022 'rm -f /tmp/nixblitz; rm -rf ~/nixblitz; rm -f ~/nixblitz.log'
  scp -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no -P 10022 $"($unwrapped)/bin/nixblitz-bin" nixos@localhost:/tmp/nixblitz
  print "Deployed. Run on VM: /tmp/nixblitz"
  print "For full install test (with disko), run on the VM instead:"
  print "  nix run git+https://forge.f44.fyi/f44/nixblitz_ng"

# SSH into the installer VM (live ISO)
vm-ssh-installer:
  ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no nixos@localhost -p 10022

# SSH into the installed VM
vm-ssh:
  ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no admin@localhost -p 10022

# Delete the disk image to start fresh
vm-clean:
  rm -f nixblitz-disk.qcow2
