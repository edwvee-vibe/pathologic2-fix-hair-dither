# Build the release: dist\Pathologic2HairDitherFix-<version>.zip (version = $ModVersion in release-template\pathologic2-fix-hair-dither.ps1).
# The archive holds only files with the mod prefix, to be extracted straight into the game folder:
#   pathologic2-fix-hair-dither.ps1             the patcher with all data built in (no C#, no other files needed)
#   pathologic2-fix-hair-dither-enable.bat      double-click: fix on
#   pathologic2-fix-hair-dither-disable.bat     double-click: original file back
#   pathologic2-fix-hair-dither-README.md      short player instructions (release-template\, not the project README)
#
# How: for every ORIGINAL globalgamemanagers.assets found (backup\globalgamemanagers.assets* and the installed game),
# patch.ps1 + HairDither.cs make the _Time.y version; the shader blobs of both versions, their positions and the file
# hashes go into the release script. The release script then only recognizes the file by hash and copies bytes.
# A self-test runs the built script on copies of every original (state, -Apply, repeat, -Restore, unknown file).
#
# Example: powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 [-GameDir "D:\Games\Pathologic"] [-Sources a,b]
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Pathologic",
    [string[]]$Sources   # original globalgamemanagers.assets files; default: backup\globalgamemanagers.assets* + the game's file
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$prefix = 'pathologic2-fix-hair-dither'
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'stage'
$template = Join-Path $root "release-template\$prefix.ps1"
$shaders = @(
    @{ Name = 'Pathologic/Universal Dithered'; Editor = 'Shaders.UniversalEditor' },
    @{ Name = 'Pathologic/Universal Metallic Dithered'; Editor = 'Shaders.UniversalMetallicEditor' }
)

$m = [regex]::Match((Get-Content -Raw $template), "\`$ModVersion\s*=\s*'([^']+)'")
if (-not $m.Success) { throw "No `$ModVersion in $template" }
$version = $m.Groups[1].Value

Add-Type -TypeDefinition (Get-Content -Raw -Encoding UTF8 (Join-Path $root 'HairDither.cs'))

function Get-Sha256([byte[]]$data) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($data)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# Shader regions of a file: the compressedLengths field and the whole compressedBlob vector of each shader.
# Returns $null if the file is not an untouched original.
function Get-OriginalRegions([byte[]]$data) {
    $regions = @()
    foreach ($sh in $shaders) {
        $loc = [HairDitherFix.Assets]::Find($data, $sh.Name, $sh.Editor)
        # Unity writes the blob without padding; our patcher leaves zeros after a shorter blob
        if ($loc.CompressedLen -ne $loc.VectorLen) { return $null }
        $raw = [HairDitherFix.Lz4]::Decompress($data, $loc.BlobPos, $loc.CompressedLen, $loc.DecompressedLen)
        foreach ($c in [HairDitherFix.Dxbc]::FindContainers($raw)) {
            if (-not [HairDitherFix.Dxbc]::ChecksumOk($raw, $c[0], $c[1])) { return $null }
            $comps = New-Object 'System.Collections.Generic.List[int]'
            $hits = [HairDitherFix.Dxbc]::FindTimeAdds($raw, $c[0], $comps)
            if ($null -ne $hits -and ($hits.Count -ne 1 -or $comps[0] -ne 0)) { return $null }
        }
        $regions += @{ LenPos = $loc.HeaderPos + 28; BlobPos = $loc.BlobPos; Length = $loc.VectorLen }
    }
    return , $regions
}

function Get-SkeletonHash([byte[]]$data, $regions) {
    $copy = [byte[]]$data.Clone()
    foreach ($r in $regions) { [Array]::Clear($copy, $r.LenPos, 4); [Array]::Clear($copy, $r.BlobPos, $r.Length) }
    return Get-Sha256 $copy
}

