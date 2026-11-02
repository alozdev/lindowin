<#
  lindowin: manage your lindowin install.
  Started by bin\lindowin.cmd, so it works from cmd, PowerShell and Server Core.

    lindowin status | update | config | start | stop | uninstall [--all] | version | help
#>
param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"
# Words after the command, however they were written: "--all", "-all" and "all" are the same
$Options = @(@($Rest) | Where-Object { $_ } | ForEach-Object { $_.ToLower().TrimStart("-") })
# "lindowin --version": PowerShell treats a leading dash as a parameter, so it lands in $Rest
if (-not $PSBoundParameters.ContainsKey("Command") -and $Options.Count -gt 0) {
    $Command = $Options[0]
    $Options = @($Options | Select-Object -Skip 1)
}
$InstallDir = Split-Path (Split-Path $PSScriptRoot)      # ...\wsl-docker-engine (script lives in installer\src)
$ConfigPath = Join-Path $InstallDir "config.json"
$Docker = Join-Path $InstallDir "bin\docker.exe"
$InstallUrls = @("https://lindowin.dev/install", "https://raw.githubusercontent.com/alozdev/lindowin/main/install.ps1")

function Write-Ok($msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  !   $msg" -ForegroundColor Yellow }

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "lindowin is not installed correctly (missing $ConfigPath). Run the installer again." }
    return Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Get-StageDir($cfg) {
    # The owner's folder: installer copy, logs, settings kept across updates
    if ($cfg.stageDir) { return $cfg.stageDir } else { return $InstallDir }
}

function Save-Config($cfg) {
    $json = $cfg | ConvertTo-Json
    if (-not $cfg.allUsers) { Set-Content -Path $ConfigPath -Encoding ASCII -Value $json; return }
    # Shared install: the settings in Program Files affect everyone, so changing them needs
    # an administrator. The owner's copy is updated too, so updates keep the change.
    $targets = @($ConfigPath, (Join-Path (Get-StageDir $cfg) "config.json")) | Select-Object -Unique
    try {
        foreach ($t in $targets) { Set-Content -Path $t -Encoding ASCII -Value $json -ErrorAction Stop }
    } catch {
        Write-Host "  This changes Docker for all users: Windows will ask for administrator permission."
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $script = "`$j = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64'));" +
                  (($targets | ForEach-Object { "Set-Content -Path '$_' -Encoding ASCII -Value `$j" }) -join ";")
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        try { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList "-NoProfile", "-EncodedCommand", $enc }
        catch { throw "Administrator permission was not granted. Nothing changed." }
    }
}

function Test-IsOwner($cfg) {
    return (-not $cfg.allUsers) -or (-not $cfg.owner) -or
           ($cfg.owner -eq [Security.Principal.WindowsIdentity]::GetCurrent().Name)
}

function Assert-Owner($cfg, $what) {
    if (-not (Test-IsOwner $cfg)) { throw "Docker is shared by $($cfg.owner): only they can $what (it affects everyone)." }
}

function Test-DistroRunning($name) {
    $running = (& wsl.exe --list --running --quiet 2>$null) -replace "`0", ""
    return [bool]($running | Where-Object { $_.Trim() -eq $name })
}

function Invoke-LocalInstaller($cfg, [hashtable]$extra) {
    # Re-runs the installer already on this PC (no download) with the saved settings plus $extra
    $stage = Get-StageDir $cfg
    $installer = Join-Path $stage "installer\install.ps1"
    if (-not (Test-Path $installer)) { throw "Installer copy not found ($installer). Run: lindowin update" }
    $params = @{ Distro = $cfg.distro; InstallDir = $stage } + $extra
    $env:LINDOWIN_COMMAND = "1"     # the installer then knows this window keeps working
    & $installer @params
}

