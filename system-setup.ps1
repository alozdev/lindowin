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
    [string]$ResultFile              # where to write OK / the error (the window is hidden)
)

$ErrorActionPreference = "Stop"
$ProgramDir = Join-Path $env:ProgramFiles "wsl-docker-engine"
$StateDir = Join-Path $env:ProgramData "wsl-docker-engine"
$RelayTask = "wsl-docker-engine"
$PortsTask = "wsl-docker-engine-ports"
$Group = "docker-users"
$GroupMarker = Join-Path $StateDir "created-docker-users-group"

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

function Stop-Tasks {
    foreach ($t in $RelayTask, $PortsTask) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
        }
    }
    Get-Process docker-port-sync -ErrorAction SilentlyContinue | Stop-Process -Force
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
        Remove-Item -Recurse -Force $ProgramDir, $StateDir -ErrorAction SilentlyContinue
        Write-Result "OK"
        return
    }

    if (-not $InstallDir -or -not $UserName) { throw "InstallDir and UserName are required" }
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
    Remove-PortRules   # start clean; the service recreates the rules for running containers

    if ($Mode -ne "local") {
        $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        $source = Join-Path $InstallDir "installer\ports\docker-port-sync.cs"
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

    # ---- Start task for the relay (runs as the user that owns the distro) ----------
    $relay = Join-Path $InstallDir "bin\docker-pipe-relay.exe"
    $relayArgs = "--distro $Distro --wsl-ip-file `"$(Join-Path $InstallDir 'bin\wsl-ip.txt')`""
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
