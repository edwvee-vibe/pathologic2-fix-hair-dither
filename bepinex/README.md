# Pathologic 2 Hair Dither Fix (BepInEx)

Makes the crawling checkerboard pattern on hair edges much less visible. Best with DLAA.
For game version 2.1.31648 (current Steam version) and 2.1.31563. Needs BepInEx 5 x64.

## Enable

1. Install BepInEx 5 x64 into the game folder and start the game once.
2. Extract the archive into the game folder. The mod ends up in `BepInEx\patchers\pathologic2-fix-hair-dither\`.
3. Start the game. The fix is put in at every start, also after a game update.

## Disable

Open `BepInEx\config\pathologic2.hairdither.cfg`, set `Enabled = false` and start the game once.
The original game file is put back.

## Uninstall

Disable it (see above), then delete the `BepInEx\patchers\pathologic2-fix-hair-dither` folder.
