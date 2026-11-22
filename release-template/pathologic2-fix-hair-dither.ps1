# Pathologic 2 hair dither fix: makes soft hair edges (dithered shaders) smooth under TAA/DLAA.
# Players: put the files into the game folder and double-click pathologic2-fix-hair-dither-enable.bat
# (pathologic2-fix-hair-dither-disable.bat turns it off). See pathologic2-fix-hair-dither-README.md.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File pathologic2-fix-hair-dither.ps1            # show the state only
#   powershell -NoProfile -ExecutionPolicy Bypass -File pathologic2-fix-hair-dither.ps1 -Apply     # turn the fix on
#   powershell -NoProfile -ExecutionPolicy Bypass -File pathologic2-fix-hair-dither.ps1 -Restore   # back to the original file
#
# The script changes Pathologic_Data\globalgamemanagers.assets. It knows the exact bytes of that file for each supported
# game version (built in below by build.ps1): it recognizes the file by hashes, writes the prepared shader data and checks
# the hash of the result. Restoring writes the original bytes back, so no backup file is needed.
# A file it does not recognize (another game version, another tool) is never touched.
param(
    [switch]$Apply,
    [switch]$Restore,
    [switch]$Interactive,  # set by the .bat files: folder dialog if the game is not found
    [string]$GameDir,
    [string]$File          # another file instead of <Game>\Pathologic_Data\globalgamemanagers.assets (for testing)
)
$ErrorActionPreference = 'Stop'
# Players run this from a .bat: a short message instead of a PowerShell stack trace, exit code 1 for the .bat
trap { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$ModVersion = '1.2.0'
#@@DATA@@ (build.ps1 puts $Builds and $Payload here)
if (-not (Get-Variable -Name Builds -Scope Script -ErrorAction SilentlyContinue)) {
    throw ('This is the source template without game data, it cannot patch anything. Use the built release: ' +
        'Pathologic2HairDitherFix-<version>.zip from the GitHub releases, or dist\ after build.ps1.')
}

function Assert-GameClosed {
    if (Get-Process -Name Pathologic -ErrorAction SilentlyContinue) { throw 'The game is running; close it first.' }
}

function Test-GameDir([string]$dir) {
    return $dir -and (Test-Path -LiteralPath (Join-Path $dir 'Pathologic_Data\globalgamemanagers.assets'))
}

function Find-GameDir {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    # normally the script lies in the game folder; also try the folders above it
    $p = $PSScriptRoot
    for ($i = 0; $i -lt 3 -and $p; $i++) { $candidates.Add($p); $p = Split-Path $p }
    # Steam: main folder and all libraries from libraryfolders.vdf
    $steamRoots = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        $v = Get-ItemProperty $key -ErrorAction SilentlyContinue
        if ($v -and $v.SteamPath) { $steamRoots += ($v.SteamPath -replace '/', '\') }
        if ($v -and $v.InstallPath) { $steamRoots += $v.InstallPath }
    }
    foreach ($s in $steamRoots) {
        $libs = @($s)
        $vdf = Join-Path $s 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $vdf), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
        foreach ($lib in $libs) { $candidates.Add((Join-Path $lib 'steamapps\common\Pathologic')) }
    }
    # GOG Galaxy / offline installer
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -ErrorAction SilentlyContinue)) {
        $v = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($v -and $v.gameName -like 'Pathologic 2*' -and $v.path) { $candidates.Add($v.path) }
    }
    foreach ($d in $candidates) { if (Test-GameDir $d) { return (Resolve-Path -LiteralPath $d).Path } }
    return $null
}

function Select-GameDir {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pathologic 2 was not found. Select the game folder (the one with Pathologic.exe).'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'Cancelled: no game folder selected.' }
    if (-not (Test-GameDir $dlg.SelectedPath)) {
        throw "Not a Pathologic 2 folder (no Pathologic_Data\globalgamemanagers.assets): $($dlg.SelectedPath)"
    }
    return $dlg.SelectedPath
}

function Get-Sha256([byte[]]$data) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($data)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# Hash of the file with the shader data blanked out: identifies the game version whatever state the shaders are in
function Get-SkeletonHash([byte[]]$data, $build) {
    $copy = [byte[]]$data.Clone()
    foreach ($r in $build.Regions) {
        [Array]::Clear($copy, $r.LenPos, 4)
        [Array]::Clear($copy, $r.BlobPos, $r.Length)
    }
    return Get-Sha256 $copy
}

function Get-PayloadBytes {
    $packed = [Convert]::FromBase64String(($Payload -replace '\s', ''))
    $in = New-Object IO.MemoryStream(, $packed)
    $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    try { $gz.CopyTo($out); return , $out.ToArray() } finally { $gz.Dispose(); $in.Dispose() }
}

"Pathologic 2 hair dither fix $ModVersion"
if ($File) {
    $target = $File
} else {
    if (-not $GameDir) {
        $GameDir = Find-GameDir
        if (-not $GameDir) {
            if ($Interactive) { $GameDir = Select-GameDir }
            else { throw 'Pathologic 2 not found. Pass -GameDir "<folder with Pathologic.exe>".' }
        }
    }
    if (-not (Test-GameDir $GameDir)) { throw "Not a Pathologic 2 folder (no Pathologic_Data\globalgamemanagers.assets): $GameDir" }
    $target = Join-Path $GameDir 'Pathologic_Data\globalgamemanagers.assets'
}
if (-not (Test-Path -LiteralPath $target)) { throw "File not found: $target" }
"File: $target"

$bytes = [IO.File]::ReadAllBytes($target)
$build = $null
foreach ($b in $Builds) {
    if ($b.Size -eq $bytes.Length -and (Get-SkeletonHash $bytes $b) -eq $b.Skeleton) { $build = $b; break }
}
if (-not $build) {
    $known = ($Builds | ForEach-Object { $_.Game }) -join ', '
    throw ("This game file is not one the mod knows (supported game versions: $known). " +
        'If the game was updated, look for a newer version of the mod. If the file was changed by another tool, ' +
        'verify the game files in Steam first. Nothing was changed.')
}
$hash = Get-Sha256 $bytes
$state = if ($hash -eq $build.Patched) { 'ON' } elseif ($hash -eq $build.Original) { 'OFF (original file)' } else { 'unknown (shaders changed by another tool)' }
"Game version: $($build.Game)"
"Hair fix: $state"

if (-not $Apply -and -not $Restore) { 'Nothing changed (use -Apply or -Restore).'; return }
$wantHash = if ($Apply) { $build.Patched } else { $build.Original }
if ($hash -eq $wantHash) { 'Nothing to do.'; return }

$payloadBytes = Get-PayloadBytes
foreach ($r in $build.Regions) {
    if ($Apply) { $len = $r.NewLen; $from = $r.New } else { $len = $r.OrigLen; $from = $r.Orig }
    [BitConverter]::GetBytes([int]$len).CopyTo($bytes, $r.LenPos)
    [Array]::Copy($payloadBytes, $from, $bytes, $r.BlobPos, $r.Length)
}
if ((Get-Sha256 $bytes) -ne $wantHash) { throw 'Internal check failed: the result does not match the expected file. Nothing was changed.' }

Assert-GameClosed
try { [IO.File]::WriteAllBytes($target, $bytes) }
catch [System.UnauthorizedAccessException] {
    throw "No write access to $target. Run the .bat file as administrator (right click > Run as administrator)."
}
if ($Apply) { 'Hair fix: ON' } else { 'Hair fix: OFF, the original file is back' }
