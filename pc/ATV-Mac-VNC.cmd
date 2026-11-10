@echo off
rem Opens the virtual Mac (on the Apple TV) in TigerVNC Viewer with the password filled in.
cd /d "%~dp0"
title atv-macos VNC
"runtime313\python.exe" -u atv-macos\atv_vnc.py %*
if errorlevel 1 pause
