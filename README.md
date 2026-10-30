# lindowin

**Headless Linux Docker for Windows.** Terminal only. No GUI. One command.

`docker run nginx` just works, on Windows 10/11 and Windows Server, even Server Core.

![From no Docker to nginx running, with one command](docs/demo.gif)

[Español](README.es.md)

## Why lindowin

- 🐧 **Real Linux containers.** `nginx`, `postgres`, `redis`... any image from Docker Hub. Even on Windows Server, where the native Docker only runs Windows containers.
- 💸 **Free for companies.** Docker Desktop needs a paid subscription for companies with more than 250 employees or more than $10M in revenue. Everything here is open source.
- 🪶 **No GUI.** No tray app, no background UI. Under 1 GB of RAM when idle, and it fits on Server Core.
- 🌐 **Ports like on Linux.** `80:80` is reachable from your network, `127.0.0.1:80:80` only from your PC. TCP and UDP.
- 🔌 **Works with your tools.** It uses the same `\.\pipe\docker_engine` as Docker Desktop, so the `docker` CLI, compose, buildx, VS Code, Testcontainers and SDKs work with no setup.
- 🔁 **Starts by itself.** At sign-in on a PC, at boot on a server (no sign-in needed).

## How it compares

| | lindowin | Docker Desktop | Native Docker on Windows Server |
|---|:---:|:---:|:---:|
| Linux images (`nginx`, `postgres`...) | ✅ | ✅ | ❌ Windows images only |
| Free for companies | ✅ | ❌ paid above 250 people / $10M | ✅ |
| Windows Server / Server Core | ✅ | ❌ not supported | ✅ |
| No GUI, starts without signing in | ✅ | ❌ | ✅ |
| Official `docker` CLI, compose, buildx | ✅ | ✅ | ✅ |

