# Contributing to lindowin

Thanks for helping! Bug reports, tests on other Windows versions and pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/alozdev/lindowin/issues/new/choose) and include:

- Windows edition and build (`winver`), and whether it is a PC or Windows Server.
- WSL version (`wsl --version`).
- The installer output, and these logs if they exist:
  - `%LOCALAPPDATA%\Programs\wsl-docker-engine\bin\docker-pipe-relay.log`
  - `C:\ProgramData\wsl-docker-engine\port-sync.log`

Please remove anything private (user names, IPs, hostnames) before posting.

## Security issues

Do not open a public issue. See [SECURITY.md](SECURITY.md).

## Project layout

| Path | What it is |
|---|---|
| `install.ps1`, `install.cmd` | Installer (what users run) |
| `uninstall.ps1`, `uninstall.cmd` | Uninstaller |
| `src/wsl/setup.sh` | Configures the WSL distro and installs Docker Engine |
| `src/relay/` | Named pipe relay (`\.\pipe\docker_engine`), compiled on the user's PC |
| `src/ports/` | Service that opens/closes firewall rules for published ports |
| `src/system-setup.ps1` | The part that runs as administrator (tasks, group, rules) |
| `assets/` | README images and the script that renders them |
| `website/` | The website, published with GitHub Pages |

## Pull requests

1. Keep `.ps1` files ASCII-only: Windows PowerShell 5.1 misreads UTF-8 without a BOM.
2. Make it safe to run twice: the installer must skip what is already done.
3. Never download prebuilt binaries from this repo: C# code is compiled on the user's PC.
4. Test on a clean Windows if you can (Windows Sandbox does not support WSL; a VM with nested virtualization does).
5. Add a line to `CHANGELOG.md` under **Unreleased**.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
