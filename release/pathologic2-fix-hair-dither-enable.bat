@echo off
rem Pathologic 2 hair dither fix: turn ON. Put the mod files into the game folder and double-click this file.
title Pathologic 2 hair dither fix - enable
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pathologic2-fix-hair-dither.ps1" -Apply -Interactive %*
if errorlevel 1 (
    echo.
    echo FAILED: see the message above. Nothing was changed.
) else (
    echo.
    echo Done. Start the game as usual.
)
echo.
pause
