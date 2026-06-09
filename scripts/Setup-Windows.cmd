@echo off
setlocal

REM Tiny launcher for Setup-Windows.ps1
REM Zero-friction: double-click or run from command line.
REM Always uses Bypass + NoProfile for fresh machines.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Windows.ps1" %* -PauseOnExit

endlocal