# Game version for messages: from the backup file name (globalgamemanagers.assets.2.1.31563) or, for the installed
# game's file, from Player.log
$gameFile = Join-Path $GameDir 'Pathologic_Data\globalgamemanagers.assets'
$logVersion = $null
$log = Join-Path $env:USERPROFILE 'AppData\LocalLow\Ice-Pick Lodge\Pathologic 2\Player.log'
if (Test-Path $log) {
    $lm = [regex]::Match((Get-Content -Raw $log), '(\d+\.\d+\.\d+)-rel')
    if ($lm.Success) { $logVersion = $lm.Groups[1].Value }
}

if (-not $Sources) {
    $Sources = @(Get-ChildItem (Join-Path $root 'backup') -Filter 'globalgamemanagers.assets*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    if (Test-Path $gameFile) { $Sources += $gameFile }
}
$gameSkeleton = $null   # skeleton hash of the installed game's file, to give a backup without a version in its name the log version

$builds = @(); $seen = @{}
$payload = New-Object IO.MemoryStream
$tmp = Join-Path $env:TEMP "$prefix-build.assets"
foreach ($src in $Sources) {
    $data = [IO.File]::ReadAllBytes($src)
    $regions = Get-OriginalRegions $data
    if ($src -eq $gameFile -and $null -eq $regions) {
        # installed game is patched: still useful for the version label of a backup of the same build
        try {
            $r2 = @(); foreach ($sh in $shaders) { $l = [HairDitherFix.Assets]::Find($data, $sh.Name, $sh.Editor); $r2 += @{ LenPos = $l.HeaderPos + 28; BlobPos = $l.BlobPos; Length = $l.VectorLen } }
            $gameSkeleton = Get-SkeletonHash $data $r2
        } catch { }
    }
    if ($null -eq $regions) { "skip (not an original): $src"; continue }
    $hash = Get-Sha256 $data
    $skeleton = Get-SkeletonHash $data $regions
    if ($src -eq $gameFile) { $gameSkeleton = $skeleton }   # before the duplicate check: labels a backup of the same build
    if ($seen[$hash]) { "skip (same as $($seen[$hash])): $src"; continue }
    $seen[$hash] = $src

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'patch.ps1') -File $src -OutFile $tmp -Apply -Component y |
        ForEach-Object { "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "patch.ps1 failed on $src" }
    $patched = [IO.File]::ReadAllBytes($tmp)
    Remove-Item $tmp -Force -Confirm:$false
    if ($patched.Length -ne $data.Length -or (Get-SkeletonHash $patched $regions) -ne $skeleton) {
        throw "patch.ps1 changed bytes outside the shader regions in $src"
    }

    $outRegions = @()
    foreach ($r in $regions) {
        $o = $payload.Position; $payload.Write($data, $r.BlobPos, $r.Length)
        $n = $payload.Position; $payload.Write($patched, $r.BlobPos, $r.Length)
        $outRegions += @{ LenPos = $r.LenPos; BlobPos = $r.BlobPos; Length = $r.Length; Orig = $o; New = $n
            OrigLen = [BitConverter]::ToInt32($data, $r.LenPos); NewLen = [BitConverter]::ToInt32($patched, $r.LenPos) }
    }
    $vm = [regex]::Match([IO.Path]::GetFileName($src), 'assets\.(\d+\.\d+\.\d+)')
    $builds += @{ Src = $src; Game = $(if ($vm.Success) { $vm.Groups[1].Value } else { $null }); Size = $data.Length
        Skeleton = $skeleton; Original = $hash; Patched = (Get-Sha256 $patched); Regions = $outRegions }
}
if (-not $builds) { throw 'No original globalgamemanagers.assets found (backup\ or the game folder).' }
foreach ($b in $builds) {
    if (-not $b.Game -and $logVersion -and $b.Skeleton -eq $gameSkeleton) { $b.Game = $logVersion }
    if (-not $b.Game) {
        throw "Game version of $($b.Src) is unknown: rename it to globalgamemanagers.assets.<game version> (e.g. .2.1.31648)."
    }
    "build $($b.Game): $($b.Src)"
}

# Data block for the release script
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('$Builds = @(')
foreach ($b in ($builds | Sort-Object { [version]($_.Game -replace '^unknown$', '0.0') })) {
    [void]$sb.AppendLine("    @{ Game = '$($b.Game)'; Size = $($b.Size)")
    [void]$sb.AppendLine("        Skeleton = '$($b.Skeleton)'")
    [void]$sb.AppendLine("        Original = '$($b.Original)'")
    [void]$sb.AppendLine("        Patched  = '$($b.Patched)'")
    [void]$sb.AppendLine('        Regions = @(')
    foreach ($r in $b.Regions) {
        [void]$sb.AppendLine("            @{ LenPos = $($r.LenPos); BlobPos = $($r.BlobPos); Length = $($r.Length); OrigLen = $($r.OrigLen); NewLen = $($r.NewLen); Orig = $($r.Orig); New = $($r.New) }")
    }
    [void]$sb.AppendLine('        ) }')
}
[void]$sb.AppendLine(')')
$gzBuf = New-Object IO.MemoryStream
$gz = New-Object IO.Compression.GZipStream($gzBuf, [IO.Compression.CompressionLevel]::Optimal)
$gz.Write($payload.ToArray(), 0, [int]$payload.Length); $gz.Dispose()
$b64 = [Convert]::ToBase64String($gzBuf.ToArray())
[void]$sb.AppendLine("# shader blobs (original and patched, gzip + base64): $($payload.Length) bytes")
[void]$sb.AppendLine("`$Payload = @'")
for ($i = 0; $i -lt $b64.Length; $i += 120) { [void]$sb.AppendLine($b64.Substring($i, [Math]::Min(120, $b64.Length - $i))) }
[void]$sb.Append("'@")

$lines = Get-Content $template -Encoding UTF8
$marker = @($lines | Where-Object { $_ -like '#@@DATA@@*' })
if ($marker.Count -ne 1) { throw "Template must have exactly one #@@DATA@@ line" }
$script = (($lines | ForEach-Object { if ($_ -like '#@@DATA@@*') { $sb.ToString() } else { $_ } }) -join "`r`n") + "`r`n"
if ($script -match '[^\x00-\x7F]') { throw 'The release script must be ASCII (PowerShell 5.1 reads BOM-less files as ANSI).' }

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage -Confirm:$false }
New-Item -ItemType Directory -Force $stage | Out-Null
[IO.File]::WriteAllText("$stage\$prefix.ps1", $script, (New-Object Text.ASCIIEncoding))
foreach ($bat in "$prefix-enable.bat", "$prefix-disable.bat") {
    $b = [IO.File]::ReadAllBytes("$root\release-template\$bat")
    for ($i = 0; $i -lt $b.Length; $i++) {
        if ($b[$i] -gt 127) { throw "$bat has a non-ASCII byte at $i" }
        if ($b[$i] -eq 10 -and ($i -eq 0 -or $b[$i - 1] -ne 13)) { throw "$bat has an LF without CR at $i (cmd.exe needs CRLF)" }
    }
    Copy-Item "$root\release-template\$bat" $stage
}
Copy-Item "$root\release-template\$prefix-README.md" $stage
"Release script: $((Get-Item "$stage\$prefix.ps1").Length) bytes, game versions: $(($builds | % { $_.Game }) -join ', ')"

