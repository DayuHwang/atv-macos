@echo off
rem atv-macos keeper: keeps the virtual Mac on the Apple TV running (JIT, relaunch).
cd /d "%~dp0"
title atv-macos keeper
"runtime313\python.exe" -u atv-macos\atv_keeper.py %*
pause
