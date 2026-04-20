# NixBlitz

NixBlitz is a comprehensive toolkit for managing NixOS environments, with a particular focus on the RaspiBlitz project. It provides a command-line interface (CLI), a web-based user interface, and a set of engines for installation and system management.

The project is structured as a monorepo containing several Rust crates, each with a specific responsibility.

## Components

### `nixblitz_cli`

The primary entry point for users is the `nixblitz_cli`, an interactive terminal user interface (TUI) for managing NixBlitz environments. It provides a guided, user-friendly experience for the entire installation and management process.

### `nixblitz_norupo`

`nixblitz_norupo` is a web-based user interface for NixBlitz, built with the Dioxus framework. It offers a graphical alternative to the CLI for managing the system.

### `nixblitz_installer_engine`

The `nixblitz_installer_engine` is a web server that handles the installation process. It communicates with the frontend (CLI or web UI) over WebSockets to provide real-time updates and guidance during installation.

### `nixblitz_system_engine`

Similar to the installer engine, the `nixblitz_system_engine` is a web server responsible for managing the system after installation. It provides an API for the frontend to interact with and control the NixOS environment.

### `nixblitz_core`

This crate contains the core data structures, error handling, and other shared functionality used by the other components of the NixBlitz toolkit.

### `nixblitz_system`

The `nixblitz_system` crate provides the low-level functionality for interacting with the underlying NixOS system. This includes managing Nix configurations, gathering system information, and performing other system-level operations.

## Development

The project uses Nix flakes for dependency management and to provide a consistent development environment. The `flake.nix` file at the root of the repository defines the development shell, which includes all the necessary tools and dependencies for building and testing the project.
