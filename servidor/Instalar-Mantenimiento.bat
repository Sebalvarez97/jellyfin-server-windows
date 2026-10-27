@echo off
rem Abre Instalar-Mantenimiento.ps1 como administrador (Windows pide confirmacion)
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0Instalar-Mantenimiento.ps1\"'"
