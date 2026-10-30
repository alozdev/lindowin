<#
.SYNOPSIS
  lindowin: headless Linux Docker for Windows. Installs Docker Engine on WSL 2
  and the official Docker CLI on Windows,
  with no Docker Desktop and no GUI.

.DESCRIPTION
  - Creates (or reuses) a WSL distro with Docker Engine, started by systemd.
  - Installs docker.exe, docker compose and docker buildx for Windows
    (official downloads, checksums verified).
  - Exposes Docker on \\.\pipe\docker_engine, like Docker Desktop, so "docker"
    works from cmd/PowerShell with no DOCKER_HOST and no open TCP port.
  - Published ports behave like on Linux: "80:80" is reachable from the network,
    "127.0.0.1:80:80" only from this PC, TCP and UDP.
  - Starts automatically: at sign-in on PCs, at boot (no sign-in needed) on
    Windows Server.

  Safe to run again: it skips what is already installed and updates the rest.
  Asks for administrator permission once (firewall rules, start task).

.EXAMPLE
  irm https://raw.githubusercontent.com/alozdev/lindowin/main/install.ps1 | iex

.EXAMPLE
  .\install.ps1 -Server
#>
[CmdletBinding()]
param(
    # Name of the WSL distro that runs Docker Engine (created if missing)
    [string]$Distro = "docker",
    # Where the Windows files are installed
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\wsl-docker-engine"),
    # Start Docker at boot without anyone signing in (automatic on Windows Server)
    [switch]$Server,
    # How published ports reach the network. "auto": mirrored if it works, otherwise portproxy.
    # "local": only this PC (no admin rules for ports).
    [ValidateSet("auto", "mirrored", "portproxy", "local")]
    [string]$NetworkMode = "auto",
    # Do not start Docker automatically
    [switch]$NoStartup,
    # Continue even if Docker Desktop or another Docker pipe is detected
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # makes Invoke-WebRequest much faster on PowerShell 5
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$env:WSL_UTF8 = "1"                       # wsl.exe prints UTF-8 instead of UTF-16

$Repo = "alozdev/lindowin"
$UbuntuImage = "Ubuntu-24.04"

function Write-Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "    $msg" }
function Write-Warn($msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }
$StopMarker = "wsl-docker-engine: install stopped"
function Stop-Install($msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    throw $StopMarker
}

