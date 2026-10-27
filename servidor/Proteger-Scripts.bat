@echo off
rem Protege los scripts de esta carpeta: qBittorrent (usuario de descargas) y los servicios ya no pueden modificarlos.
rem Pide permiso de administrador (Windows pide confirmacion). Guarda un respaldo de los permisos antes.
rem Para volver atras: Proteger-Scripts.bat deshacer
set "EXTRA="
if /i "%~1"=="deshacer" set "EXTRA=-Deshacer"
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "Start-Process -FilePath '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0panel\Proteger-Scripts.ps1\" %EXTRA%'"
