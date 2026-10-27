<#
  Panel-Accion.ps1 - Las acciones del panel que necesitan administrador.
  Lo lanza Panel-Media.ps1 con "Ejecutar como administrador": Windows pide permiso cada vez.
  Solo acepta las acciones y los objetivos de estas listas; la cuenta de cada servicio
  esta escrita aca y no viene del navegador. Los nombres de las tareas salen de config.local.json.
  Deja el resultado en panel\estado\<Resultado> para que el panel lo muestre.
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('Iniciar', 'Reiniciar', 'CorregirCuenta')][string]$Accion,
  [Parameter(Mandatory = $true)][ValidateSet('JellyfinServer', 'Radarr', 'Sonarr', 'Prowlarr', 'Bazarr', 'qbittorrent', 'zrok-jellyfin', 'zrok-seerr')][string]$Objetivo,
  [Parameter(Mandatory = $true)][ValidatePattern('^accion-\d+\.json$')][string]$Resultado
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$archivo = Join-Path (Join-Path $PSScriptRoot 'estado') $Resultado

# Configuracion de la instalacion (el panel vive en <Raiz>\panel)
$raizPanel = Split-Path -Parent $PSScriptRoot
$usuarioDescargas = 'media'; $puertoQbit = 8080
if (Test-Path -LiteralPath (Join-Path $raizPanel 'Config-Media.ps1')) {
  . (Join-Path $raizPanel 'Config-Media.ps1')
  $cfg = Get-ConfigMedia (Join-Path $raizPanel 'config.local.json')
  $usuarioDescargas = [string]$cfg.UsuarioDescargas; $puertoQbit = [int]$cfg.Puertos.qBittorrent
}

# Con que cuenta tiene que correr cada servicio (igual que Mantenimiento-Media.ps1)
$cuentas = @{
  JellyfinServer = 'NT AUTHORITY\NetworkService'
  Radarr = 'NT AUTHORITY\LocalService'; Sonarr = 'NT AUTHORITY\LocalService'
  Prowlarr = 'NT AUTHORITY\LocalService'; Bazarr = 'NT AUTHORITY\LocalService'
}
# Tareas programadas que crean Nivel2-qBittorrent.ps1 y Tunel-zrok.ps1
$tareas = @{ 'qbittorrent' = "qBittorrent ($usuarioDescargas)"; 'zrok-jellyfin' = 'zrok Jellyfin'; 'zrok-seerr' = 'zrok Seerr' }

function Fin([bool]$ok, [string]$codigo, [string]$mensaje = '') {
  [ordered]@{ ok = $ok; codigo = $codigo; mensaje = $mensaje; accion = $Accion; objetivo = $Objetivo; fecha = (Get-Date).ToString('s') } |
    ConvertTo-Json | Set-Content -LiteralPath $archivo -Encoding UTF8
  exit $(if ($ok) { 0 } else { 1 })
}

function Wait-Servicio([string]$n) {
  try { (Get-Service -Name $n).WaitForStatus('Running', [TimeSpan]::FromSeconds(60)) } catch {}
  (Get-Service -Name $n).Status -eq 'Running'
}

try {
  if ($cuentas.ContainsKey($Objetivo)) {
    switch ($Accion) {
      'Iniciar' { Start-Service -Name $Objetivo }
      'Reiniciar' { Restart-Service -Name $Objetivo -Force }
      'CorregirCuenta' {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$Objetivo'"
        $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ StartName = $cuentas[$Objetivo]; StartPassword = '' }
        if ($r.ReturnValue -ne 0) { Fin $false 'cuenta' "Win32_Service.Change devolvio $($r.ReturnValue)" }
        Restart-Service -Name $Objetivo -Force
      }
    }
    if (Wait-Servicio $Objetivo) { Fin $true 'ok' } else { Fin $false 'no-arranco' "$((Get-Service -Name $Objetivo).Status)" }
  }

  # Tareas programadas: qBittorrent (usuario de descargas) y los tuneles de zrok
  $tarea = $tareas[$Objetivo]
  if ($Accion -eq 'CorregirCuenta') { Fin $false 'no-aplica' }
  if ($Accion -eq 'Reiniciar') {
    # Los tuneles de zrok no se reinician a la fuerza: dejan el nombre ocupado y los reintentos dan 429
    if ($Objetivo -ne 'qbittorrent') { Fin $false 'no-aplica' }
    # Primero se le pide que se cierre bien (guarda el estado de los torrents), despues se fuerza
    try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$puertoQbit/api/v2/app/shutdown" -Method Post -UseBasicParsing -TimeoutSec 10 } catch {}
    for ($i = 0; $i -lt 30 -and (Get-Process qbittorrent -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
    Stop-ScheduledTask -TaskName $tarea -ErrorAction SilentlyContinue
    Get-Process qbittorrent -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
  }
  Start-ScheduledTask -TaskName $tarea
  Start-Sleep -Seconds 8
  $estado = (Get-ScheduledTask -TaskName $tarea).State
  if ($estado -eq 'Running') { Fin $true 'ok' } else { Fin $false 'no-arranco' "tarea $estado" }
}
catch { Fin $false 'error' $_.Exception.Message }
