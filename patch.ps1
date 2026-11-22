# Pathologic 2 hair dither fix (checked on 2.1.31563 and 2.1.31648, Unity 2022.3). Details in README.md next to this script.
# Players use enable.bat / disable.bat; this script does the work.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File patch.ps1                    # dry run: check everything, write nothing
#   powershell -NoProfile -ExecutionPolicy Bypass -File patch.ps1 -Apply             # write (_Time.y)
#   powershell -NoProfile -ExecutionPolicy Bypass -File patch.ps1 -Apply -Component z
#   powershell -NoProfile -ExecutionPolicy Bypass -File patch.ps1 -Restore           # restore the original from backup\
#
# -Component x is the game's behaviour (equivalent to the original). The game must be closed.
# -GameDir is found automatically (folders above this script, Steam libraries, GOG); -Interactive asks for it
# with a folder dialog if nothing is found.
param(
    [ValidateSet('x', 'y', 'z', 'w')][string]$Component = 'y',
    [switch]$Apply,
    [switch]$Restore,
    [switch]$Interactive,  # set by the .bat files: folder dialog if the game is not found
    [string]$GameDir,
    [string]$File,      # another file instead of <Game>\Pathologic_Data\globalgamemanagers.assets (for testing)
    [string]$OutFile    # write the result here instead of over the source (no backup is made then)
)
$ErrorActionPreference = 'Stop'
# Players run this from a .bat: a short message instead of a PowerShell stack trace, exit code 1 for the .bat
trap { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
$ModVersion = '1.1.0'
$bak = Join-Path $PSScriptRoot 'backup\globalgamemanagers.assets'
$shaders = @(
    @{ Name = 'Pathologic/Universal Dithered'; Editor = 'Shaders.UniversalEditor' },          # *_Fade hair, bodies
    @{ Name = 'Pathologic/Universal Metallic Dithered'; Editor = 'Shaders.UniversalMetallicEditor' } # eyelashes
)
$compChars = 'xyzw'

function Assert-GameClosed {
    if (Get-Process -Name Pathologic -ErrorAction SilentlyContinue) { throw 'The game is running; close it first.' }
}

function Test-GameDir([string]$dir) {
    return $dir -and (Test-Path -LiteralPath (Join-Path $dir 'Pathologic_Data\globalgamemanagers.assets'))
}

function Find-GameDir {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    # extracted into the game folder (or a subfolder of it)
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
    $candidates.Add('C:\Program Files (x86)\Steam\steamapps\common\Pathologic')
    foreach ($d in $candidates) { if (Test-GameDir $d) { return (Resolve-Path -LiteralPath $d).Path } }
    return $null
}

function Select-GameDir {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pathologic 2 was not found automatically. Select the game folder (the one with Pathologic.exe).'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'Cancelled: no game folder selected.' }
    if (-not (Test-GameDir $dlg.SelectedPath)) {
        throw "Not a Pathologic 2 folder (no Pathologic_Data\globalgamemanagers.assets): $($dlg.SelectedPath)"
    }
    return $dlg.SelectedPath
}

function Write-GameFile([scriptblock]$action) {
    try { & $action }
    catch [System.UnauthorizedAccessException] {
        throw "No write access ($($_.Exception.Message)). Run the .bat file as administrator (right click > Run as administrator)."
    }
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

if ($Restore) {
    # The patch never changes the file size, so a backup of a different size comes from another game build
    if ((Test-Path -LiteralPath $bak) -and (Get-Item -LiteralPath $bak).Length -eq (Get-Item -LiteralPath $target).Length) {
        Assert-GameClosed
        Write-GameFile { Copy-Item -LiteralPath $bak -Destination $target -Force }
        "Restored the original from $bak"
        return
    }
    if (Test-Path -LiteralPath $bak) { 'The backup is from another game version, not using it.' } else { 'No backup found.' }
    'Switching the shaders back to the game behaviour (_Time.x) instead.'
    $Component = 'x'
    $Apply = [switch]$true
}

Add-Type -TypeDefinition (Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'HairDither.cs'))

$bytes = [IO.File]::ReadAllBytes($target)
$newComp = $compChars.IndexOf($Component)
$wasOriginal = $true
$changed = $false

foreach ($sh in $shaders) {
    $loc = [HairDitherFix.Assets]::Find($bytes, $sh.Name, $sh.Editor)
    $raw = [HairDitherFix.Lz4]::Decompress($bytes, $loc.BlobPos, $loc.CompressedLen, $loc.DecompressedLen)
    $containers = [HairDitherFix.Dxbc]::FindContainers($raw)
    $bad = @($containers | Where-Object { -not [HairDitherFix.Dxbc]::ChecksumOk($raw, $_[0], $_[1]) }).Count
    if ($bad) { throw "$($sh.Name): checksum mismatch in $bad DXBC containers; wrong or corrupted file." }

    $ps = 0; $patched = 0; $current = @{}
    foreach ($c in $containers) {
        $comps = New-Object 'System.Collections.Generic.List[int]'
        $hits = [HairDitherFix.Dxbc]::FindTimeAdds($raw, $c[0], $comps)
        if ($null -eq $hits) { continue }
        $ps++
        if ($hits.Count -ne 1) { throw "$($sh.Name): pixel shader has $($hits.Count) add instructions with cb1[0], expected 1 (different game version?)" }
        $old = $comps[0]
        $current[$compChars[$old]] = 1 + [int]$current[$compChars[$old]]
        if ($old -ne 0) { $wasOriginal = $false }
        if ($old -eq $newComp) { continue }
        $before = [HairDitherFix.D3D]::Disassemble($raw, $c[0], $c[1])
        [HairDitherFix.Dxbc]::SetComponent($raw, $hits[0], $newComp)
        [HairDitherFix.Dxbc]::FixChecksum($raw, $c[0], $c[1])
        $after = [HairDitherFix.D3D]::Disassemble($raw, $c[0], $c[1])
        $err = [HairDitherFix.D3D]::CheckOneLineDiff($before, $after, $compChars[$old], $Component[0])
        if ($err) { throw "$($sh.Name): disassembler check failed: $err" }
        $patched++
    }
    $now = ($current.Keys | Sort-Object | ForEach-Object { "_Time.$_ x$($current[$_])" }) -join ', '
    "  $($sh.Name): DXBC $($containers.Count), pixel $ps, currently $now; changing $patched"
    if ($patched -eq 0) { continue }

    $packed = [HairDitherFix.Lz4]::CompressOptimal($raw, 16384)
    $check = [HairDitherFix.Lz4]::Decompress($packed, 0, $packed.Length, $raw.Length)
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$check, [byte[]]$raw)) { throw 'LZ4: compression is not reversible' }
    if ($packed.Length -gt $loc.VectorLen) {
        throw "$($sh.Name): compressed blob of $($packed.Length) bytes does not fit into $($loc.VectorLen). Verify game files in Steam and retry."
    }
    # the compressedBlob vector size stays the same: new data + zeros; Unity reads compressedLengths bytes
    [BitConverter]::GetBytes([int]$packed.Length).CopyTo($bytes, $loc.HeaderPos + 28)
    [Array]::Copy($packed, 0, $bytes, $loc.BlobPos, $packed.Length)
    [Array]::Clear($bytes, $loc.BlobPos + $packed.Length, $loc.VectorLen - $packed.Length)
    "    compressed: $($packed.Length) of $($loc.VectorLen) bytes (was $($loc.CompressedLen))"
    $changed = $true
}

