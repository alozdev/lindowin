# AGENTS.md

Instructions for AI coding agents (Codex, Copilot, Cursor, Claude Code, Gemini, ...) working on lindowin.
Humans: see [CONTRIBUTING.md](CONTRIBUTING.md).

## What this is

lindowin installs the real Docker Engine on Windows without Docker Desktop: a WSL2 distro
named `docker` (Ubuntu + systemd + Docker Engine), the Windows `docker` CLI, and a small relay
that exposes `\\.\pipe\docker_engine`. Terminal only, no GUI, works on Windows 10/11 and Windows Server.

## Repo map

| Path | What it is |
|---|---|
| `install.ps1` | The installer users run (`irm https://lindowin.dev/install \| iex`). Holds `$Version`. |
| `uninstall.ps1` | Uninstaller (the official way is `lindowin uninstall`, which calls it) |
| `src/lindowin.ps1` | The `lindowin` command: status, update, config, start, stop, compact, uninstall |
| `src/system-setup.ps1` | The only part that runs as administrator (tasks, `docker-users` group, port service) |
| `src/relay/docker-pipe-relay.cs` | Named pipe relay, idle sleep, error hints, update/compact checks |
| `src/ports/docker-port-sync.cs` | SYSTEM service that syncs firewall/port rules for published ports |
| `src/wsl/setup.sh` | Configures the WSL distro and installs Docker Engine |
| `assets/make-demo-gif.py` | Renders the GIFs, banners, wordmarks and social preview |
| `website/` | lindowin.dev, deployed by `.github/workflows/pages.yml` (also serves `/install`) |

## Rules that must not be broken

- **PowerShell 5.1 compatible and ASCII-only `.ps1` files.** No `??`, `?.`, ternaries, `&&`/`||`,
  `-AsHashtable`. PS 5.1 misreads UTF-8 without a BOM, so no accents, emoji or smart quotes.
- **Idempotent.** Running the installer twice must skip what is already done and respect
  dependencies the user already has (WSL, distro, Docker, CLI plugins).
- **Ask for administrator permission once** per install, through `src/system-setup.ps1`. Do not add new elevation prompts.
- **No GUI.** Everything must work on Windows Server Core. Toast notifications are fine only
  when they need no UI and are skipped where unsupported.
- **Ports follow the compose file exactly** on PCs and servers. Mirrored networking first;
  portproxy only as fallback. Never remap ports.
- **`-Server` only changes start-at-boot.** Idle sleep defaults: on for PCs, off for servers.
- **C# is compiled on the user's PC** with the .NET Framework 4 `csc.exe`. Never ship or download prebuilt binaries.
- **Rebuild only when the source changes.** The relay and port service use `*.source.sha256`
  stamp files. Every new build is an unsigned program Windows Smart App Control has never seen and
  may block (Code Integrity event 3033). Do not remove the stamps or force rebuilds.
- **`lindowin update` only updates.** Settings change through `lindowin config`.
- **Switching modes must not require a new terminal.** The user should be able to keep typing.
- **`lindowin uninstall` is the official uninstall.** The Scoop manifest only calls it when `$cmd -eq 'uninstall'`.

## Line endings

`.gitattributes` decides them: `.sh` LF; `.ps1`, `.cmd`, `.cs` CRLF. Keep them, or `setup.sh` breaks inside Linux.

## How to check your change

- Relay: `& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /optimize /r:System.Core.dll /r:System.Management.dll /out:$env:TEMP\relay.exe src\relay\docker-pipe-relay.cs`
- Port service: same compiler with `/r:System.Core.dll /r:System.Web.Extensions.dll` and `src\ports\docker-port-sync.cs`.
- PowerShell syntax: `[System.Management.Automation.Language.Parser]::ParseFile(...)` with no errors, in Windows PowerShell 5.1.
- Shell: `bash -n src/wsl/setup.sh`.
- Real test: run `install.ps1` twice (the second run must skip work), then `lindowin status`,
  `docker run --rm hello-world` and `docker run -d -p 8080:80 nginx`.
  Windows Sandbox has no WSL; use a VM with nested virtualization.

## Releasing

1. Bump `$Version` in `install.ps1` and add a section to `CHANGELOG.md`.
2. Tag `vX.Y.Z` and publish a GitHub release.
3. Update the Scoop bucket (`alozdev/scoop-bucket`, `bucket/lindowin.json`): `version`, `url`,
   `hash` (SHA256 of the tag zip) and `extract_dir`.
4. The website and the demo GIFs update through their workflows.

## Commits and pull requests

- **Do not add `Co-Authored-By` lines or any AI attribution** (no "Generated with ..." footers)
  to commits or pull requests.
- Do not add yourself or any bot as a collaborator, author or maintainer.
- Short commit messages in English, imperative mood. Add a line under **Unreleased** in `CHANGELOG.md`.

## Privacy and security

- Never commit personal data: user names, home paths, emails, IPs, hostnames, tokens or keys.
  Use placeholders like `C:\Users\<you>` in docs and examples.
- Do not weaken the security defaults (the pipe only for the user and `docker-users`, no TCP API, firewall
  rules only for published ports, the relay refuses to start if another program owns the pipe, nothing auto-installs).
- Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in public issues.

## Docs and numbers

- Benchmarks show only measured numbers, with no invented margins. Results where Docker Desktop
  wins stay in the docs, with the reason.
- `README.md` and `README.es.md` must stay in sync. User-facing messages: short, plain, actionable.
