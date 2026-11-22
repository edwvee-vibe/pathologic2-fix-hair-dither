# Pathologic 2: fix for checkerboard hair

Soft hair edges (`*_Hair_Fade` materials), eyelashes and some bodies are rendered with the
`Pathologic/Universal Dithered` and `Pathologic/Universal Metallic Dithered` shaders. Instead of blending transparency,
these shaders discard pixels against a noise threshold (Interleaved Gradient Noise), relying on TAA to average it out.
The noise is animated via `_Time.x` (time/20) and barely changes between frames, so neither TAA nor DLAA smooths it:
a static pattern remains. The fix switches the noise to `_Time.y` (time): it changes every frame, and anti-aliasing
turns it into a smooth semi-transparent edge. Works best with DLAA.

## Requirements

- **Pathologic 2** for Windows, game version **2.1.31648** (current Steam version) or 2.1.31563.
  Other versions are recognized as unknown and left untouched.
- Windows 10 or 11. Nothing else to install: the fix runs on the built-in Windows PowerShell 5.1. No BepInEx needed.
- The fix changes one game file, `Pathologic_Data\globalgamemanagers.assets` (only the two shaders inside it; the file
  size stays the same). Saves are not touched.

## Installation

1. Close the game.
2. Extract `Pathologic2HairDitherFix-<version>.zip` into the game folder (the one with `Pathologic.exe`).
   All mod files start with `pathologic2-fix-hair-dither`.
3. Double-click **`pathologic2-fix-hair-dither-enable.bat`**.
4. A console window shows what was done and ends with `Done.` Press any key to close it and start the game.

If the files are not in the game folder, the game is searched for in Steam libraries and GOG; if it is still not found,
a dialog asks for the folder with `Pathologic.exe`.

## Uninstall

Double-click **`pathologic2-fix-hair-dither-disable.bat`** (game closed). It writes back the exact original bytes,
so no backup file is needed. Then delete the `pathologic2-fix-hair-dither*` files. Verifying the game files in Steam
also restores the original.

## After a game update

An update or a Steam file verification replaces the file and removes the fix. Run the enable file again. If the update
changed the file itself, the mod reports an unknown game version and changes nothing: wait for a new version of the mod.

## Troubleshooting

- **"Windows protected your PC"**: Windows warns about `.bat` files from downloaded archives. Click
  *More info* > *Run anyway*, or open the archive's *Properties* and tick *Unblock* before extracting.
- **"No write access"**: the game is in a protected folder. Right-click the `.bat` file > *Run as administrator*.
- **"The game is running"**: close Pathologic 2 first.
- **"This game file is not one the mod knows"**: another game version, or the file was changed by another tool.
  Nothing was changed. Verify the game files in Steam and try again; if that does not help, the mod needs an update.

## Command line

```
powershell -NoProfile -ExecutionPolicy Bypass -File pathologic2-fix-hair-dither.ps1            # show the state only
powershell -NoProfile -ExecutionPolicy Bypass -File pathologic2-fix-hair-dither.ps1 -Apply     # fix on
powershell -NoProfile -ExecutionPolicy Bypass -File pathologic2-fix-hair-dither.ps1 -Restore   # original file back
```
`-GameDir "<folder>"` skips the search.

## How it works

The release script contains, for every supported game version, the original and the patched shader data, their
positions in the file and SHA-256 hashes of the original and the patched file. It recognizes the game version by the
hash of the file with the shader data blanked out, writes the prepared bytes and checks that the result has exactly the
expected hash before saving. Files it does not recognize are never written.

The patched shaders themselves: in each of the 112 pixel shaders, 2 bits are changed in the `cb1[0].x` operand of an
`add` instruction (`_Time` from `UnityPerCamera`) to `.y`, the DXBC container checksum is recomputed (D3D11 verifies
it), and the shader blob is recompressed with LZ4 and written back in place with the remainder zero-filled (Unity reads
exactly `compressedLength` bytes).

## BepInEx variant

