# Changelog

All notable changes to lindowin. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Website at [alozdev.github.io/lindowin](https://alozdev.github.io/lindowin/), with the installer at `/install`.

### Changed
- Repository layout: internal pieces moved to `src/`, README images to `assets/`. Installing and uninstalling work the same.

## [1.1.0] - 2026-10-30

### Added
- Windows Server and Server Core support. Detected automatically; Docker starts at boot without anyone signing in. `-Server` does the same on a PC.
- Published ports work like on Linux: `80:80` is reachable from the network, `127.0.0.1:80:80` only from the PC, TCP and UDP. Firewall rules open when a container starts and close when it stops.
- WSL mirrored networking, with automatic fallback to port forwarding when mirrored breaks internet (some VPNs).
- `docker-users` group, like Docker Desktop.

### Changed
- The project is now **lindowin** (formerly wsl-docker-engine). Old links redirect.
- One administrator prompt at install time, none afterwards.
- Autostart uses a scheduled task instead of a Startup folder script.

## [1.0.0] - 2026-10-30

### Added
- First release: Docker Engine in WSL 2 plus the official Docker CLI, compose and buildx for Windows, set up with one command.
- Relay that serves `\.\pipe\docker_engine`, the same endpoint as Docker Desktop.
- Automatic start at sign-in, safe re-runs, clean uninstall.

[Unreleased]: https://github.com/alozdev/lindowin/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/alozdev/lindowin/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/alozdev/lindowin/releases/tag/v1.0.0
