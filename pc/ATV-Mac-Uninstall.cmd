@echo off
rem Removes atv-macos: uninstalls the ATVMac app (and its macOS) from the Apple TV, deletes atv-sign credentials.
cd /d "%~dp0"
title atv-macos uninstall
"runtime313\python.exe" -u atv-macos\atv_uninstall.py %*
pause
