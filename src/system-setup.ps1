<#
.SYNOPSIS
  Admin part of lindowin. Called (elevated, once) by install.ps1 / uninstall.ps1.
  You do not need to run it yourself.

  Install:
   - local group "docker-users" (like Docker Desktop) + adds the installing user
   - docker-port-sync service (SYSTEM scheduled task) so published ports work like on Linux
   - the start task: at sign-in on PCs, at boot (no sign-in needed) on servers
  Uninstall:
   - removes the tasks, every firewall / portproxy rule it created, and its files
#>
[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall")][string]$Action = "Install",
    [string]$InstallDir,
    [string]$Distro = "docker",
    [string]$UserName,               # DOMAIN\user that owns the WSL distro
    [ValidateSet("mirrored", "portproxy", "local")][string]$Mode = "mirrored",
    [switch]$StartAtBoot,            # servers: start without anyone signing in
    [switch]$AllUsers,               # share Docker with every member of docker-users (Program Files + machine PATH)
    [string]$PluginDir,              # with -AllUsers: folder with the docker-compose / docker-buildx plugins to share
    [string]$ResultFile              # where to write OK / the error (the window is hidden)
)

$ErrorActionPreference = "Stop"
$ProgramDir = Join-Path $env:ProgramFiles "wsl-docker-engine"
$StateDir = Join-Path $env:ProgramData "wsl-docker-engine"
$RelayTask = "wsl-docker-engine"
$PortsTask = "wsl-docker-engine-ports"
$Group = "docker-users"
$GroupMarker = Join-Path $StateDir "created-docker-users-group"
$SharedBin = Join-Path $ProgramDir "bin"
$SharedPlugins = Join-Path $env:ProgramFiles "Docker\cli-plugins"
$SharedPluginsMarker = Join-Path $SharedPlugins "installed-by-lindowin.txt"

function Write-Result($text) { if ($ResultFile) { Set-Content -Path $ResultFile -Value $text -Encoding UTF8 } }

function Remove-PortRules {
    # Firewall rules created by docker-port-sync
    Get-NetFirewallRule -Name "wsl-docker-engine-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        Get-NetFirewallHyperVRule -Name "wsl-docker-engine-*" -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue
    }
    # portproxy entries recorded in its state file
    $state = Join-Path $StateDir "applied.txt"
    if (Test-Path $state) {
        $lines = Get-Content $state
        $hostIps = (($lines | Where-Object { $_ -like "hostips=*" }) -replace "^hostips=", "") -split "," | Where-Object { $_ }
        foreach ($key in ($lines | Where-Object { $_ -like "tcp/*" })) {
            $port = $key.Substring(4)
            foreach ($ip in $hostIps) { netsh interface portproxy delete v4tov4 listenaddress=$ip listenport=$port | Out-Null }
        }
        Remove-Item $state -Force
    }
}

# Deleting a file at the next restart (MOVEFILE_DELAY_UNTIL_REBOOT): for files an open
# terminal may still be using, e.g. the lindowin.cmd that is running right now.
Add-Type -Namespace LindowinNative -Name Files -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string existing, IntPtr target, int flags);
'@

function Remove-AtRestart([string[]]$paths) {
    foreach ($p in $paths) {
        # Not fatal: at worst a small leftover stays until the next install or uninstall
        if (Test-Path $p) { [LindowinNative.Files]::MoveFileEx($p, [IntPtr]::Zero, 4) | Out-Null }
    }
}

function Cancel-RemoveAtRestart([string]$under) {
    # Sharing again before a restart: do not let the pending deletions remove the new files
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    $ops = (Get-ItemProperty $key -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if (-not $ops) { return }
    $keep = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i + 1 -lt $ops.Count; $i += 2) {
        if ($ops[$i] -notlike "*$under*") { $keep.Add($ops[$i]); $keep.Add($ops[$i + 1]) }
    }
    if ($keep.Count -eq $ops.Count) { return }
    if ($keep.Count -eq 0) { Remove-ItemProperty $key -Name PendingFileRenameOperations }
    else { Set-ItemProperty $key -Name PendingFileRenameOperations -Value ([string[]]$keep) -Type MultiString }
}

