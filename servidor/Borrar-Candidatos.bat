@echo off
chcp 65001 >nul
rem Borra lo marcado con SI en candidatos-borrar.csv (muestra vista previa y pide confirmacion)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Borrar-Candidatos.ps1"
echo.
pause
