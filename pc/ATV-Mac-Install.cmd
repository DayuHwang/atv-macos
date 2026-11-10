@echo off
rem atv-macos: sign the Apple TV app with your Apple ID and install it.
cd /d "%~dp0"
title atv-macos install
"runtime313\python.exe" -u atv-macos\atv_install.py %*
pause
