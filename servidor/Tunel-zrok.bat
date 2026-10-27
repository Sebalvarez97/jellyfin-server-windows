@echo off
rem Abre Tunel-zrok.ps1 como administrador (Windows pide confirmacion)
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0Tunel-zrok.ps1\"'"
