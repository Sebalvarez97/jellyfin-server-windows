@echo off
rem Publica Seerr por zrok (abre Tunel-zrok.ps1 como administrador; Windows pide confirmacion).
rem El nombre reservado sale de config.local.json (Zrok.NombreSeerr).
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0Tunel-zrok.ps1\" -Servicio Seerr'"
