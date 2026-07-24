# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/) and Semantic Versioning.

## [Unreleased]

## [0.1.1] - 2026-07-24

### Added

- `vpf` shortcut for opening the interactive management menu.
- Installed-version detection with upgrade, reinstall, uninstall, and cancel flows.
- Non-interactive version actions through installer flags.

### Fixed

- Release the configuration lock before starting systemd/OpenRC, preventing the installer from deadlocking its own service process.
- Reattach piped remote installers to `/dev/tty` for version-selection prompts.

## [0.1.0] - 2026-07-24

### Added

- Initial Bash CLI and interactive menu.
- Isolated nftables NAT and filter tables.
- TCP, UDP, BOTH and three Masquerade modes.
- Ubuntu, Debian, Alpine, systemd, and OpenRC installation paths.
- Atomic configuration, backup/restore, dry-run, diagnostics, and tests.
