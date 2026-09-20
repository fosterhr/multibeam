@echo off
title MultiBeam Server
cd /d "%~dp0"
echo Building multibeam-server.exe ...
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize+ /target:exe /out:multibeam-server.exe MultiBeamServer.cs
if errorlevel 1 (
  echo.
  echo Build failed. If the server is already running, close it first.
  pause
  exit /b 1
)
.\multibeam-server.exe
echo.
echo Server stopped.
pause
