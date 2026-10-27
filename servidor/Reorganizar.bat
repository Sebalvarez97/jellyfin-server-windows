@echo off
chcp 65001 >nul
echo 1. Generar propuesta: revisa Movies y Shows y arma renombrar.csv (no mueve nada)
echo 2. Ejecutar renombrar.csv: muestra la vista previa y pide SI
echo.
choice /c 12 /n /m "Elegi 1 o 2: "
if errorlevel 2 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Reorganizar.ps1"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Reorganizar.ps1" -Generar
)
echo.
pause
