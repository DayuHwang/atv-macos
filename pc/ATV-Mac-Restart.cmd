@echo off
rem atv-macos keeper, restarting the app first so changed settings (data\atv-macos.json) apply.
cd /d "%~dp0"
title atv-macos keeper
"runtime313\python.exe" -u atv-macos\atv_keeper.py --restart %*
pause