function Get-SpecificIpPorts {
    # Containers (running or not) that publish a port on one specific IP, e.g. 192.168.1.20:80:80.
    # 127.x and "all IPs" work in every network mode, so they are not listed.
    $ids = @(& $Docker ps -aq 2>$null)
    if ($LASTEXITCODE -ne 0 -or $ids.Count -eq 0) { return @() }
    $found = @()
    foreach ($line in (& $Docker inspect --format '{{.Name}}|{{json .HostConfig.PortBindings}}' $ids 2>$null)) {
        $name, $json = $line -split "\|", 2
        if (-not $json -or $json -eq "null") { continue }
        $bindings = $json | ConvertFrom-Json
        foreach ($prop in $bindings.PSObject.Properties) {
            foreach ($b in @($prop.Value)) {
                $ip = $b.HostIp
                if ($ip -and $ip -notin "0.0.0.0", "::" -and $ip -notmatch "^127\." -and $ip -ne "::1") {
                    $found += "$($name.TrimStart('/')) ($($ip):$($b.HostPort))"
                }
            }
        }
    }
    return $found
}

function Get-RelayStatus($cfg) {
    # Written by the relay: network, pipe_owner (+ _time)
    $file = Join-Path (Get-StageDir $cfg) "bin\relay-status.txt"
    $st = @{}
    if (Test-Path $file) {
        foreach ($line in Get-Content $file) {
            $i = $line.IndexOf("=")
            if ($i -gt 0) { $st[$line.Substring(0, $i)] = $line.Substring($i + 1) }
        }
    }
    return $st
}

function Test-InDockerUsers {
    # In the group now (this sign-in), and in the group at all (may need to sign out and in)
    $inToken = [bool](& whoami.exe /groups 2>$null | Select-String -SimpleMatch "\docker-users")
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $member = $false
    try { $member = [bool](Get-LocalGroupMember -Group "docker-users" -ErrorAction Stop | Where-Object { $_.Name -eq $me }) } catch { }
    return @{ Token = $inToken; Member = ($member -or $inToken) }
}

function Get-DistroDisk($name) {
    # The WSL virtual disk (ext4.vhdx) of the distro, from the registry
    foreach ($k in Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty $k.PSPath
        if ($p.DistributionName -eq $name) {
            $folder = $p.BasePath -replace '^\\\\\?\\', ''
            $file = Get-ChildItem $folder -Filter *.vhdx -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($file) { return $file }
        }
    }
    return $null
}

function Stop-DockerCleanly($name) {
    # Containers shut down cleanly and keep their restart policy (also with live-restore)
    & wsl.exe -d $name -u root -- sh -c "if [ -x /usr/local/sbin/lindowin-stop-docker ]; then /usr/local/sbin/lindowin-stop-docker; else systemctl stop docker.socket docker; fi" 2>$null | Out-Null
}

function Test-RelayBlocked([datetime]$since) {
    # Smart App Control may block lindowin's relay (built on this PC, not signed yet)
    try {
        return [bool](Get-WinEvent -FilterHashtable @{ LogName = "Microsoft-Windows-CodeIntegrity/Operational"; Id = 3033; StartTime = $since } -ErrorAction Stop |
            Where-Object { $_.Message -match "docker-pipe-relay\.exe" })
    } catch { return $false }
}

function Show-Notices($cfg) {
    # Found by the relay once a day: updates, disk space worth giving back (no internet call here)
    if (-not (Test-IsOwner $cfg)) { return }
    $st = Get-RelayStatus $cfg
    $updates = @()
    if ($st["update_lindowin"]) { $updates += "lindowin $($st['update_lindowin'])" }
    if ($st["update_docker"]) { $updates += "Docker CLI $($st['update_docker'])" }
    if ($updates.Count -gt 0) { Write-Warn "$($updates -join ' and ') available. Run: lindowin update" }
    if ($st["compact_gb"]) { Write-Warn "About $($st['compact_gb']) GB of Docker's disk is unused. Run: lindowin compact" }
}

