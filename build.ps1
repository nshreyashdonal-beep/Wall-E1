<#
.SYNOPSIS
    Builds Wall-E.exe from Wall-E.ps1 using the ps2exe module.

.DESCRIPTION
    Run this ONCE on Windows (PowerShell 5.1 or 7+) from the Wall-E folder.
    It installs the free/open-source 'ps2exe' module if missing, then
    compiles Wall-E.ps1 into Wall-E.exe with the app icon and no console
    window.

    The resulting Wall-E.exe is NOT fully standalone - it still needs its
    sibling folders (modules\, UI\, assets\) next to it, exactly like the
    .ps1 does. That's what makes the whole Wall-E folder "portable": zip up
    the folder (exe + modules + UI + assets) and it'll run on any Windows
    PC with .NET/PowerShell installed (built into Windows 10/11), no
    install step required.

.NOTES
    Run with: powershell.exe -ExecutionPolicy Bypass -File build.ps1
#>

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Write-Host "Wall-E build - creating portable .exe" -ForegroundColor Green

# 1. Ensure ps2exe is installed
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing ps2exe module (one-time)..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

# 2. Compile
$srcScript = Join-Path $root 'Wall-E.ps1'
$outExe    = Join-Path $root 'Wall-E.exe'
$iconFile  = Join-Path $root 'assets\icon.ico'

$ps2exeArgs = @{
    inputFile   = $srcScript
    outputFile  = $outExe
    noConsole   = $true
    title       = 'Wall-E'
    description = 'Movie snapshots as your desktop wallpaper'
    product     = 'Wall-E'
    version     = '1.0.0.0'
    requireAdmin = $false
}
if (Test-Path -LiteralPath $iconFile) {
    $ps2exeArgs['iconFile'] = $iconFile
}

Invoke-ps2exe @ps2exeArgs

if (Test-Path -LiteralPath $outExe) {
    Write-Host "`nBuilt: $outExe" -ForegroundColor Green
    Write-Host "The whole Wall-E folder (exe + modules + UI + assets) is your portable app." -ForegroundColor Green
    Write-Host "Zip that folder to share it - no installer needed." -ForegroundColor Green
} else {
    Write-Host "`nBuild did not produce an exe - check the errors above." -ForegroundColor Red
}
