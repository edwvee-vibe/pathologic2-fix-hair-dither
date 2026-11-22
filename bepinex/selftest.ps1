# Self-test of the built BepInEx patcher (Core only, no BepInEx needed), run by ..\build.ps1 in a separate process.
# For every original file: on, on again (nothing to do), off (exact original), file held open by another process
# (nothing changed), unknown file (nothing changed).
param(
    [Parameter(Mandatory)][string]$Dll,
    [Parameter(Mandatory)][string]$Sources   # original files separated by '|' (powershell -File cannot pass arrays)
)
$ErrorActionPreference = 'Stop'
[void][Reflection.Assembly]::LoadFile($Dll)
$core = [Pathologic2HairDitherFix.Core]
$log = [Action[string]] { param($s) }
$tmp = Join-Path $env:TEMP 'pathologic2-fix-hair-dither-selftest.assets'
function Hash([string]$f) { $core::Sha256([IO.File]::ReadAllBytes($f)) }

foreach ($src in $Sources.Split('|')) {
    $h = Hash $src
    $b = $core::Builds | Where-Object { $_.Original -eq $h }
    if (-not $b) { throw "no build data for $src" }
    Copy-Item $src $tmp -Force
    if ($core::Run($tmp, $true, $log, $log) -ne 'ON' -or (Hash $tmp) -ne $b.Patched) { throw "on ($($b.Game))" }
    if ($core::Run($tmp, $true, $log, $log) -ne 'ON' -or (Hash $tmp) -ne $b.Patched) { throw "on again ($($b.Game))" }
    $fs = [IO.File]::Open($tmp, 'Open', 'Read', 'Read')
    try { if ($core::Run($tmp, $false, $log, $log) -ne 'in use') { throw "in use ($($b.Game))" } } finally { $fs.Dispose() }
    if ((Hash $tmp) -ne $b.Patched) { throw "in use changed the file ($($b.Game))" }
    if ($core::Run($tmp, $false, $log, $log) -ne 'OFF' -or (Hash $tmp) -ne $b.Original) { throw "off ($($b.Game))" }
    "BepInEx self-test passed: $($b.Game)"
}
$junk = New-Object byte[] 1000
[IO.File]::WriteAllBytes($tmp, $junk)
if ($core::Run($tmp, $true, $log, $log) -ne 'unknown' -or (Hash $tmp) -ne $core::Sha256($junk)) { throw 'unknown file' }
Remove-Item $tmp -Force -Confirm:$false
'BepInEx self-test passed: unknown file refused'
