<#
  Instalar-Mantenimiento.ps1 - Crea las dos tareas programadas que ejecutan Mantenimiento-Media.ps1
  como SYSTEM. Hay que ejecutarlo como administrador: Instalar-Mantenimiento.bat lo pide solo.

    "Media - Arranque"        al iniciar Windows, 5 minutos despues: revisa y levanta lo caido
    "Media - Mantenimiento"   domingos 04:00 (o apenas se prenda la PC si estaba apagada):
                              actualiza Jellyfin, Bazarr, qBittorrent y Seerr, y revisa todo

  Se puede volver a ejecutar: reemplaza las tareas.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Mantenimiento-Media.ps1'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Hay que ejecutarlo como administrador (usa Instalar-Mantenimiento.bat).'
}
if (-not (Test-Path -LiteralPath $script)) { throw "No encontre $script" }

$sistema = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$ps = 'powershell.exe'

$tareas = @(
  @{ Nombre = 'Media - Arranque'; Modo = 'Salud'; Limite = 30
     Disparador = $(New-ScheduledTaskTrigger -AtStartup); Demora = 'PT5M'
     Descripcion = 'Revisa que el servidor de medios este corriendo y levanta lo caido. Log en C:\ProgramData\MediaStack\logs' },
  @{ Nombre = 'Media - Mantenimiento'; Modo = 'Completo'; Limite = 120
     Disparador = $(New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00'); Demora = $null
     Descripcion = 'Actualiza Jellyfin, Bazarr, qBittorrent y Seerr, y revisa el servidor de medios. Log en C:\ProgramData\MediaStack\logs' }
)

foreach ($t in $tareas) {
  if ($t.Demora) { $t.Disparador.Delay = $t.Demora }
  $accion = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Modo $($t.Modo)"
  $ajustes = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes $t.Limite)
  Register-ScheduledTask -TaskName $t.Nombre -Action $accion -Trigger $t.Disparador -Settings $ajustes `
    -Principal $sistema -Description $t.Descripcion -Force | Out-Null
  Write-Host "Tarea creada: $($t.Nombre)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Prueba: se ejecuta ahora el chequeo de salud...' -ForegroundColor Cyan
Start-ScheduledTask -TaskName 'Media - Arranque'
for ($i = 0; $i -lt 60 -and (Get-ScheduledTask -TaskName 'Media - Arranque').State -eq 'Running'; $i++) { Start-Sleep -Seconds 5 }
$estado = Get-Content -LiteralPath 'C:\ProgramData\MediaStack\ultimo-estado.json' -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
if ($estado) {
  foreach ($r in $estado.Resultados) {
    Write-Host ('  {0,-22} {1}  {2}' -f $r.Que, $(if ($r.Ok) { 'OK   ' } else { 'FALLA' }), $r.Detalle) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Yellow' })
  }
  Write-Host ''
  Write-Host "Log completo: $($estado.Log)"
}
else { Write-Host 'No se genero el resumen. Revisa C:\ProgramData\MediaStack\logs' -ForegroundColor Yellow }
