@echo off
chcp 65001 >nul
rem Copia los scripts del repositorio a la carpeta del servidor (no pisa config ni secretos)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Desplegar.ps1" %*
echo.
pause
