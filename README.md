# wsl-docker-engine

**Docker on Windows without Docker Desktop.** Use `docker` and `docker compose` from cmd / PowerShell / any terminal, just like with Docker Desktop, but with no GUI, no license restrictions and a much lighter footprint.

![From no Docker to docker run hello-world with one command](docs/demo.gif)

It installs the open-source **Docker Engine** inside WSL 2, the **official Docker CLI** for Windows, and a tiny relay that exposes the engine on `\\.\pipe\docker_engine`, the same endpoint Docker Desktop uses. Every tool that talks to Docker Desktop (the `docker` CLI, compose, buildx, VS Code, Testcontainers, SDKs) works without extra configuration.

[Español](README.es.md)

---

## Install

**Option 1: one command.** Open PowerShell (no admin needed) and paste:

```powershell
irm https://raw.githubusercontent.com/alozdev/wsl-docker-engine/main/install.ps1 | iex
```

**Option 2: double-click.** [Download the ZIP](https://github.com/alozdev/wsl-docker-engine/archive/refs/heads/main.zip), extract it and double-click **`install.cmd`**.

Then open a **new** terminal:

```
docker run --rm hello-world
```

The installer takes a few minutes the first time (it downloads Ubuntu and Docker). It handles everything:

- **If WSL is missing**, it installs it. Windows asks for administrator permission **once**. If a restart is needed, the installer **continues by itself** after you sign in again.
- **Distro:** it creates a WSL distro called `docker` (Ubuntu 24.04) and installs Docker Engine with the official script, started automatically by systemd.
- **Windows tools:** it installs `docker.exe`, `docker compose` and `docker buildx` from their official sources, checking compose and buildx against their published checksums.
- **Sign-in:** it starts Docker automatically when you sign in to Windows.
- **Check:** it tests the whole chain at the end.

### Already have some of this installed?

Run the installer anyway. It is safe to run more than once, and it only adds what is missing:

| You already have... | What the installer does |
|---|---|
| WSL | Uses it. If it is older than 2.4.4, it runs `wsl --update`. |
| A distro with the same name | Reuses it. If Docker Engine is already installed there, it is kept. |
| Your own `/etc/wsl.conf` settings | Keeps them and only adds the needed keys. A backup is saved as `wsl.conf.before-wsl-docker-engine`. |
| The Docker CLI / compose / buildx | Updates them to the latest version, and skips any that are already up to date. |
| Docker Desktop | Stops and explains why: both would fight over the same pipe. Uninstall Docker Desktop first, or use `-Force`. |
| Podman / Rancher Desktop serving `\\.\pipe\docker_engine` | Asks you to stop it first. |
| `DOCKER_HOST` set, or another `docker.exe` earlier in PATH | Warns you, because those would take priority. |

## Requirements

- Windows 10 2004+ or Windows 11, x64. **Windows Home works.**
- Virtualization enabled in BIOS/UEFI. It is on by default on most PCs.
- Internet access during install.

## How it works

```
 Windows                                         WSL 2 distro "docker" (Ubuntu)
 ───────                                         ──────────────────────────────
 docker.exe / compose / buildx / VS Code ...
        │
        ▼
 \\.\pipe\docker_engine  ◄── docker-pipe-relay.exe ── wsl.exe ── socat ──► /var/run/docker.sock
   (same pipe as Docker Desktop)                                              │
                                                                       Docker Engine (systemd)
```

Docker Desktop does the same thing internally: a Linux VM in WSL runs `dockerd`, and a Windows process connects the pipe to it. This project replaces that GUI app with:

- **`wsl/setup.sh`**: configures the distro. It enables systemd, installs Docker Engine and socat, sets up automatic security updates and maps Windows drives for compose.
- **`relay/docker-pipe-relay.cs`**: a ~250-line relay, compiled on your PC by the C# compiler that ships with Windows. No prebuilt binaries are downloaded from this repo.
- **`install.ps1` / `uninstall.ps1`**: the Windows side.

## Daily use

| | |
|---|---|
| Start | Automatic at sign-in. Any `docker` command also wakes it up. |
| Stop (frees RAM) | `wsl --terminate docker` |
| Update | Run the installer again. Docker Engine inside WSL also gets automatic security updates. |
| Shell inside the engine | `wsl -d docker` |
| Uninstall | `%LOCALAPPDATA%\Programs\wsl-docker-engine\installer\uninstall.cmd` |

The uninstaller **keeps** the distro (your containers, images and volumes) unless you run `uninstall.ps1 -RemoveDistro`.

Containers with `restart: unless-stopped` or `restart: always` come back automatically when Docker starts at sign-in.

## Good to know

- **Compose bind mounts work** (`./data:/data`, `../volume:/var/lib/...`). The installer sets `COMPOSE_CONVERT_WINDOWS_PATHS=1`, so compose turns `C:\...` into `/c/...`, and `/c` points to your C: drive inside WSL.
- **With plain `docker run -v`**, write Windows paths as `/c/Users/you/project:/app` instead of `C:\Users\...`.
- **Published ports are only reachable from your PC** (`localhost:5432`, etc.). That is safer than Docker Desktop, which publishes on all interfaces. To expose a port to your LAN, use a WSL port proxy or [mirrored networking](https://learn.microsoft.com/windows/wsl/networking).
- **Performance:** data in **named volumes** lives inside WSL and is fast. Bind mounts of Windows folders work, but disk I/O is slower, as with Docker Desktop. For databases, prefer named volumes.
- **File permissions on Windows drives:** WSL's `metadata` mount option is enabled, so images that need Linux owners/permissions (for example Postgres) work on bind-mounted Windows folders.

## Security

- **The pipe is only for you:** only your Windows user can connect, and remote/network clients are rejected (`PIPE_REJECT_REMOTE_CLIENTS` plus an explicit deny for NETWORK).
- **No impostors:** if another program already owns `\\.\pipe\docker_engine`, the relay refuses to start instead of sharing it.
- **No TCP port:** Docker is never exposed with an open TCP port (no `tcp://...:2375`).
- **Verified downloads:** compose and buildx are checked against their release checksums. Docker Engine comes from Docker's official apt repository, and the CLI from `download.docker.com` over HTTPS.
- **Automatic updates:** Ubuntu security updates and Docker Engine updates are installed automatically by `unattended-upgrades`.

Note: anyone who can run `docker` effectively has root inside the WSL distro. That is the same as with Docker Desktop.

## Troubleshooting

| Problem | Fix |
|---|---|
| `docker` not found | Open a **new** terminal (PATH changed). |
| `failed to connect to the docker API at npipe:////./pipe/docker_engine` | Run `%LOCALAPPDATA%\Programs\wsl-docker-engine\bin\docker-pipe-relay.exe`, or sign out and in again. Check `docker-pipe-relay.log` in the same folder. |
| Install fails with `0x80370102` | Enable virtualization (Intel VT-x / AMD-V) in BIOS/UEFI. |
| Docker inside WSL does not start | `wsl -d docker -u root -- systemctl status docker` |
| Want a different distro name | `.\install.ps1 -Distro mydocker` |
| Don't want autostart | `.\install.ps1 -NoStartup` |

## FAQ

**Why not just use Docker Desktop?**
It is great, but it requires a paid subscription for larger companies, runs a heavy GUI and background services, and some people simply don't want it. This gives you the same CLI experience with only open-source pieces.

**Why not Podman?**
Podman is a good option too. This project is for people who want the real Docker Engine (100% Docker behavior, BuildKit, compose) with the official CLI.

**Why not set `DOCKER_HOST=tcp://localhost:2375`?**
That opens an unauthenticated root-level port. Also, WSL's localhost forwarding breaks the streams `docker run` uses to show output, so you would not see your containers' output. The named pipe avoids both problems.

## Licenses

This project's scripts and relay are under the [MIT License](LICENSE).

The installer **downloads** these components from their official sources. It does not redistribute them:

| Component | License | Source |
|---|---|---|
| Docker Engine (Moby) | Apache-2.0 | `download.docker.com` (apt) |
| Docker CLI | Apache-2.0 | `download.docker.com` |
| Docker Compose | Apache-2.0 | `github.com/docker/compose` |
| Docker Buildx | Apache-2.0 | `github.com/docker/buildx` |
| socat | GPL-2.0 | Ubuntu archive |
| Ubuntu | Various open-source licenses | Microsoft Store / Canonical |

*Docker and the Docker logo are trademarks of Docker, Inc. This project is not affiliated with, endorsed by or sponsored by Docker, Inc. It does not use or modify Docker Desktop.*