# Self-test of the built script on copies of the originals
$rel = "$stage\$prefix.ps1"
function Invoke-Release([string]$file, [string[]]$extra) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rel -File $file @extra | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
foreach ($b in $builds) {
    Copy-Item $b.Src $tmp -Force
    $r = Invoke-Release $tmp @();          if ($r.Code -ne 0 -or $r.Out -notmatch 'Hair fix: OFF') { throw "self-test state ($($b.Game)): $($r.Out)" }
    $r = Invoke-Release $tmp @('-Apply');  if ($r.Code -ne 0 -or (Get-Sha256 ([IO.File]::ReadAllBytes($tmp))) -ne $b.Patched) { throw "self-test apply ($($b.Game)): $($r.Out)" }
    $r = Invoke-Release $tmp @('-Apply');  if ($r.Code -ne 0 -or $r.Out -notmatch 'Nothing to do') { throw "self-test re-apply ($($b.Game)): $($r.Out)" }
    $r = Invoke-Release $tmp @('-Restore'); if ($r.Code -ne 0 -or (Get-Sha256 ([IO.File]::ReadAllBytes($tmp))) -ne $b.Original) { throw "self-test restore ($($b.Game)): $($r.Out)" }
    "self-test passed: $($b.Game)"
}
$junk = [byte[]]::new(1000); [IO.File]::WriteAllBytes($tmp, $junk)
$r = Invoke-Release $tmp @('-Apply')
if ($r.Code -ne 1 -or (Get-Sha256 ([IO.File]::ReadAllBytes($tmp))) -ne (Get-Sha256 $junk)) { throw "self-test unknown file: $($r.Out)" }
Remove-Item $tmp -Force -Confirm:$false
'self-test passed: unknown file refused'