if (-not $changed) { "Already _Time.$Component; nothing to change."; return }

# Verify the result: find again, decompress, check all checksums and components
foreach ($sh in $shaders) {
    $loc = [HairDitherFix.Assets]::Find($bytes, $sh.Name, $sh.Editor)
    $raw = [HairDitherFix.Lz4]::Decompress($bytes, $loc.BlobPos, $loc.CompressedLen, $loc.DecompressedLen)
    foreach ($c in [HairDitherFix.Dxbc]::FindContainers($raw)) {
        if (-not [HairDitherFix.Dxbc]::ChecksumOk($raw, $c[0], $c[1])) { throw "verify: bad DXBC checksum in $($sh.Name)" }
        $comps = New-Object 'System.Collections.Generic.List[int]'
        $hits = [HairDitherFix.Dxbc]::FindTimeAdds($raw, $c[0], $comps)
        if ($null -ne $hits -and $comps[0] -ne $newComp) { throw "verify: $($sh.Name) still has _Time.$($compChars[$comps[0]])" }
    }
}
"Verification passed, file size unchanged ($($bytes.Length) bytes)."

if (-not $Apply) { 'Dry run: file not written (use -Apply to write).'; return }

if ($OutFile) {
    [IO.File]::WriteAllBytes($OutFile, $bytes)
    "Written: $OutFile (_Time.$Component)"
    return
}
Assert-GameClosed
if ((Test-Path -LiteralPath $bak) -and $wasOriginal -and (Get-Item -LiteralPath $bak).Length -ne $bytes.Length) {
    # backup from another game build (after a game update): keep it aside and back up the current original
    $old = "$bak.{0:yyyyMMdd-HHmmss}.old" -f (Get-Date)
    Move-Item -LiteralPath $bak -Destination $old
    "Old backup from another game version moved to $old"
}
if (-not (Test-Path -LiteralPath $bak)) {
    if ($wasOriginal) {
        Write-GameFile {
            New-Item -ItemType Directory -Force (Split-Path $bak) | Out-Null
            Copy-Item -LiteralPath $target -Destination $bak
        }
        "Backup: $bak"
    } elseif ($Component -ne 'x') {
        Write-Warning 'The file was already modified, so no backup of the original was made. disable.bat (or -Restore) still switches back to the game behaviour.'
    }
}
Write-GameFile { [IO.File]::WriteAllBytes($target, $bytes) }
"Written: $target (_Time.$Component)"
