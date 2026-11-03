# Changelog

All notable changes to lindowin. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.2] - 2026-11-03

### Fixed
- Apps that connect to `localhost` could hang: Windows tries `::1` first, and WSL cannot pass IPv6 loopback to Linux. lindowin now lowers only `::1` in Windows' address preference table (if it still has its default), so `localhost` tries `127.0.0.1` first while other IPv6 traffic is unchanged. Uninstalling restores it.

### Added
- `AGENTS.md` (and `CLAUDE.md`) with the project rules for AI coding agents.

## [1.2.1] - 2026-11-02

### Fixed
- Windows Smart App Control could block the relay or the port service the first time a new build ran, so an update could end with "the Windows CLI could not reach it". They are now rebuilt only when their code changes, and the installer, `lindowin start` and `lindowin status` retry and explain it when Windows blocks a first run.

### Added
- Install with Scoop: `scoop bucket add alozdev https://github.com/alozdev/scoop-bucket` then `scoop install lindowin`.

## [1.2.0] - 2026-11-02

### Added
- Website at [lindowin.dev](https://lindowin.dev), with a short install command: `irm https://lindowin.dev/install | iex`.
- Logo.
- **Idle sleep:** after 5 minutes with no containers running, the Linux VM stops and its memory goes back to Windows. The next `docker` command wakes it, with a Windows notification. On by default on PCs, off when Docker starts at boot (servers).
- **`lindowin` command:** `status`, `update` (latest version, keeps your settings), `config` (`idle-sleep on|off`, `start-at boot|signin`, `share all-users|me`, `network mirrored|nat|local`), `start`, `stop`, `uninstall [--all]`.
- Installer options `-StartAt boot|signin` and `-IdleSleep on|off`. Your choices are remembered on updates.
- **Shared install for all users** (`-AllUsers`): programs in Program Files and the machine PATH, Docker starts at boot, and every member of `docker-users` can use it (like the `docker` group on Linux). Per-user stays the default.
- Faster start: Docker uses the nftables firewall (its start-up drops from ~4.5 s to ~1 s) and the distro no longer starts services a Docker-only system never uses (snapd, cloud-init, Landscape, apport...): Linux boots in ~2.6 s instead of ~7 s.
- Lighter Linux: system journal limited to 64 MB, duplicate logger (rsyslog) turned off, package downloads cleaned.
- **Clear warnings** where Docker's own error is confusing on Windows:
  - a port on a specific IP without mirrored networking, or a port already used by a Windows program: one extra line in Docker's error says why and how to fix it;
  - WSL started without network (mirrored networking can fail with some VPNs): restarted once automatically when nothing is running, otherwise a notification;
  - another Docker (Docker Desktop, Podman...) took the Docker pipe: a notification says which one.
  - Docker lost a network's setup, or a Windows path in `docker run -v C:\...`: the error says how to fix it.
  - less than 2 GB free on the drive that holds Docker's disk: a notification (once a day).
  - `lindowin status` shows these, plus disk usage, missing `docker-users` membership and new lindowin versions.
- **Update notices:** once a day lindowin checks for a new lindowin or Docker CLI version and shows a notification (once per version) and a line in `lindowin` commands. Nothing is installed without you: run `lindowin update`.
- **Docker updates no longer stop your containers:** Docker Engine updates itself inside Linux, and `live-restore` keeps running containers going while it does (skipped with Docker Swarm). `lindowin stop` still shuts containers down cleanly.
- **`lindowin compact`:** gives the space of deleted images and volumes back to Windows (WSL never shrinks its disk by itself). lindowin tells you when more than 5 GB can be given back.

### Changed
- The relay only checks the WSL IP in port-forwarding mode (fewer CPU wake-ups).
- The port rules service never wakes a stopped Docker.
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

[Unreleased]: https://github.com/alozdev/lindowin/compare/v1.2.2...HEAD
[1.2.2]: https://github.com/alozdev/lindowin/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/alozdev/lindowin/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/alozdev/lindowin/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/alozdev/lindowin/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/alozdev/lindowin/releases/tag/v1.0.0
