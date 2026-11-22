# Install the BepInEx variant: copies dist\Pathologic2HairDitherFix.dll to <Game>\BepInEx\patchers\pathologic2-fix-hair-dither\.
# The patcher puts the fix into globalgamemanagers.assets at the next game start.
# -Uninstall first writes the original globalgamemanagers.assets back (with the same DLL), then removes the patcher folder
# (the config BepInEx\config\pathologic2.hairdither.cfg stays).
# Example: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-GameDir ...] [-Uninstall]
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Pathologic",
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$target = Join-Path $GameDir 'BepInEx\patchers\pathologic2-fix-hair-dither'
$dll = Join-Path $PSScriptRoot 'dist\Pathologic2HairDitherFix.dll'
$assets = Join-Path $GameDir 'Pathologic_Data\globalgamemanagers.assets'

if (Get-Process -Name Pathologic -ErrorAction SilentlyContinue) { throw 'The game is running; close it first.' }

if ($Uninstall) {
    $installed = Join-Path $target 'Pathologic2HairDitherFix.dll'
    $use = if (Test-Path $installed) { $installed } elseif (Test-Path $dll) { $dll } else { $null }
    if ($use) {
        # separate process: the loaded DLL would stay locked in this one
        & powershell -NoProfile -Command "[void][Reflection.Assembly]::LoadFile('$use'); [Pathologic2HairDitherFix.Core]::Run('$assets', `$false, [Action[string]]{ param(`$s) Write-Host `$s }, [Action[string]]{ param(`$s) Write-Warning `$s }) | Out-Null"
        if ($LASTEXITCODE -ne 0) { throw 'Restoring the original file failed; the patcher was left in place.' }
    }
    if (Test-Path $target) {
        Remove-Item -Recurse -Force $target -Confirm:$false
        "Removed: $target"
    } else {
        "Not installed: $target"
    }
    return
}

if (-not (Test-Path "$GameDir\BepInEx\core\BepInEx.Preloader.dll")) { throw "BepInEx 5 not found in the game folder: $GameDir" }
if (-not (Test-Path $dll)) { throw "$dll not found; run build.ps1 first" }
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item $dll $target -Force
Copy-Item (Join-Path $PSScriptRoot 'bepinex\README.md') $target -Force
"Installed: $target\Pathologic2HairDitherFix.dll (the fix is applied at the next game start)"
