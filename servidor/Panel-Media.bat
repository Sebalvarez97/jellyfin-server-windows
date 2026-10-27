@echo off
rem Abre el panel del servidor de medios (solo en esta PC: 127.0.0.1, sin administrador).
rem Si ya esta abierto, abre otra ventana del mismo. Se apaga solo al cerrar la ventana.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0panel\Panel-Media.ps1"
