#!/usr/bin/env nu

# Generate nix/workspace_pubspec.lock.json from pubspec.lock.

def main [] {
    let input = "pubspec.lock"
    let output = "nix/workspace_pubspec.lock.json"

    if not ($input | path exists) {
        error make {msg: $"Input file ($input) not found"}
    }

    print $"Converting ($input) to JSON..."

    yq . $input | save --force $output

    print $"Successfully generated ($output)"
}
