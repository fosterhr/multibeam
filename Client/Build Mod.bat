@echo off
title MultiBeam - Build Mod
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-mod.ps1"
echo.
pause