function Invoke-Download {
    # Invoke-WebRequest with retries (flaky networks, VPNs)
    param([string]$Uri, [string]$OutFile)
    for ($i = 1; ; $i++) {
        try {
            if ($OutFile) { Invoke-WebRequest -UseBasicParsing $Uri -OutFile $OutFile; return }
            return Invoke-WebRequest -UseBasicParsing $Uri
        } catch {
            if ($i -ge 4) { Stop-Install "Download failed: $Uri`n       $($_.Exception.Message)" }
            Write-Info "Network problem, retrying ($i/3)..."
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

function Invoke-Native {
    # Runs a program and returns exit code + output as text.
    # (On PowerShell 5, redirecting stderr with ErrorAction=Stop would abort the script.)
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = "Continue"
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", "" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n").Trim() }
}

function Invoke-Wsl {
    param([string[]]$Arguments)
    return Invoke-Native "wsl.exe" $Arguments
}

function Test-WslReady {
    try { return (Invoke-Wsl @("--version")).Code -eq 0 } catch { return $false }
}

function Start-TempKeepAlive($name) {
    # WSL shuts an idle distro down after a few seconds, killing running containers.
    # Keep it alive while the installer works (the process ends by itself).
    Start-Process wsl.exe -ArgumentList "-d $name -u root -- sleep 900" -WindowStyle Hidden
}

function Wait-DockerActive($name) {
    for ($i = 0; $i -lt 30; $i++) {
        if ((Invoke-Wsl @("-d", $name, "-u", "root", "--", "systemctl", "is-active", "docker")).Text -eq "active") { return }
        Start-Sleep 2
    }
    Stop-Install "Docker did not start inside WSL. Check with: wsl -d $name -u root -- systemctl status docker"
}

function Stop-DockerGracefully($name) {
    # Running containers get SIGTERM and can shut down properly (databases!)
    Invoke-Wsl @("-d", $name, "-u", "root", "--", "sh", "-c", "systemctl stop docker.service docker.socket >/dev/null 2>&1 || true") | Out-Null
}

function Restart-Wsl($name) {
    # .wslconfig changes need a full WSL restart (all distros)
    Stop-DockerGracefully $name
    Get-Process docker-pipe-relay -ErrorAction SilentlyContinue | Stop-Process -Force
    Invoke-Wsl @("--shutdown") | Out-Null
    Start-Sleep 2
    Start-TempKeepAlive $name
    Wait-DockerActive $name
}

function Test-WslInternet($name) {
    for ($i = 0; $i -lt 3; $i++) {
        $r = Invoke-Wsl @("-d", $name, "-u", "root", "--", "curl", "-fsS", "-m", "10", "-o", "/dev/null", "https://download.docker.com/")
        if ($r.Code -eq 0) { return $true }
        Start-Sleep 3
    }
    return $false
}

function Get-WslNetworkingMode {
    $f = Join-Path $env:USERPROFILE ".wslconfig"
    if (-not (Test-Path $f)) { return "nat" }
    $section = ""
    foreach ($line in Get-Content $f) {
        if ($line -match "^\s*\[(.+)\]\s*$") { $section = $Matches[1].Trim().ToLower(); continue }
        if ($section -eq "wsl2" -and $line -match "^\s*networkingMode\s*=\s*(\w+)") { return $Matches[1].ToLower() }
    }
    return "nat"
}

function Set-WslConfigValue($sectionName, $key, $value) {
    # Sets [section] key=value in .wslconfig, keeping the user's other settings.
    # Returns $true if the file changed.
    $f = Join-Path $env:USERPROFILE ".wslconfig"
    $lines = if (Test-Path $f) { @(Get-Content $f) } else { @() }
    $out = New-Object System.Collections.Generic.List[string]
    $section = ""; $seen = $false; $done = $false
    foreach ($line in $lines) {
        if ($line -match "^\s*\[(.+)\]\s*$") {
            if ($section -eq $sectionName -and -not $done) { $out.Add("$key=$value"); $done = $true }
            $section = $Matches[1].Trim().ToLower()
            if ($section -eq $sectionName) { $seen = $true }
            $out.Add($line); continue
        }
        if ($section -eq $sectionName -and $line -match "^\s*$key\s*=") {
            if (-not $done) { $out.Add("$key=$value"); $done = $true }
            continue
        }
        $out.Add($line)
    }
    if (-not $done) {
        if (-not $seen) { if ($out.Count -gt 0) { $out.Add("") }; $out.Add("[$sectionName]") }
        $out.Add("$key=$value")
    }
    if (($lines -join "`n") -eq ($out -join "`n")) { return $false }
    [IO.File]::WriteAllLines($f, $out)
    return $true
}

function Set-WslNetworkingMode($value) { Set-WslConfigValue "wsl2" "networkingMode" $value | Out-Null }

function Select-NetworkMode($name, $requested, $config) {
    # Returns "mirrored", "portproxy" or "local"
    if ($requested -eq "local") { return "local" }
    $current = Get-WslNetworkingMode
    $supported = [Environment]::OSVersion.Version.Build -ge 22621   # Windows 11 22H2+ / Server 2025
    $wslconfig = Join-Path $env:USERPROFILE ".wslconfig"
    $backup = Join-Path $InstallDir "wslconfig.original"
    $noFile = Join-Path $InstallDir "wslconfig.original.none"

    if ($requested -eq "portproxy" -or -not $supported -or ($requested -eq "auto" -and $config.mirroredFailed)) {
        if ($requested -eq "mirrored") { Write-Warn "Mirrored networking needs Windows 11 22H2+ or Windows Server 2025. Using portproxy." }
        if ($current -eq "mirrored") {
            if ((Test-Path $backup) -or (Test-Path $noFile)) {
                # We turned mirrored on before: put the user's original file back
                if (Test-Path $noFile) { Remove-Item $wslconfig -Force; Remove-Item $noFile -Force } else { Move-Item $backup $wslconfig -Force }
                Write-Info "Restarting WSL to switch back to its default network (other WSL distros restart too)..."
                Restart-Wsl $name
            } else {
                Write-Info "Your .wslconfig already uses mirrored networking: keeping it."
                return "mirrored"
            }
        }
        return "portproxy"
    }

    if (-not (Test-Path $backup) -and -not (Test-Path $noFile)) {
        if (Test-Path $wslconfig) { Copy-Item $wslconfig $backup } else { New-Item -ItemType File $noFile | Out-Null }
    }
    $changed = Set-WslConfigValue "wsl2" "networkingMode" "mirrored"
    # Lets this PC reach published ports through its own network IP too (like on Linux)
    if (Set-WslConfigValue "experimental" "hostAddressLoopback" "true") { $changed = $true }
    if ($changed) {
        Write-Info "Enabling WSL mirrored networking (other WSL distros restart too)..."
        Restart-Wsl $name
    }
    if (Test-WslInternet $name) { return "mirrored" }

    # Mirrored breaks networking on some PCs (VPNs, some network drivers): go back
    Write-Warn "WSL had no internet with mirrored networking (common with some VPNs). Switching to portproxy."
    if (Test-Path $noFile) { Remove-Item $wslconfig -Force -ErrorAction SilentlyContinue; Remove-Item $noFile -Force }
    elseif (Test-Path $backup) { Move-Item $backup $wslconfig -Force }
    else { Set-WslNetworkingMode "nat" }
    Restart-Wsl $name
    $config.mirroredFailed = $true
    return "portproxy"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SystemSetup([string[]]$Arguments) {
    # Runs system-setup.ps1 as administrator (one Windows permission prompt)
    $script = Join-Path $InstallDir "installer\system-setup.ps1"
    $result = Join-Path $script:TempDir "system-setup.result"
    $all = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"") + $Arguments + @("-ResultFile", "`"$result`"")
    try {
        if (Test-IsAdmin) {
            Start-Process powershell.exe -ArgumentList $all -WindowStyle Hidden -Wait
        } else {
            Start-Process powershell.exe -ArgumentList $all -Verb RunAs -WindowStyle Hidden -Wait
        }
    } catch {
        return "DECLINED"
    }
    if (Test-Path $result) { return (Get-Content $result -Raw).Trim() }
    return "ERROR: no result"
}

function Get-WslVersion {
    $t = (Invoke-Wsl @("--version")).Text
    if ($t -match "(\d+)\.(\d+)\.(\d+)") { return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return [version]"0.0.0"
}

function Get-Distros {
    $r = Invoke-Wsl @("--list", "--quiet")
    if ($r.Code -ne 0) { return @() }
    return @($r.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-LatestTag($repo) {
    # Follows github.com/<repo>/releases/latest without using the rate-limited API
    $loc = $null
    for ($i = 1; -not $loc; $i++) {
        try {
            $req = [Net.HttpWebRequest]::Create("https://github.com/$repo/releases/latest")
            $req.AllowAutoRedirect = $false
            $req.UserAgent = "wsl-docker-engine"
            $resp = $req.GetResponse()
            try { $loc = $resp.Headers["Location"] } finally { $resp.Close() }
        } catch {
            if ($i -ge 4) { Stop-Install "Could not reach github.com: $($_.Exception.Message)" }
            Write-Info "Network problem, retrying ($i/3)..."
            Start-Sleep -Seconds (3 * $i)
        }
    }
    if ($loc -notmatch "/tag/([^/]+)$") { Stop-Install "Could not find the latest release of $repo" }
    return $Matches[1]
}

function Get-Sha256($path) { return (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant() }

function Install-GitHubBinary {
    # Downloads a release asset, checks it against the release's checksums.txt and installs it
    param($repo, $assetPattern, $dest, $label)
    $tag = Get-LatestTag $repo
    $asset = $assetPattern -f $tag
    $base = "https://github.com/$repo/releases/download/$tag"
    # Signed Windows binaries are listed in checksums-signed.txt (buildx), the rest in checksums.txt
    $line = $null
    foreach ($file in "checksums.txt", "checksums-signed.txt") {
        try { $sums = (Invoke-WebRequest -UseBasicParsing "$base/$file").Content } catch { continue }
        if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        $line = ($sums -split "`n") | Where-Object { $_ -match ("\s\*?" + [regex]::Escape($asset) + "\s*$") } | Select-Object -First 1
        if ($line) { break }
    }
    if (-not $line) { Stop-Install "No checksum published for $asset (or github.com is unreachable)" }
    $expected = ($line -split "\s+")[0].ToLowerInvariant()

    if ((Test-Path $dest) -and (Get-Sha256 $dest) -eq $expected) {
        Write-Ok "$label $tag already installed"
        return
    }
    $tmp = Join-Path $script:TempDir $asset
    Invoke-Download "$base/$asset" $tmp
    if ((Get-Sha256 $tmp) -ne $expected) { Stop-Install "Checksum mismatch for $asset (download corrupted or tampered)" }
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item $tmp $dest -Force
    Write-Ok "$label $tag installed (checksum verified)"
}

function Add-UserPath($dir) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($current -split ";" | Where-Object { $_ })
    if ($parts -notcontains $dir) {
        [Environment]::SetEnvironmentVariable("Path", (($parts + $dir) -join ";"), "User")
        Write-Ok "Added to your PATH: $dir"
    }
    if (($env:Path -split ";") -notcontains $dir) { $env:Path = "$env:Path;$dir" }
}

