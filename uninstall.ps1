<#
.SYNOPSIS
  Removes wsl-docker-engine from Windows.

.DESCRIPTION
  Removes the Windows side: docker.exe, compose/buildx plugins, the pipe relay,
  the sign-in launcher, and the PATH / environment changes.

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
Write-Host "wsl-docker-engine uninstaller" -ForegroundColor White

if ($RemoveDistro -and -not $Yes) {
    Write-Host ""
    Write-Host "This will DELETE the WSL distro '$distro' with all its containers, images and volumes." -ForegroundColor Yellow
    Write-Host "(Data in folders you bind-mounted from Windows, like ./data, is not touched.)" -ForegroundColor Yellow
    $answer = Read-Host "Type the distro name to confirm"
    if ($answer -ne $distro) { Write-Host "Cancelled."; return }
}

Get-Process docker-pipe-relay -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Ok "Pipe relay stopped"

$launcher = Join-Path ([Environment]::GetFolderPath("Startup")) "wsl-docker-engine.vbs"
if (Test-Path $launcher) { Remove-Item $launcher -Force }
Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "wsl-docker-engine" -ErrorAction SilentlyContinue
Write-Ok "Sign-in launcher removed"

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
