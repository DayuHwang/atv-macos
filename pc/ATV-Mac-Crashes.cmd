@echo off
rem atv-macos: pull and summarise the app's recent crash and memory reports from the Apple TV.
cd /d "%~dp0"
title atv-macos crashes
"runtime313\python.exe" -u atv-macos\atv_keeper.py --crashes %*
pause