![Windows Server 2022: native Docker can't run nginx, lindowin can](docs/compare.gif)

Under the hood it installs the open-source **Docker Engine** inside WSL 2, the **official Docker CLI** for Windows, and a tiny relay between them. [How it works](#how-it-works).

---

## Install

**Option 1: one command.** Open PowerShell (no admin needed) and paste:

```powershell
irm https://raw.githubusercontent.com/alozdev/lindowin/main/install.ps1 | iex
```

**Option 2: double-click.** [Download the ZIP](https://github.com/alozdev/lindowin/archive/refs/heads/main.zip), extract it and double-click **`install.cmd`**.

Then open a **new** terminal:

```
docker run -d -p 8080:80 nginx
```

Then open http://localhost:8080 in your browser.

The installer takes a few minutes the first time (it downloads Ubuntu and Docker). It handles everything:

- **If WSL is missing**, it installs it. If a restart is needed, the installer **continues by itself** after you sign in again.
- **Distro:** it creates a WSL distro called `docker` (Ubuntu 24.04) and installs Docker Engine with the official script, started automatically by systemd.
- **Windows tools:** it installs `docker.exe`, `docker compose` and `docker buildx` from their official sources, checking compose and buildx against their published checksums.
- **Ports:** published ports work [like on Linux](#published-ports): `80:80` is reachable from your network, `127.0.0.1:80:80` only from your PC.
- **Autostart:** it starts Docker when you sign in to Windows (on [Windows Server](#windows-server), at boot).
- **Check:** it tests the whole chain at the end.

Windows asks for **administrator permission once**, to create the `docker-users` group, the start task and the service that opens published ports. If you say no, Docker still works, only from your PC and without autostart.

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
- Or Windows Server 2022 / 2025, with or without desktop (Server Core works). See [Windows Server](#windows-server).
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
- **`relay/docker-pipe-relay.cs`**: a ~300-line relay, compiled on your PC by the C# compiler that ships with Windows. No prebuilt binaries are downloaded from this repo.
- **`ports/docker-port-sync.cs`**: a small service that watches your containers and opens or closes the firewall for their published ports, so they behave like on Linux. Also compiled on your PC.
- **`install.ps1` / `uninstall.ps1`**: the Windows side.

## Daily use

| | |
|---|---|
| Start | Automatic at sign-in (at boot on Windows Server). Any `docker` command also wakes it up. |
| Stop (frees RAM) | `wsl --terminate docker` |
| Update | Run the installer again. Docker Engine inside WSL also gets automatic security updates. |
| Shell inside the engine | `wsl -d docker` |
| Uninstall | See [Uninstall](#uninstall) |

Containers with `restart: unless-stopped` or `restart: always` come back automatically when Docker starts.

## Published ports

Ports follow your `docker-compose.yml` / `docker run -p` exactly, as on a Linux server. Nothing new to learn:

| You write | Reachable from |
|---|---|
| `80:80` | Your PC **and your network** (TCP) |
| `127.0.0.1:80:80` | **Only your PC** |
| `192.168.1.20:80:80` | That network IP only |
| `53:53/udp` | Your PC and your network (UDP) |

When a container starts, its ports are opened in the Windows firewall; when it stops or is removed, they are closed again. Only for ports you published, nothing else.

> **Tip:** databases and admin panels (Postgres, Redis, ...) usually don't need to be on your network. Publish them as `127.0.0.1:5432:5432`.

**How it is done.** The installer turns on WSL's *mirrored networking* (Windows 11 22H2+ / Server 2025), which makes ports behave exactly like on Linux. It then checks that WSL still has internet. On some PCs (certain VPNs or network drivers) it doesn't; in that case it goes back to your previous setting and uses *port forwarding* instead. It all happens automatically.

| | Mirrored (preferred) | Port forwarding (fallback) |
|---|---|---|
| `80:80`, `127.0.0.1:80:80` | ✅ | ✅ |
| Specific IP (`192.168.1.20:80:80`) | ✅ | ⚠️ Not reachable from the network; use `80:80` |
| UDP | ✅ | ✅ |

Your original `.wslconfig` is backed up and restored when you uninstall.

## Windows Server

Same installer, same commands. It detects Windows Server by itself and the only difference is: **Docker starts at boot, without anyone signing in** (like the Docker service on Linux). Containers with `restart: always` / `unless-stopped` come back after a reboot.

```powershell
irm https://raw.githubusercontent.com/alozdev/lindowin/main/install.ps1 | iex
```

- Works on **Server Core** (no desktop): everything runs from PowerShell.
- **Virtual machines:** enable nested virtualization on the host (Hyper-V: `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true`).
- **Server 2022** has no mirrored networking, so it uses port forwarding (see the table above). Server 2025 uses mirrored.
- Want the at-boot behavior on a normal PC? `.\install.ps1 -Server`.
- Other users who should run `docker`: add them to the `docker-users` group (`Add-LocalGroupMember docker-users <user>`), as with Docker Desktop.

## Uninstall

The uninstaller lives in `%LOCALAPPDATA%\Programs\wsl-docker-engine\installer\`. Pick one:

| I want to... | Run |
|---|---|
| **Remove everything**, including Docker Engine and all containers, images and volumes | `uninstall.cmd -RemoveDistro` (asks you to type the distro name to confirm) |
| Remove only the Windows side and **keep the engine** with all its data | Double-click `uninstall.cmd` |
| Remove the Windows side **and** the engine, without the confirmation prompt | `uninstall.cmd -RemoveDistro -Yes` |

From PowerShell you can also run it directly:

```powershell
& "$env:LOCALAPPDATA\Programs\wsl-docker-engine\installer\uninstall.ps1" -RemoveDistro
```

What gets removed from Windows: `docker.exe`, the compose/buildx plugins it installed, the pipe relay, the start task, the port service with every firewall / port-forwarding rule it created, the `docker-users` group (only if it created it), the PATH / environment changes, and your original `.wslconfig` is restored. Plugins you installed yourself are left alone. Windows asks for administrator permission once.

**Before removing the distro:**

- **Stop your apps first.** Run `docker compose down` in each project so databases shut down cleanly.
- **Bind-mounted data is safe.** Folders from Windows, like `./data`, live on your Windows disk and are never touched.
- **Named volumes are deleted.** They live inside the distro. Back them up first if you need them, for example with `docker run --rm -v myvol:/v -v /c/backup:/b alpine tar czf /b/myvol.tgz -C /v .`.
- **Reinstalling is easy.** Run the installer again, then `docker compose up -d` in each project. Bind-mounted data comes back as it was.

## Good to know

- **Compose bind mounts work** (`./data:/data`, `../volume:/var/lib/...`). The installer sets `COMPOSE_CONVERT_WINDOWS_PATHS=1`, so compose turns `C:\...` into `/c/...`, and `/c` points to your C: drive inside WSL.
- **With plain `docker run -v`**, write Windows paths as `/c/Users/you/project:/app` instead of `C:\Users\...`.
- **Performance:** data in **named volumes** lives inside WSL and is fast. Bind mounts of Windows folders work, but disk I/O is slower, as with Docker Desktop. For databases, prefer named volumes.
- **File permissions on Windows drives:** WSL's `metadata` mount option is enabled, so images that need Linux owners/permissions (for example Postgres) work on bind-mounted Windows folders.

## Security

- **Who can use Docker:** only your Windows user and members of the local `docker-users` group (like Docker Desktop). Remote/network clients are rejected (`PIPE_REJECT_REMOTE_CLIENTS` plus an explicit deny for NETWORK).
- **Ports are opened only for what you publish,** and closed when the container stops. Ports bound to `127.0.0.1` are never opened.
- **The port service runs as SYSTEM** (it needs to change the firewall). It is compiled into `Program Files`, where normal users cannot replace it, and it only reads from Docker.
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
| A published port is not reachable from the network | Check `C:\ProgramData\wsl-docker-engine\port-sync.log`. If you skipped the admin prompt, run the installer again and accept it. |
| WSL lost internet after installing | Run the installer with `-NetworkMode portproxy` (VPNs can break mirrored networking). |
| Only want ports on your PC | `.\install.ps1 -NetworkMode local` |
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
