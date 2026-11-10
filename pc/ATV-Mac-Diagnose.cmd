@echo off
rem atv-macos: launch the app with the Apple TV log streaming, to see why a launch fails.
cd /d "%~dp0"
title atv-macos diagnose
"runtime313\python.exe" -u atv-macos\atv_keeper.py --diagnose %*
pause