# ------------------------------------------------------------------------------

Write-Host ""
Write-Host "lindowin installer" -ForegroundColor White
Write-Host "Headless Linux Docker for Windows. Terminal only, no Docker Desktop."

$script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ("wsl-docker-engine-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $script:TempDir | Out-Null

try {
    # ---- Checks ----------------------------------------------------------------
    Write-Step "Checking this PC"

    if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
        Stop-Install "Only 64-bit Intel/AMD (x64) Windows is supported."
    }
    if ([Environment]::OSVersion.Version.Build -lt 19041) {
        Stop-Install "Windows 10 version 2004 (build 19041) or newer is required for WSL 2."
    }
    Write-Ok "Windows build $([Environment]::OSVersion.Version.Build), x64"

    $dockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerDesktop) {
        if (-not $Force) {
            Stop-Install ("Docker Desktop is installed. Both use \\.\pipe\docker_engine and the 'docker' command, so they would conflict.`n" +
                          "       Uninstall Docker Desktop first, or run again with -Force if you know what you are doing.")
        }
        Write-Warn "Docker Desktop is installed; continuing because of -Force."
    }

    $ourRelay = Get-Process docker-pipe-relay -ErrorAction SilentlyContinue
    if ((Test-Path "\\.\pipe\docker_engine") -and -not $ourRelay) {
        $msg = "Another program is serving \\.\pipe\docker_engine (Docker Desktop, Podman machine, Rancher Desktop...)."
        if (-not $Force) { Stop-Install "$msg`n       Stop it (for Podman: podman machine stop) and run the installer again." }
        Write-Warn $msg
    }

    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) { Stop-Install ".NET Framework 4 compiler not found ($csc)." }

    # ---- Installer files (local checkout or downloaded) ------------------------
    $src = $PSScriptRoot
    if (-not $src -or -not (Test-Path (Join-Path $src "relay\docker-pipe-relay.cs"))) {
        Write-Info "Downloading installer files from github.com/$Repo"
        $zip = Join-Path $script:TempDir "repo.zip"
        Invoke-Download "https://codeload.github.com/$Repo/zip/refs/heads/main" $zip
        Expand-Archive $zip (Join-Path $script:TempDir "repo") -Force
        $src = (Get-ChildItem (Join-Path $script:TempDir "repo") -Directory | Select-Object -First 1).FullName
    }

    # Keep a copy of the installer next to the program (used by uninstall and after a reboot)
    $installerCopy = Join-Path $InstallDir "installer"
    if ((Resolve-Path $src).Path.TrimEnd("\") -ne $installerCopy.TrimEnd("\")) {
        if (Test-Path $installerCopy) { Remove-Item -Recurse -Force $installerCopy }
        New-Item -ItemType Directory -Force $installerCopy | Out-Null
        foreach ($item in "install.ps1", "install.cmd", "uninstall.ps1", "uninstall.cmd", "system-setup.ps1", "wsl", "relay", "ports", "LICENSE") {
            $p = Join-Path $src $item
            if (Test-Path $p) { Copy-Item $p $installerCopy -Recurse -Force }
        }
    }

    # ---- WSL ---------------------------------------------------------------------
    Write-Step "Checking WSL"
    if (-not (Test-WslReady)) {
        Write-Info "WSL is not installed (or is too old). Installing it now."
        Write-Info "Windows will ask for administrator permission once."
        try { Start-Process wsl.exe -ArgumentList "--install --no-distribution" -Verb RunAs -Wait }
        catch { Stop-Install "Administrator permission is needed once to install WSL. Run the installer again and accept the prompt." }
        if (-not (Test-WslReady)) {
            # Most PCs need a restart after enabling WSL. Resume automatically after it.
            $resume = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installerCopy\install.ps1`" -Distro `"$Distro`""
            if ($NoStartup) { $resume += " -NoStartup" }
            if ($Force) { $resume += " -Force" }
            Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "wsl-docker-engine" -Value $resume
            Write-Host ""
            Write-Host "WSL was installed. Please RESTART your computer." -ForegroundColor Yellow
            Write-Host "The installer will continue by itself after you sign in again." -ForegroundColor Yellow
            return
        }
    }
    $wslVersion = Get-WslVersion
    if ($wslVersion -lt [version]"2.4.4") {
        Write-Info "Updating WSL ($wslVersion is too old). Windows may ask for administrator permission."
        Invoke-Wsl @("--update") | Out-Null
        if ((Get-WslVersion) -lt [version]"2.4.4") {
            try { Start-Process wsl.exe -ArgumentList "--update" -Verb RunAs -Wait } catch { }
        }
        if ((Get-WslVersion) -lt [version]"2.4.4") {
            Stop-Install "WSL 2.4.4 or newer is needed. Update it with: wsl --update (as administrator)"
        }
        $wslVersion = Get-WslVersion
    }
    Write-Ok "WSL $wslVersion"

    # ---- Distro --------------------------------------------------------------------
    Write-Step "Preparing the '$Distro' WSL distro"
    $fresh = $false
    if ((Get-Distros) -contains $Distro) {
        Write-Ok "Distro '$Distro' already exists, reusing it"
    } else {
        Write-Info "Downloading and installing $UbuntuImage as '$Distro' (a few minutes)..."
        $r = Invoke-Wsl @("--install", $UbuntuImage, "--name", $Distro, "--no-launch")
        if ($r.Code -ne 0 -or (Get-Distros) -notcontains $Distro) {
            $hint = ""
            if ($r.Text -match "0x80370102|virtualiz") {
                $hint = "`n       Virtualization seems to be disabled. Enable it in your BIOS/UEFI (Intel VT-x / AMD-V) and try again."
            }
            Stop-Install "Could not create the WSL distro:`n$($r.Text)$hint"
        }
        $fresh = $true
        Write-Ok "Distro '$Distro' created"
    }

    Start-TempKeepAlive $Distro

    # ---- Docker Engine inside WSL ------------------------------------------------
    Write-Step "Installing Docker Engine inside WSL"
    $setup = Join-Path $script:TempDir "setup.sh"
    $text = [IO.File]::ReadAllText((Join-Path $src "wsl\setup.sh")) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($setup, $text, (New-Object Text.UTF8Encoding($false)))
    $setupArgs = @("-d", $Distro, "-u", "root", "--cd", $script:TempDir, "--", "bash", "./setup.sh")
    if ($fresh) { $setupArgs += "--fresh" }
    & wsl.exe @setupArgs
    if ($LASTEXITCODE -ne 0) { Stop-Install "Setting up Docker inside WSL failed (see messages above)." }

    $needRestart = (Invoke-Wsl @("-d", $Distro, "-u", "root", "--", "test", "-f", "/run/wsl-docker-engine.restart")).Code -eq 0
    if ($needRestart) {
        Write-Info "Restarting the distro so systemd and the new settings take effect..."
        # Stop Docker cleanly first: running containers get SIGTERM and can shut down properly
        Invoke-Wsl @("-d", $Distro, "-u", "root", "--", "sh", "-c", "systemctl stop docker.service docker.socket >/dev/null 2>&1 || true") | Out-Null
        Get-Process docker-pipe-relay -ErrorAction SilentlyContinue | Stop-Process -Force
        Invoke-Wsl @("--terminate", $Distro) | Out-Null
        Start-TempKeepAlive $Distro
    } else {
        Invoke-Wsl @("-d", $Distro, "-u", "root", "--", "systemctl", "start", "docker") | Out-Null
    }
    Wait-DockerActive $Distro
    Write-Ok "Docker Engine is running inside WSL"

    # ---- Docker CLI for Windows ----------------------------------------------------
    Write-Step "Installing the Docker CLI for Windows"
    $bin = Join-Path $InstallDir "bin"
    New-Item -ItemType Directory -Force $bin | Out-Null

    $listing = (Invoke-Download "https://download.docker.com/win/static/stable/x86_64/").Links.href |
        Where-Object { $_ -match "^docker-(\d+\.\d+\.\d+)\.zip$" } |
        Sort-Object { [version]($_ -replace "^docker-|\.zip$", "") } | Select-Object -Last 1
    if (-not $listing) { Stop-Install "Could not find the Docker CLI on download.docker.com" }
    $cliVersion = $listing -replace "^docker-|\.zip$", ""
    $dockerExe = Join-Path $bin "docker.exe"
    $installed = if (Test-Path $dockerExe) { ((& $dockerExe --version) -replace "^Docker version ([^,]+),.*$", '$1') } else { "" }
    if ($installed -eq $cliVersion) {
        Write-Ok "docker.exe $cliVersion already installed"
    } else {
        $zip = Join-Path $script:TempDir $listing
        Invoke-Download "https://download.docker.com/win/static/stable/x86_64/$listing" $zip
        Expand-Archive $zip (Join-Path $script:TempDir "docker-cli") -Force
        Copy-Item (Join-Path $script:TempDir "docker-cli\docker\docker.exe") $dockerExe -Force
        Write-Ok "docker.exe $cliVersion installed (official static build)"
    }

    $configDir = if ($env:DOCKER_CONFIG) { $env:DOCKER_CONFIG } else { Join-Path $env:USERPROFILE ".docker" }
    $plugins = Join-Path $configDir "cli-plugins"
    Install-GitHubBinary "docker/compose" "docker-compose-windows-x86_64.exe" (Join-Path $plugins "docker-compose.exe") "docker compose"
    Install-GitHubBinary "docker/buildx" "buildx-{0}.windows-amd64.exe" (Join-Path $plugins "docker-buildx.exe") "docker buildx"
    Copy-Item (Join-Path $plugins "docker-compose.exe") (Join-Path $bin "docker-compose.exe") -Force

    # ---- Pipe relay ----------------------------------------------------------------
    Write-Step "Building the Docker pipe relay"
    $relayExe = Join-Path $bin "docker-pipe-relay.exe"
    Get-Process docker-pipe-relay -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    $r = Invoke-Native $csc @("/nologo", "/target:winexe", "/optimize", "/r:System.Core.dll", "/out:$relayExe", (Join-Path $src "relay\docker-pipe-relay.cs"))
    if ($r.Code -ne 0) { Write-Host $r.Text; Stop-Install "Could not build the pipe relay." }
    Write-Ok "Relay built: $relayExe"

    # ---- Environment ---------------------------------------------------------------
    Write-Step "Configuring your user environment"
    Add-UserPath $bin
    if ([Environment]::GetEnvironmentVariable("COMPOSE_CONVERT_WINDOWS_PATHS", "User") -ne "1") {
        [Environment]::SetEnvironmentVariable("COMPOSE_CONVERT_WINDOWS_PATHS", "1", "User")
        Write-Ok "COMPOSE_CONVERT_WINDOWS_PATHS=1 (compose bind mounts like ./data work)"
    }
    $env:COMPOSE_CONVERT_WINDOWS_PATHS = "1"
    $dockerHost = [Environment]::GetEnvironmentVariable("DOCKER_HOST", "User")
    if (-not $dockerHost) { $dockerHost = [Environment]::GetEnvironmentVariable("DOCKER_HOST", "Machine") }
    if ($dockerHost) {
        Write-Warn "DOCKER_HOST is set to '$dockerHost'. The docker command will use it instead of this setup."
        Write-Warn "Remove it if you want to use wsl-docker-engine."
    }
    $first = Get-Command docker.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($first -and $first.Source -ne $dockerExe) {
        Write-Warn "Another docker.exe comes first in PATH: $($first.Source)"
        Write-Warn "Remove it from PATH (or uninstall it) so 'docker' uses this setup."
    }

    # ---- Previous settings ----------------------------------------------------------
    $configPath = Join-Path $InstallDir "config.json"
    $config = @{ mirroredFailed = $false }
    if (Test-Path $configPath) {
        try {
            $old = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($old.mirroredFailed) { $config.mirroredFailed = $true }
        } catch { }
    }

    # ---- Network -------------------------------------------------------------------
    Write-Step "Configuring how published ports reach the network"
    $mode = Select-NetworkMode $Distro $NetworkMode $config
    switch ($mode) {
        "mirrored"  { Write-Ok "Mirrored networking: ports work exactly like on Linux (TCP/UDP, any IP)" }
        "portproxy" { Write-Ok "Port forwarding: '80:80' is reachable from the network, '127.0.0.1:80:80' only from this PC" }
        "local"     { Write-Ok "Local only: published ports are reachable from this PC only (-NetworkMode local)" }
    }

    # ---- Administrator part (one permission prompt) ---------------------------------
    $isServer = $Server -or ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1)
    Write-Step "Setting up automatic start and port rules"
    if ($isServer) { Write-Info "Windows Server (or -Server): Docker will start at boot, even if nobody signs in." }
    Write-Info "Windows will ask for administrator permission once."
    Get-Process docker-pipe-relay -ErrorAction SilentlyContinue | Stop-Process -Force
    $setupArgs = @("-Action", "Install", "-InstallDir", "`"$InstallDir`"", "-Distro", $Distro,
                   "-UserName", "`"$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`"", "-Mode", $mode)
    if ($isServer) { $setupArgs += "-StartAtBoot" }
    $result = Invoke-SystemSetup $setupArgs
    $relayArgs = @("--distro", $Distro, "--wsl-ip-file", "`"$(Join-Path $bin 'wsl-ip.txt')`"")
    if ($result -eq "OK") {
        Write-Ok "docker-users group, port rules service and start task are ready"
        if ($NoStartup) {
            Disable-ScheduledTask -TaskName "wsl-docker-engine" -ErrorAction SilentlyContinue | Out-Null
            Write-Info "Automatic start disabled (-NoStartup)."
        } else {
            Write-Ok ($(if ($isServer) { "Starts automatically at boot" } else { "Starts automatically at sign-in" }))
        }
    } else {
        if ($result -eq "DECLINED") { Write-Warn "Administrator permission was not granted." } else { Write-Warn $result }
        Write-Warn "Docker works, but only from this PC, and it will not start by itself."
        Write-Warn "Run the installer again and accept the prompt to finish the setup."
        $mode = "local"
    }

    # Old versions started from a .vbs in the Startup folder: the task replaces it
    $legacy = Join-Path ([Environment]::GetFolderPath("Startup")) "wsl-docker-engine.vbs"
    if (Test-Path $legacy) { Remove-Item $legacy -Force }

    # Remember what was installed (the uninstaller only removes plugins with these hashes)
    $hashes = @("docker-compose.exe", "docker-buildx.exe") | ForEach-Object { Get-Sha256 (Join-Path $plugins $_) }
    Set-Content -Path $configPath -Encoding ASCII -Value (@{
        distro = $Distro; pluginHashes = $hashes; networkMode = $mode; server = [bool]$isServer
        mirroredFailed = [bool]$config.mirroredFailed
    } | ConvertTo-Json)

    # ---- Start and test ------------------------------------------------------------
    Write-Step "Starting and testing"
    $started = $false
    if ($result -eq "OK" -and -not $NoStartup) {
        try { Start-ScheduledTask -TaskName "wsl-docker-engine" -ErrorAction Stop; $started = $true } catch { }
    }
    if (-not $started) { Start-Process $relayExe -ArgumentList $relayArgs -WindowStyle Hidden }
    for ($i = 0; $i -lt 20 -and -not (Test-Path "\\.\pipe\docker_engine"); $i++) { Start-Sleep -Milliseconds 500 }

    Remove-Item Env:DOCKER_HOST -ErrorAction SilentlyContinue
    $r = Invoke-Native $dockerExe @("version", "--format", "{{.Server.Version}}")
    $engineVersion = $r.Text
    if ($r.Code -ne 0 -or -not $engineVersion) {
        $log = Join-Path $bin "docker-pipe-relay.log"
        if (Test-Path $log) { Get-Content $log -Tail 5 | ForEach-Object { Write-Host "    $_" } }
        Stop-Install "Docker is installed but the Windows CLI could not reach it."
    }
    Write-Ok "docker.exe $cliVersion  ->  Docker Engine $engineVersion"

    Write-Host ""
    Write-Host "Done! Open a NEW terminal and try:" -ForegroundColor Green
    Write-Host "    docker run -d -p 8080:80 nginx   (then open http://localhost:8080)"
    Write-Host "    docker compose up -d"
    Write-Host ""
    switch ($mode) {
        "local"     { Write-Host "Published ports:  only reachable from this PC" }
        "portproxy" { Write-Host "Published ports:  like on Linux ('80:80' = network, '127.0.0.1:80:80' = this PC only)" }
        "mirrored"  { Write-Host "Published ports:  exactly like on Linux" }
    }
    Write-Host "Stop Docker:      wsl --terminate $Distro"
    Write-Host "Uninstall:        $installerCopy\uninstall.cmd"
}
catch {
    # Our own errors were already printed nicely; show anything unexpected
    if ("$($_.Exception.Message)" -ne $StopMarker) {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Nothing was broken. Fix the problem above and run the installer again." -ForegroundColor Yellow
    # Exit code 1 when run as a file; no exit when piped into iex (it would close the window)
    if ($PSCommandPath) { exit 1 }
}
finally {
    Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
}
