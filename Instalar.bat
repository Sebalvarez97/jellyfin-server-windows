@echo off
rem Instala y configura el servidor de medios (pide permisos de administrador).
rem Para solo revisar una instalacion existente sin cambiar nada: Instalar.bat -SoloRevisar
powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0instalador\Instalar-Servidor.ps1\" %*'"
