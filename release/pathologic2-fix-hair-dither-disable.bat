@echo off
rem Pathologic 2 hair dither fix: turn OFF, put back the original game file. Double-click this file.
title Pathologic 2 hair dither fix - disable
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pathologic2-fix-hair-dither.ps1" -Restore -Interactive %*
if errorlevel 1 (
    echo.
    echo FAILED: see the message above. Nothing was changed.
) else (
    echo.
    echo Done. The game is back to the original.
)
echo.
pause