# Release archive (files at the root: extracted straight into the game folder)
$zip = Join-Path $dist "Pathologic2HairDitherFix-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force -Confirm:$false }
# ZipArchive instead of Compress-Archive: PS 5.1 writes entry names with backslashes, which some unpackers mishandle.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in Get-ChildItem $stage) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $f.Name) | Out-Null
    }
} finally {
    $archive.Dispose()
}
"Release archive: $zip ($((Get-Item $zip).Length) bytes)"

# --- BepInEx variant: preloader patcher with the same data as an embedded resource ---
$bep = Join-Path $root 'bepinex'
$dataFile = Join-Path $bep 'obj\hairdither.data'
New-Item -ItemType Directory -Force (Split-Path $dataFile) | Out-Null
$fsData = [IO.File]::Create($dataFile)
try {
    $gzData = New-Object IO.Compression.GZipStream($fsData, [IO.Compression.CompressionLevel]::Optimal)
    $w = New-Object IO.BinaryWriter($gzData)
    $w.Write([int]$builds.Count)
    foreach ($b in $builds) {
        $w.Write([string]$b.Game); $w.Write([long]$b.Size)
        $w.Write([string]$b.Skeleton); $w.Write([string]$b.Original); $w.Write([string]$b.Patched)
        $w.Write([int]$b.Regions.Count)
        foreach ($r in $b.Regions) {
            foreach ($v in $r.LenPos, $r.BlobPos, $r.Length, $r.OrigLen, $r.NewLen, $r.Orig, $r.New) { $w.Write([int]$v) }
        }
    }
    $w.Write([int]$payload.Length); $w.Write($payload.ToArray())
    $w.Dispose()
} finally { $fsData.Dispose() }

& dotnet build "$bep\Pathologic2HairDitherFix.csproj" -c Release -nologo "-p:GameDir=$GameDir" "-p:Version=$version" `
    "-p:DataFile=$dataFile" "-p:OutDir=$bep\bin\Release\"
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed (exit code $LASTEXITCODE)" }
$dll = "$bep\bin\Release\Pathologic2HairDitherFix.dll"
Copy-Item $dll $dist -Force

& powershell -NoProfile -ExecutionPolicy Bypass -File "$bep\selftest.ps1" -Dll $dll -Sources (($builds | ForEach-Object { $_.Src }) -join '|')
if ($LASTEXITCODE -ne 0) { throw 'BepInEx self-test failed' }

$zip = Join-Path $dist "Pathologic2HairDitherFix-BepInEx-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force -Confirm:$false }
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    $p = "BepInEx/patchers/$prefix/"
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $dll, $p + 'Pathologic2HairDitherFix.dll') | Out-Null
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, "$bep\README.md", $p + 'README.md') | Out-Null
} finally {
    $archive.Dispose()
}
"Release archive (BepInEx): $zip ($((Get-Item $zip).Length) bytes)"
