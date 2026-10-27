@echo off
rem Abre Nivel2-qBittorrent.ps1 como administrador (Windows pide confirmacion)
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0Nivel2-qBittorrent.ps1\"'"