function Get-LastPortWarning($cfg) {
    $log = Join-Path (Get-StageDir $cfg) "bin\docker-pipe-relay.log"
    if (-not (Test-Path $log)) { return $null }
    $line = Get-Content $log -Tail 200 | Where-Object { $_ -match "Port warning:" } | Select-Object -Last 1
    if (-not $line) { return $null }
    try { if ([datetime]::Parse($line.Substring(0, 19)) -lt (Get-Date).AddHours(-24)) { return $null } } catch { }
    return $line
}

function Show-Help {
    Write-Host ""
    Write-Host "lindowin: headless Linux Docker for Windows" -ForegroundColor White
    Write-Host ""
    Write-Host "  lindowin status              Is Docker running? Containers, memory"
    Write-Host "  lindowin update              Get the latest lindowin and Docker (keeps your settings)"
    Write-Host "  lindowin config              Show the settings. Change one with:"
    Write-Host "      config idle-sleep on|off          Sleep after 5 min with no containers, to free memory"
    Write-Host "      config start-at boot|signin       Start at boot (no sign-in needed) or when you sign in"
    Write-Host "      config share all-users|me         Share Docker with the docker-users group, or just you"
    Write-Host "      config network mirrored|nat|local Published ports: mirrored (default) or nat (wakes faster)"
    Write-Host "  lindowin start               Start Docker now"
    Write-Host "  lindowin stop                Stop Docker now and free its memory"
    Write-Host "  lindowin compact             Give unused disk space back to Windows (stops Docker ~1 min)"
    Write-Host "  lindowin uninstall           Uninstall (keeps your containers, images and volumes)"
    Write-Host "  lindowin uninstall --all     Uninstall and delete all Docker data (asks first)"
    Write-Host "  lindowin version"
    Write-Host ""
    Write-Host "  Docker itself is used as always: docker run, docker compose up..."
    Write-Host ""
}

function Show-Config($cfg) {
    Write-Host ""
    Write-Host "lindowin $($cfg.version) settings" -ForegroundColor White
    Write-Host "  idle-sleep   $(if ($cfg.idleSleep -eq 'on') { 'on    (after 5 min with no containers, Docker sleeps to free memory)' } else { 'off   (Docker stays on)' })"
    Write-Host "  start-at     $(if ($cfg.startAt -eq 'boot') { 'boot  (no sign-in needed)' } else { 'signin (when you sign in)' })"
    Write-Host "  share        $(if ($cfg.allUsers) { "all-users (members of docker-users; owner: $($cfg.owner))" } else { 'me    (only your Windows user)' })"
    $net = switch ($cfg.networkMode) {
        "mirrored"  { "like on Linux (mirrored networking)" }
        "portproxy" { "like on Linux (port forwarding)" }
        default     { "this PC only" }
    }
    $choice = if ($cfg.networkChoice -and $cfg.networkChoice -ne "auto") { $cfg.networkChoice -replace "portproxy", "nat" } else { "auto" }
    Write-Host "  network      $choice   (ports: $net)"
    Write-Host "  distro       $($cfg.distro)"
    Write-Host ""
    Write-Host "  Change one:  lindowin config <setting> <value>    e.g. lindowin config idle-sleep off"
    Write-Host ""
}

