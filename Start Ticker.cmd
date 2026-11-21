@echo off
rem Ticker launcher for Windows. Double-click to open the ticker window.
rem It runs server.ps1 (in this folder) with Windows' built-in PowerShell.
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0server.ps1"