function Set-MachinePath([bool]$add) {
    $path = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = @($path -split ";" | Where-Object { $_ -and $_.TrimEnd("\") -ne $SharedBin.TrimEnd("\") })
    if ($add) { $parts += $SharedBin }
    $new = $parts -join ";"
    if ($new -ne $path) { [Environment]::SetEnvironmentVariable("Path", $new, "Machine") }
}

function Remove-SharedFiles([string]$why = "switch") {
    # Everything -AllUsers put outside the user's folder.
    # Terminals that were already open still have Program Files in their PATH, and the
    # "lindowin config share me" that is running right now lives there too. So:
    #   switch:    keep docker.exe and a lindowin.cmd that forwards to the user's copy,
    #              so open terminals keep working; both are deleted at the next restart.
    #   uninstall: leave only a lindowin.cmd saying it was uninstalled, deleted at restart.
    Set-MachinePath $false
    foreach ($p in (Join-Path $ProgramDir "installer"), (Join-Path $ProgramDir "config.json")) {
        if (Test-Path $p) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
    }
    if (Test-Path $SharedBin) {
        $cmdFile = Join-Path $SharedBin "lindowin.cmd"
        $keepNames = if ($why -eq "switch") { "lindowin.cmd", "docker.exe" } else { "lindowin.cmd" }
        Get-ChildItem $SharedBin | Where-Object { $keepNames -notcontains $_.Name } | Remove-Item -Force -ErrorAction SilentlyContinue
        $text = if ($why -eq "switch") { "@`"$(Join-Path $InstallDir 'bin\lindowin.cmd')`" %*" }
                else { "@echo lindowin was uninstalled. & exit /b 0" }
        Set-Content -Path $cmdFile -Encoding ASCII -Value $text
        Remove-AtRestart (@(Get-ChildItem $SharedBin | ForEach-Object FullName) + $SharedBin)
    }
    if ([Environment]::GetEnvironmentVariable("COMPOSE_CONVERT_WINDOWS_PATHS", "Machine") -eq "1") {
        [Environment]::SetEnvironmentVariable("COMPOSE_CONVERT_WINDOWS_PATHS", $null, "Machine")
    }
    if (Test-Path $SharedPluginsMarker) {
        Remove-Item -Recurse -Force $SharedPlugins -ErrorAction SilentlyContinue
        $dockerDir = Split-Path $SharedPlugins
        if ((Test-Path $dockerDir) -and -not (Get-ChildItem $dockerDir -Force)) { Remove-Item $dockerDir -Force }
    }
}

function Install-SharedFiles {
    # Copies the CLI, the relay and the "lindowin" command where every user can run them
    # but only administrators can change them.
    Cancel-RemoveAtRestart $ProgramDir
    New-Item -ItemType Directory -Force $SharedBin | Out-Null
    foreach ($f in "docker.exe", "docker-pipe-relay.exe", "lindowin.cmd") {
        Copy-Item (Join-Path $InstallDir "bin\$f") (Join-Path $SharedBin $f) -Force
    }
    $sharedInstaller = Join-Path $ProgramDir "installer"
    if (Test-Path $sharedInstaller) { Remove-Item -Recurse -Force $sharedInstaller }
    Copy-Item (Join-Path $InstallDir "installer") $sharedInstaller -Recurse -Force
    Copy-Item (Join-Path $InstallDir "config.json") (Join-Path $ProgramDir "config.json") -Force

    if (-not (Test-Path $SharedPlugins)) {
        New-Item -ItemType Directory -Force $SharedPlugins | Out-Null
        Set-Content -Path $SharedPluginsMarker -Value "created by lindowin"
    }
    if (Test-Path $SharedPluginsMarker) {
        foreach ($f in "docker-compose.exe", "docker-buildx.exe") {
            $from = Join-Path $PluginDir $f
            if (Test-Path $from) { Copy-Item $from (Join-Path $SharedPlugins $f) -Force }
        }
    }
    Set-MachinePath $true
    [Environment]::SetEnvironmentVariable("COMPOSE_CONVERT_WINDOWS_PATHS", "1", "Machine")
}

function Stop-Tasks {
    foreach ($t in $RelayTask, $PortsTask) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
        }
    }
    Get-Process docker-port-sync -ErrorAction SilentlyContinue | Stop-Process -Force
    # The relay too: started at boot it runs in its own session, where only an administrator can stop it
    Get-Process docker-pipe-relay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function New-TaskSettings {
    New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
}

try {
    if ($Action -eq "Uninstall") {
        Stop-Tasks
        Remove-PortRules
        if (Test-Path $GroupMarker) { Remove-LocalGroup -Name $Group -ErrorAction SilentlyContinue }
        Remove-SharedFiles "uninstall"
        # Program Files folder: everything now, except the bin folder a terminal may be running from
        Get-ChildItem $ProgramDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $SharedBin } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $SharedBin) { Remove-AtRestart @($ProgramDir) }
        else { Remove-Item -Recurse -Force $ProgramDir -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
        Write-Result "OK"
        return
    }

    if (-not $InstallDir -or -not $UserName) { throw "InstallDir and UserName are required" }
    $relayNew = Join-Path $InstallDir "bin\docker-pipe-relay.new.exe"
    if ($AllUsers -and -not $StartAtBoot) { throw "-AllUsers needs -StartAtBoot (shared Docker cannot wait for one person to sign in)" }
    New-Item -ItemType Directory -Force $ProgramDir, $StateDir | Out-Null

    # ---- docker-users group ------------------------------------------------------
    if (-not (Get-LocalGroup -Name $Group -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $Group -Description "Users allowed to use Docker (wsl-docker-engine)" | Out-Null
        Set-Content -Path $GroupMarker -Value "created by wsl-docker-engine"
    }
    $isMember = Get-LocalGroupMember -Group $Group -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $UserName }
    if (-not $isMember) { Add-LocalGroupMember -Group $Group -Member $UserName -ErrorAction SilentlyContinue }

    # ---- Port sync service (runs as SYSTEM) ----------------------------------------
    # Built here, into Program Files, so a normal user cannot replace a program that runs as SYSTEM.
    Stop-Tasks
    # A relay the installer could not replace (it was running at boot): now it is stopped
    if (Test-Path $relayNew) { Move-Item $relayNew (Join-Path $InstallDir "bin\docker-pipe-relay.exe") -Force }
    Remove-PortRules   # start clean; the service recreates the rules for running containers

    if ($Mode -ne "local") {
        $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        $source = Join-Path $PSScriptRoot "ports\docker-port-sync.cs"
        $exe = Join-Path $ProgramDir "docker-port-sync.exe"
        $out = & $csc /nologo /target:winexe /optimize /r:System.Core.dll /r:System.Web.Extensions.dll "/out:$exe" $source 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not build docker-port-sync: $out" }

        if ($Mode -eq "portproxy") {
            # portproxy needs the IP Helper service
            Set-Service iphlpsvc -StartupType Automatic
            Start-Service iphlpsvc -ErrorAction SilentlyContinue
        }

        $ipFile = Join-Path $InstallDir "bin\wsl-ip.txt"
        $taskAction = New-ScheduledTaskAction -Execute $exe -Argument "--mode $Mode --state `"$StateDir`" --wsl-ip-file `"$ipFile`""
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $PortsTask -Description "Opens published Docker ports like on Linux (wsl-docker-engine)" `
            -Action $taskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings (New-TaskSettings) | Out-Null
        Start-ScheduledTask -TaskName $PortsTask
    }

    # ---- Shared install (all users) or per-user -----------------------------------------
    if ($AllUsers) {
        Install-SharedFiles
        $relay = Join-Path $SharedBin "docker-pipe-relay.exe"
        $configFile = Join-Path $ProgramDir "config.json"
    } else {
        Remove-SharedFiles   # switching from all users back to per-user
        $relay = Join-Path $InstallDir "bin\docker-pipe-relay.exe"
        $configFile = Join-Path $InstallDir "config.json"
    }

    # ---- Start task for the relay (runs as the user that owns the distro) ----------
    # Logs and the WSL IP file stay in the owner's folder (the relay runs as the owner).
    $relayArgs = "--distro $Distro --config `"$configFile`" --wsl-ip-file `"$(Join-Path $InstallDir 'bin\wsl-ip.txt')`"" +
                 " --log `"$(Join-Path $InstallDir 'bin\docker-pipe-relay.log')`""
    $taskAction = New-ScheduledTaskAction -Execute $relay -Argument $relayArgs
    if ($StartAtBoot) {
        # Servers: at boot, without anyone signing in ("S4U": no password stored)
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType S4U -RunLevel Limited
    } else {
        # PCs: when this user signs in
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
        $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
    }
    Register-ScheduledTask -TaskName $RelayTask -Description "Starts Docker (WSL distro '$Distro') and \\.\pipe\docker_engine (wsl-docker-engine)" `
        -Action $taskAction -Trigger $trigger -Principal $principal -Settings (New-TaskSettings) | Out-Null

    Write-Result "OK"
}
catch {
    Write-Result ("ERROR: " + $_.Exception.Message)
    exit 1
}
