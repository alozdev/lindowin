<#
.SYNOPSIS
  Removes lindowin (Linux Docker for Windows) from Windows.

.DESCRIPTION
  Removes the Windows side: docker.exe, compose/buildx plugins, the pipe relay,
  the start task, the port rules service with every firewall / portproxy rule it
  created, the docker-users group (if it created it), the PATH / environment
  changes, and restores your original .wslconfig.

  The WSL distro (with your containers, images and volumes) is KEPT unless you
  pass -RemoveDistro.

.EXAMPLE
  .\uninstall.ps1
.EXAMPLE
  .\uninstall.ps1 -RemoveDistro
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\wsl-docker-engine"),
    # Also delete the WSL distro and EVERYTHING inside it (containers, images, volumes)
    [switch]$RemoveDistro,
    # Do not ask for confirmation
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

function Write-Ok($msg) { Write-Host "    OK  $msg" -ForegroundColor Green }

$distro = "docker"
$pluginHashes = @()
$config = Join-Path $InstallDir "config.json"
if (Test-Path $config) {
    try {
        $c = Get-Content $config -Raw | ConvertFrom-Json
        if ($c.distro) { $distro = $c.distro }
        if ($c.pluginHashes) { $pluginHashes = @($c.pluginHashes) }
    } catch { }
}

Write-Host ""
Write-Host "lindowin uninstaller" -ForegroundColor White

if ($RemoveDistro -and -not $Yes) {
    Write-Host ""
    Write-Host "This will DELETE the WSL distro '$distro' with all its containers, images and volumes." -ForegroundColor Yellow
    Write-Host "(Data in folders you bind-mounted from Windows, like ./data, is not touched.)" -ForegroundColor Yellow
    $answer = Read-Host "Type the distro name to confirm"
    if ($answer -ne $distro) { Write-Host "Cancelled."; return }
}

Get-Process docker-pipe-relay -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Ok "Pipe relay stopped"

# Admin part: start task, port rules service, firewall / portproxy rules, docker-users group
$setupScript = Join-Path $InstallDir "installer\system-setup.ps1"
if (Test-Path $setupScript) {
    Write-Host "    Windows will ask for administrator permission once (to remove tasks and firewall rules)."
    $result = Join-Path ([IO.Path]::GetTempPath()) ("wsl-docker-engine-uninstall-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$setupScript`"", "-Action", "Uninstall", "-ResultFile", "`"$result`"")
    $id = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    try {
        if ($id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden -Wait
        } else {
            Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -Wait
        }
    } catch { }
    if ((Test-Path $result) -and (Get-Content $result -Raw).Trim() -eq "OK") {
        Write-Ok "Start task, port rules and docker-users group removed"
    } else {
        Write-Host "    !   Could not remove the start task / firewall rules (administrator permission needed)." -ForegroundColor Yellow
        Write-Host "        Run the uninstaller again and accept the prompt." -ForegroundColor Yellow
    }
    Remove-Item $result -ErrorAction SilentlyContinue
}

$launcher = Join-Path ([Environment]::GetFolderPath("Startup")) "wsl-docker-engine.vbs"
if (Test-Path $launcher) { Remove-Item $launcher -Force }
Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "wsl-docker-engine" -ErrorAction SilentlyContinue

# Put back the user's original .wslconfig if the installer turned on mirrored networking
$wslconfig = Join-Path $env:USERPROFILE ".wslconfig"
$backup = Join-Path $InstallDir "wslconfig.original"
$noFile = Join-Path $InstallDir "wslconfig.original.none"
if (Test-Path $noFile) {
    Remove-Item $wslconfig -Force -ErrorAction SilentlyContinue
    Write-Ok ".wslconfig removed (it did not exist before). Takes effect after: wsl --shutdown"
} elseif (Test-Path $backup) {
    Copy-Item $backup $wslconfig -Force
    Write-Ok ".wslconfig restored. Takes effect after: wsl --shutdown"
}

$bin = Join-Path $InstallDir "bin"
$path = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = @($path -split ";" | Where-Object { $_ -and $_.TrimEnd("\") -ne $bin.TrimEnd("\") })
[Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
if ([Environment]::GetEnvironmentVariable("COMPOSE_CONVERT_WINDOWS_PATHS", "User") -eq "1") {
    [Environment]::SetEnvironmentVariable("COMPOSE_CONVERT_WINDOWS_PATHS", $null, "User")
}
Write-Ok "PATH and environment restored"

# Plugins: only remove them if they are the same files this tool installed
$configDir = if ($env:DOCKER_CONFIG) { $env:DOCKER_CONFIG } else { Join-Path $env:USERPROFILE ".docker" }
$plugins = Join-Path $configDir "cli-plugins"
foreach ($name in "docker-compose.exe", "docker-buildx.exe") {
    $p = Join-Path $plugins $name
    if ((Test-Path $p) -and $pluginHashes -contains (Get-FileHash -Algorithm SHA256 $p).Hash.ToLowerInvariant()) {
        Remove-Item $p -Force
    }
}
Write-Ok "docker compose / buildx plugins removed (only the ones this tool installed)"

if (Test-Path $InstallDir) {
    Set-Location $env:USERPROFILE
    Remove-Item -Recurse -Force $InstallDir
}
Write-Ok "Program files removed ($InstallDir)"

if ($RemoveDistro) {
    & wsl.exe --unregister $distro | Out-Null
    Write-Ok "WSL distro '$distro' deleted"
} else {
    Write-Host ""
    Write-Host "The WSL distro '$distro' was kept (your containers, images and volumes are still there)."
    Write-Host "To delete it too:  wsl --unregister $distro"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