`Pathologic2HairDitherFix-BepInEx-<version>.zip` (needs BepInEx 5 x64): a preloader patcher
`BepInEx\patchers\pathologic2-fix-hair-dither\Pathologic2HairDitherFix.dll` with the same data. At every game start it
checks `globalgamemanagers.assets` and writes the fix in (so it comes back by itself after a game update), or the
original back with `Enabled = false` in `BepInEx\config\pathologic2.hairdither.cfg`. The result is in `BepInEx\LogOutput.log`:
`Pathologic 2 Hair Dither Fix 1.2.0: Enabled=True, state ON`. Don't use it together with the `.bat` variant:
the patcher would undo `disable.bat` at the next start.

## For developers (source folder)

Build requirements: Windows PowerShell 5.1, .NET SDK (`dotnet`), BepInEx 5 in the game folder (references for the
patcher DLL), `d3dcompiler_47.dll` (part of Windows). At least one original `globalgamemanagers.assets` per supported
game version: in `backup\` as `globalgamemanagers.assets.<game version>`, or the installed game's file if it is unpatched.

| File | Role | In a release? |
|---|---|---|
| `HairDither.cs` | Shader patching code, compiled by `Add-Type` (see below) | no, build only |
| `patch.ps1` | Patches one file with `HairDither.cs`; used by `build.ps1`, also usable by hand | no |
| `build.ps1` | Makes the data and both release archives, self-tests them | no |
| `release\pathologic2-fix-hair-dither.ps1` | Template of the release script: game search, hash checks, byte copy; `#@@DATA@@` is replaced with the data | yes, with data |
| `release\*.bat`, `release\*-README.md` | Player files of the `.bat` variant | yes |
| `bepinex\src\Core.cs` | Same as the release script, in C#: reads the embedded data, checks hashes, copies bytes | yes, in the DLL |
| `bepinex\src\Patcher.cs` | BepInEx preloader entry point, config `Enabled` | yes, in the DLL |
| `bepinex\selftest.ps1` | Self-test of the built DLL | no |
| `install.ps1` | Installs / uninstalls the BepInEx variant into the local game | no |

`HairDither.cs` is only needed to produce the patched shaders; neither release contains it or needs a compiler:
- `Assets.Find`: finds a shader in `globalgamemanagers.assets` by its name followed by its custom editor name (the name
  alone also appears as another shader's Fallback) and reads the blob header after it: position, compressed and
  decompressed size, size of the `compressedBlob` vector.
- `Lz4`: decompresses the blob; `CompressOptimal` recompresses it with an optimal parse, so the result fits into the
  original space (Unity's own compression is slightly worse).
- `Dxbc`: finds the DXBC containers in the blob, finds the single `add` with a `cb1[0].<c>` operand in each pixel shader
  (`FindTimeAdds`), changes the component (`SetComponent`), checks and recomputes the container checksum
  (modified MD5, as `ComputeHashRetail` in DXC).
- `D3D`: disassembles every changed shader with `D3DDisassemble` before and after; exactly one line may differ, and only
  in the component letter (`CheckOneLineDiff`).

- `build.ps1` builds `dist\Pathologic2HairDitherFix-<version>.zip`: it takes every original
  `globalgamemanagers.assets` from `backup\` (`globalgamemanagers.assets.<game version>`) and the installed game,
  makes the patched version with `patch.ps1`, builds the data into `release\pathologic2-fix-hair-dither.ps1`
  (version: `$ModVersion` there) and self-tests the result on copies of every original. Then it writes the same data
  to `bepinex\obj\hairdither.data`, builds `bepinex\` (the patcher, data as an embedded resource) and self-tests it
  (`bepinex\selftest.ps1`), giving `dist\Pathologic2HairDitherFix-BepInEx-<version>.zip`.
- `install.ps1` puts the BepInEx variant into the local game; `-Uninstall` writes the original file back, then removes it.
- `patch.ps1` + `HairDither.cs`: the actual patcher (LZ4, DXBC checksum, bytecode parsing, verification via
  `D3DDisassemble` from `d3dcompiler_47.dll`). Can also use other noise components (`-Component z|w`).
  After a game update: keep a copy of the new original in `backup\` and rebuild.

| Component | Bad FPS (40-300) |
|---|---|
| `x` (game) | all |
| `y` (release) | 50-57 |
| `z` | 51-55, 99-115 |
| `w` | 52-54, 77-82, 148-172 |
