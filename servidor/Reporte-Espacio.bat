@echo off
rem Genera el reporte de espacio y lo abre en el navegador (no borra nada)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Reporte-Espacio.ps1"
start "" "%~dp0Reporte-espacio.html"