try {
    switch ($Command.ToLower().TrimStart("-")) {

        { $_ -in "help", "h", "?", "/?" } { Show-Help }

        { $_ -in "version", "v" } {
            $cfg = Get-Config
            Write-Host "lindowin $($cfg.version)"
        }

        "status" {
            $cfg = Get-Config
            Write-Host ""
            Write-Host "lindowin $($cfg.version)" -ForegroundColor White
            $st = Get-RelayStatus $cfg
            if (-not (Test-IsOwner $cfg)) {
                # Shared Docker of another user: just ask Docker
                $count = @(& $Docker ps -q 2>$null).Count
                if ($LASTEXITCODE -eq 0) { Write-Ok "Docker is running (shared by $($cfg.owner)), $count container(s) up" }
                else {
                    $g = Test-InDockerUsers
                    if (-not $g.Member) { Write-Warn "You are not in the 'docker-users' group. Ask an administrator to run: Add-LocalGroupMember docker-users $([Environment]::UserName)" }
                    elseif (-not $g.Token) { Write-Warn "You were added to 'docker-users': sign out and back in to use Docker." }
                    else { Write-Warn "Docker is not reachable. It is shared by $($cfg.owner): ask them or an administrator." }
                }
            } elseif (-not (Get-Process docker-pipe-relay -ErrorAction SilentlyContinue)) {
                if ($st["pipe_owner"]) {
                    Write-Warn "lindowin could not start: $($st['pipe_owner']) is using the Docker pipe."
                    Write-Host "      Quit it, then run: lindowin start"
                } elseif (Test-RelayBlocked (Get-Date).AddHours(-1)) {
                    Write-Warn "Windows Smart App Control blocked lindowin's relay (it is built on this PC and not signed yet)."
                    Write-Host "      Run: lindowin start  (Windows usually allows it on the next try)"
                } else {
                    Write-Warn "Docker is not available (the relay is not running). Run: lindowin start"
                }
            } elseif (Test-DistroRunning $cfg.distro) {
                $count = @(& $Docker ps -q 2>$null).Count
                Write-Ok "Docker is running, $count container(s) up"
                $vm = Get-Process vmmemWSL -ErrorAction SilentlyContinue
                if ($vm) { Write-Host ("      Memory: {0:N0} MB (WSL VM, includes Linux cache)" -f ($vm.WorkingSet64 / 1MB)) }
            } elseif ($cfg.idleSleep -eq "on") {
                Write-Ok "Docker is sleeping (no memory used). Any docker command wakes it."
            } else {
                Write-Ok "Docker is stopped. Any docker command starts it."
            }
            if ((Test-IsOwner $cfg) -and $st["network"] -eq "none" -and (Test-DistroRunning $cfg.distro)) {
                Write-Warn "Docker has no network: WSL started without it ($($cfg.networkMode) networking)."
                if ($cfg.networkMode -eq "mirrored") { Write-Host "      Run: lindowin stop, then any docker command. If it keeps happening: lindowin config network nat" }
                else { Write-Host "      Run: lindowin stop, then any docker command." }
            }
            $warn = Get-LastPortWarning $cfg
            if ($warn) {
                Write-Warn "Last 24 h: Docker reported a problem."
                Write-Host ("      " + ($warn -replace "^.*?(lindowin: )", ""))
            }
            if (Test-IsOwner $cfg) {
                $disk = Get-DistroDisk $cfg.distro
                if ($disk) {
                    $drive = Get-PSDrive -Name $disk.FullName.Substring(0, 1) -ErrorAction SilentlyContinue
                    $freeGb = if ($drive) { $drive.Free / 1GB } else { 999 }
                    Write-Host ("      Disk:   {0:N1} GB (Docker's WSL disk), {1:N0} GB free on {2}:" -f ($disk.Length / 1GB), $freeGb, $disk.FullName.Substring(0, 1))
                    if ($freeGb -lt 2) { Write-Warn "Less than 2 GB free: downloads and builds may fail. Try: docker system prune, then lindowin compact" }
                }
                Show-Notices $cfg
            }
            Write-Host "      Settings: lindowin config"
            Write-Host ""
        }

        "config" {
            $cfg = Get-Config
            if ($Options.Count -eq 0) { Show-Config $cfg; break }
            $setting = $Options[0]
            $value = if ($Options.Count -gt 1) { $Options[1] } else { "" }

            switch ($setting) {
                "idle-sleep" {
                    if ($value -notin "on", "off") { throw "Use: lindowin config idle-sleep on   or   lindowin config idle-sleep off" }
                    $cfg.idleSleep = $value
                    $cfg.idleSleepMinutes = $(if ($value -eq "on") { 5 } else { 0 })
                    Save-Config $cfg
                    if ($value -eq "on") { Write-Ok "Idle sleep on: after 5 minutes with no containers, Docker sleeps to free memory." }
                    else { Write-Ok "Idle sleep off: Docker stays on." }
                    Write-Host "      Takes effect within 30 seconds."
                }

                "start-at" {
                    if ($value -notin "boot", "signin") { throw "Use: lindowin config start-at boot   or   lindowin config start-at signin" }
                    Assert-Owner $cfg "change when it starts"
                    if ($cfg.allUsers) {
                        if ($value -eq "boot") { Write-Ok "Docker already starts at boot (shared with all users)."; break }
                        throw "Shared Docker always starts at boot. To make it yours only first: lindowin config share me"
                    }
                    if ($cfg.startAt -eq $value) { Write-Ok "Already set: start-at $value"; break }
                    Write-Host "  Windows will ask for administrator permission (to change the start task)."
                    $result = Join-Path ([IO.Path]::GetTempPath()) ("lindowin-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")
                    $setup = Join-Path $PSScriptRoot "system-setup.ps1"
                    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$setup`"", "-Action", "Install",
                                 "-InstallDir", "`"$InstallDir`"", "-Distro", $cfg.distro,
                                 "-UserName", "`"$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`"",
                                 "-Mode", $cfg.networkMode, "-ResultFile", "`"$result`"")
                    if ($value -eq "boot") { $argList += "-StartAtBoot" }
                    try { Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -Wait }
                    catch { throw "Administrator permission was not granted. Nothing changed." }
                    $text = if (Test-Path $result) { (Get-Content $result -Raw).Trim() } else { "no result" }
                    Remove-Item $result -ErrorAction SilentlyContinue
                    if ($text -ne "OK") { throw "Could not change the start task: $text" }
                    $cfg.startAt = $value
                    $cfg.server = ($value -eq "boot")
                    Save-Config $cfg
                    Start-ScheduledTask -TaskName "wsl-docker-engine" -ErrorAction SilentlyContinue
                    if ($value -eq "boot") { Write-Ok "Docker now starts at boot, even if nobody signs in." }
                    else { Write-Ok "Docker now starts when you sign in." }
                }

                "share" {
                    if ($value -notin "all-users", "me") { throw "Use: lindowin config share all-users   or   lindowin config share me" }
                    Assert-Owner $cfg "change who can use it"
                    $want = $value -eq "all-users"
                    if ([bool]$cfg.allUsers -eq $want) {
                        if (Get-Process docker-pipe-relay -ErrorAction SilentlyContinue) { Write-Ok "Already set: share $value"; break }
                        Write-Host "  Already set, but Docker is not running: repairing it..."
                    }
                    if ($want) { Write-Host "  Sharing Docker with the docker-users group (Docker will start at boot)..." }
                    else { Write-Host "  Making Docker yours only again..." }
                    # Moving programs between your folder and Program Files: the local installer does it
                    # Open terminals keep working: the old location forwards to the new one
                    Invoke-LocalInstaller $cfg @{ AllUsers = $want }
                }

                "network" {
                    $map = @{ "mirrored" = "mirrored"; "nat" = "portproxy"; "local" = "local"; "auto" = "auto" }
                    if (-not $map.ContainsKey($value)) { throw "Use: lindowin config network mirrored|nat|local|auto" }
                    Assert-Owner $cfg "change its network"
                    switch ($value) {
                        "mirrored" { Write-Host "  Mirrored: ports work exactly like on Linux, including specific IPs." }
                        "nat"      { Write-Host "  NAT: wakes from idle sleep faster and avoids VPN issues. Specific-IP ports (192.168.x.x:80:80) are not supported." }
                        "local"    { Write-Host "  Local: published ports are reachable from this PC only." }
                        "auto"     { Write-Host "  Auto: mirrored if it works on this PC, otherwise NAT." }
                    }
                    if ($value -in "nat", "local") {
                        # These containers would stop working: say so before changing anything
                        $affected = @(Get-SpecificIpPorts)
                        if ($affected.Count -gt 0) {
                            Write-Warn "These containers publish ports on a specific IP and will not start with '$value':"
                            $affected | ForEach-Object { Write-Host "        $_" }
                            Write-Host "      Keep mirrored, or change them to all IPs (for example 80:80)."
                            $answer = Read-Host "  Change to '$value' anyway? (y/N)"
                            if ($answer -notmatch "^(y|yes|s|si)$") { Write-Host "  Nothing changed."; break }
                        }
                    }
                    Write-Host "  WSL restarts once to apply it (running containers restart too)."
                    Invoke-LocalInstaller $cfg @{ NetworkMode = $map[$value] }
                }

                default { throw "Unknown setting '$setting'. Settings: idle-sleep, start-at, share, network. See: lindowin config" }
            }
        }

        "start" {
            $cfg = Get-Config
            if (-not (Test-IsOwner $cfg)) {
                $v = & $Docker version --format "{{.Server.Version}}" 2>$null
                if ($LASTEXITCODE -eq 0) { Write-Ok "Docker $v is running (shared by $($cfg.owner))."; break }
                throw "Docker is not running. It is shared by $($cfg.owner): ask them or an administrator."
            }
            $since = (Get-Date).AddSeconds(-5)
            for ($try = 1; $try -le 3 -and -not (Get-Process docker-pipe-relay -ErrorAction SilentlyContinue); $try++) {
                try { Start-ScheduledTask -TaskName "wsl-docker-engine" -ErrorAction Stop }
                catch {
                    $relayExe = Join-Path $InstallDir "bin\docker-pipe-relay.exe"
                    Start-Process $relayExe -WindowStyle Hidden -ArgumentList @("--distro", $cfg.distro, "--config", "`"$ConfigPath`"",
                        "--wsl-ip-file", "`"$(Join-Path (Get-StageDir $cfg) 'bin\wsl-ip.txt')`"")
                }
                for ($i = 0; $i -lt 20 -and -not (Test-Path "\\.\pipe\docker_engine"); $i++) { Start-Sleep -Milliseconds 500 }
                if (-not (Test-Path "\\.\pipe\docker_engine") -and (Test-RelayBlocked $since)) {
                    Write-Host "  Windows Smart App Control blocked the relay. Trying again in a few seconds..."
                    Start-Sleep 5
                }
            }
            $v = & $Docker version --format "{{.Server.Version}}" 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Docker $v is running." } else { throw "Docker did not start. Check: lindowin status" }
        }

        "stop" {
            $cfg = Get-Config
            Assert-Owner $cfg "stop it"
            if (-not (Test-DistroRunning $cfg.distro)) { Write-Ok "Docker is already stopped."; break }
            # Stop Docker cleanly first, so databases shut down properly
            Stop-DockerCleanly $cfg.distro
            & wsl.exe --terminate $cfg.distro | Out-Null
            Write-Ok "Docker stopped. Any docker command starts it again."
        }

        "compact" {
            # WSL never shrinks its virtual disk by itself: images you delete still take space
            # on Windows. Docker and WSL must be stopped while the disk is compacted.
            $cfg = Get-Config
            Assert-Owner $cfg "compact its disk"
            $disk = Get-DistroDisk $cfg.distro
            if (-not $disk) { throw "Could not find the WSL disk of the '$($cfg.distro)' distro." }
            $before = $disk.Length
            Write-Host ""
            Write-Host ("  Docker's disk: {0:N1} GB on Windows." -f ($before / 1GB))
            Write-Host "  Compacting stops Docker and all WSL distros for about a minute."
            Write-Host "  Containers with a restart policy (restart: always / unless-stopped) start again by themselves."
            if (Test-DistroRunning $cfg.distro) {
                $up = @(& $Docker ps --format "{{.Names}}" 2>$null)
                if ($up.Count -gt 0) { Write-Host "  Running now: $($up -join ', ')" }
            }
            if ($Options -notcontains "yes" -and $Options -notcontains "y") {
                $answer = Read-Host "  Continue? (y/N)"
                if ($answer -notmatch "^(y|yes|s|si)$") { Write-Host "  Nothing changed."; break }
            }

            # 1. Tell the disk which blocks are free, with Docker stopped cleanly
            Write-Host "  Stopping Docker and marking free space..."
            Stop-DockerCleanly $cfg.distro
            & wsl.exe -d $cfg.distro -u root -- sh -c "systemctl stop containerd 2>/dev/null; sync; fstrim -a 2>/dev/null; true" | Out-Null
            # 2. Nothing may use the disk while it is compacted
            & wsl.exe --shutdown | Out-Null
            for ($i = 0; $i -lt 60 -and (Get-Process vmmemWSL -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }

            # 3. Compact it (diskpart needs administrator rights)
            Write-Host "  Compacting (Windows will ask for administrator permission)..."
            $script = Join-Path ([IO.Path]::GetTempPath()) "lindowin-compact.txt"
            Set-Content -Path $script -Encoding ASCII -Value @(
                "select vdisk file=`"$($disk.FullName)`"", "attach vdisk readonly", "compact vdisk", "detach vdisk")
            try { Start-Process diskpart.exe -ArgumentList "/s `"$script`"" -Verb RunAs -WindowStyle Hidden -Wait }
            catch { Write-Warn "Administrator permission was not granted: the disk was not compacted." }
            Remove-Item $script -ErrorAction SilentlyContinue

            # 4. Start Docker again (containers with a restart policy come back)
            $after = (Get-Item $disk.FullName).Length
            & $Docker version --format "{{.Server.Version}}" 2>$null | Out-Null
            if ($after -lt $before) {
                Write-Ok ("Docker's disk: {0:N1} GB -> {1:N1} GB ({2:N1} GB given back to Windows)." -f ($before / 1GB), ($after / 1GB), (($before - $after) / 1GB))
            } else {
                Write-Ok ("Docker's disk was already compact ({0:N1} GB)." -f ($after / 1GB))
            }
            Write-Host "      Docker is running again."
        }

        "update" {
            $cfg = Get-Config
            Assert-Owner $cfg "update it"
            Write-Host "Downloading the latest installer..."
            $code = $null
            foreach ($u in $InstallUrls) {
                try { $code = Invoke-RestMethod -UseBasicParsing $u; if ($code) { break } } catch { }
            }
            if (-not $code) { throw "Could not download the installer. Check your internet connection." }
            # The installer keeps every saved setting (idle sleep, start, sharing, network)
            $env:LINDOWIN_COMMAND = "1"
            & ([scriptblock]::Create($code)) -Distro $cfg.distro -InstallDir (Get-StageDir $cfg)
        }

        "uninstall" {
            $cfg = Get-Config
            Assert-Owner $cfg "uninstall it"
            $script = Join-Path (Get-StageDir $cfg) "installer\uninstall.ps1"
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "lindowin-uninstall.ps1"
            Copy-Item $script $tmp -Force    # the install folder is deleted while it runs
            $uArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tmp, "-InstallDir", (Get-StageDir $cfg))
            if ($Options -contains "all") { $uArgs += "-RemoveDistro" }
            & powershell.exe @uArgs
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }

        default {
            Write-Warn "Unknown command: $Command"
            Show-Help
            exit 1
        }
    }
}
catch {
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# One-line reminders after everyday commands (status shows them in its own list)
if ($Command.ToLower().TrimStart("-") -in "config", "start", "stop", "compact") {
    try { $cfg = Get-Config; Show-Notices $cfg } catch { }
}
