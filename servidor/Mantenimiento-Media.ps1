<#
  Mantenimiento-Media.ps1 - Mantenimiento del servidor de medios.
  Lo ejecutan dos tareas programadas como SYSTEM (las crea Instalar-Mantenimiento.bat):

    "Media - Arranque"            al iniciar Windows (+5 min): -Modo Salud
    "Media - Mantenimiento"       domingos 04:00:               -Modo Completo

  -Modo Salud     Revisa que todo este corriendo y levanta lo que este caido.
  -Modo Completo  Ademas actualiza lo que NO se actualiza solo y despues revisa de nuevo:
                    Jellyfin, Bazarr, qBittorrent (winget) y Seerr (imagen de Docker).
                  Radarr, Sonarr y Prowlarr NO se tocan: se actualizan solos.
  -SoloRevisar    No cambia nada: solo informa que haria.

  Log: C:\ProgramData\MediaStack\logs\  |  Resumen: C:\ProgramData\MediaStack\ultimo-estado.json
#>
param(
  [ValidateSet('Salud', 'Completo')][string]$Modo = 'Salud',
  [switch]$SoloRevisar
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Config-Media.ps1'); $cfg = Get-ConfigMedia
$P = $cfg.Puertos
$base = 'C:\ProgramData\MediaStack'
$dirLogs = Join-Path $base 'logs'
New-Item -ItemType Directory -Force -Path $dirLogs | Out-Null
$log = Join-Path $dirLogs ('{0}-{1:yyyyMMdd-HHmm}.log' -f $Modo.ToLower(), (Get-Date))
$resumen = New-Object System.Collections.Generic.List[object]

function Log([string]$t, [string]$nivel = 'INFO') {
  $linea = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $nivel, $t
  Add-Content -LiteralPath $log -Value $linea -Encoding UTF8
  Write-Host $linea
}

function Add-Resultado([string]$que, [bool]$ok, [string]$detalle) {
  $resumen.Add([pscustomobject]@{ Que = $que; Ok = $ok; Detalle = $detalle })
  Log ("{0}: {1} {2}" -f $que, $(if ($ok) { 'OK' } else { 'FALLA' }), $detalle) $(if ($ok) { 'INFO' } else { 'WARN' })
}

# --- Que hay en el stack ---
# Cuenta = con que usuario tiene que correr cada servicio (los instaladores a veces lo pisan al actualizar)
$servicios = @(
  @{ Nombre = 'Jellyfin'; Servicio = 'JellyfinServer'; Cuenta = $cfg.CuentaJellyfin; Url = "http://127.0.0.1:$($P.Jellyfin)/health" },
  @{ Nombre = 'Radarr';   Servicio = 'Radarr';         Cuenta = 'NT AUTHORITY\LocalService';   Url = "http://127.0.0.1:$($P.Radarr)/ping" },
  @{ Nombre = 'Sonarr';   Servicio = 'Sonarr';         Cuenta = 'NT AUTHORITY\LocalService';   Url = "http://127.0.0.1:$($P.Sonarr)/ping" },
  @{ Nombre = 'Prowlarr'; Servicio = 'Prowlarr';       Cuenta = 'NT AUTHORITY\LocalService';   Url = "http://127.0.0.1:$($P.Prowlarr)/ping" },
  @{ Nombre = 'Bazarr';   Servicio = 'Bazarr';         Cuenta = 'NT AUTHORITY\LocalService';   Url = "http://127.0.0.1:$($P.Bazarr)/" }
)
$tareas = @(
  @{ Nombre = 'qBittorrent'; Tarea = "qBittorrent ($($cfg.UsuarioDescargas))"; Url = "http://127.0.0.1:$($P.qBittorrent)/api/v2/app/version" }
)
if ($cfg.Zrok.Habilitado) {
  if ($cfg.Zrok.NombreJellyfin) { $tareas += @{ Nombre = 'zrok Jellyfin'; Tarea = 'zrok Jellyfin'; Url = $null } }
  if ($cfg.Zrok.NombreSeerr) { $tareas += @{ Nombre = 'zrok Seerr'; Tarea = 'zrok Seerr'; Url = $null } }
}
$winget = @(
  @{ Nombre = 'Jellyfin';    Id = 'Jellyfin.Server';         Servicio = 'JellyfinServer'; Extra = @() },
  @{ Nombre = 'Bazarr';      Id = 'Morpheus.Bazarr';         Servicio = 'Bazarr';         Extra = @('--location', 'C:\Bazarr') },
  @{ Nombre = 'qBittorrent'; Id = 'qBittorrent.qBittorrent'; Tarea = "qBittorrent ($($cfg.UsuarioDescargas))"; Extra = @() }
)
$S = $cfg.Seerr
$seerr = @{ Imagen = $S.Imagen; Contenedor = $S.Contenedor
  Run = @('run', '-d', '--name', $S.Contenedor, '--init', '--restart', 'unless-stopped', '-p', "$($P.Seerr):5055", '-e', "TZ=$($cfg.ZonaHoraria)", '-e', 'LOG_LEVEL=info', '-v', "$($S.Volumen):/app/config", $S.Imagen) }

function Test-Url([string]$url) {
  for ($i = 0; $i -lt 6; $i++) {
    try { $null = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10; return $true } catch {
      # Una respuesta 401/403 tambien significa que la app esta viva
      if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in 401, 403) { return $true }
    }
    Start-Sleep -Seconds 10
  }
  $false
}

# winget: como SYSTEM no esta en el PATH; se busca dentro del paquete App Installer
function Get-Winget {
  $c = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $d = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -Last 1
  if ($d -and (Test-Path -LiteralPath (Join-Path $d.FullName 'winget.exe'))) { return (Join-Path $d.FullName 'winget.exe') }
  $null
}

function Get-Docker {
  $p = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  & $p info --format '{{.ServerVersion}}' 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $p } else { $null }
}

# Deja el servicio con la cuenta correcta y corriendo
function Repair-Servicio($s) {
  $svc = Get-CimInstance Win32_Service -Filter "Name='$($s.Servicio)'" -ErrorAction SilentlyContinue
  if (-not $svc) { Add-Resultado "$($s.Nombre) (servicio)" $false 'el servicio no existe'; return }
  if ($svc.StartName -ne $s.Cuenta) {
    Log "$($s.Nombre): corre como $($svc.StartName), se vuelve a $($s.Cuenta)" 'WARN'
    if (-not $SoloRevisar) {
      $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ StartName = $s.Cuenta; StartPassword = '' }
      if ($r.ReturnValue -ne 0) { Log "$($s.Nombre): no se pudo cambiar la cuenta (codigo $($r.ReturnValue))" 'ERROR' }
      Restart-Service -Name $s.Servicio -Force -ErrorAction SilentlyContinue
    }
  }
  if ((Get-Service -Name $s.Servicio).Status -ne 'Running') {
    Log "$($s.Nombre): estaba detenido, se inicia" 'WARN'
    if (-not $SoloRevisar) { Start-Service -Name $s.Servicio -ErrorAction SilentlyContinue }
  }
}

function Repair-Tarea($t) {
  $tk = Get-ScheduledTask -TaskName $t.Tarea -ErrorAction SilentlyContinue
  if (-not $tk) { Add-Resultado $t.Nombre $false "no existe la tarea '$($t.Tarea)'"; return $false }
  if ($tk.State -ne 'Running') {
    Log "$($t.Nombre): la tarea no estaba corriendo, se inicia" 'WARN'
    if (-not $SoloRevisar) { Start-ScheduledTask -TaskName $t.Tarea; Start-Sleep -Seconds 15 }
  }
  $true
}

function Invoke-Salud {
  Log '--- Salud ---'
  foreach ($s in $servicios) {
    Repair-Servicio $s
    $vivo = Test-Url $s.Url
    $cuenta = (Get-CimInstance Win32_Service -Filter "Name='$($s.Servicio)'" -ErrorAction SilentlyContinue).StartName
    Add-Resultado $s.Nombre $vivo "servicio $((Get-Service $s.Servicio -ErrorAction SilentlyContinue).Status), cuenta $cuenta"
  }
  foreach ($t in $tareas) {
    if (-not (Repair-Tarea $t)) { continue }
    $estado = (Get-ScheduledTask -TaskName $t.Tarea).State
    $vivo = $(if ($t.Url) { Test-Url $t.Url } else { $estado -eq 'Running' })
    Add-Resultado $t.Nombre $vivo "tarea $estado"
  }
  $docker = Get-Docker
  if ($docker) {
    $estado = & $docker inspect -f '{{.State.Status}}' $seerr.Contenedor 2>$null
    if ($estado -ne 'running' -and -not $SoloRevisar) { & $docker start $seerr.Contenedor 2>&1 | Out-Null; Start-Sleep -Seconds 20 }
    Add-Resultado 'Seerr' (Test-Url "http://127.0.0.1:$($P.Seerr)/api/v1/status") "contenedor $estado"
  }
  else { Add-Resultado 'Seerr' $false 'Docker Desktop no esta corriendo (arranca cuando alguien inicia sesion)' }
  # Los indexadores que Prowlarr agrega a Radarr llegan con 3 seeders minimos: se suben a 5,
  # para que no elija un 4K que figura con seeders pero esta muerto
  try {
    $kR = ([xml](Get-Content -LiteralPath 'C:\ProgramData\Radarr\config.xml' -Raw)).Config.ApiKey
    $hR = @{ 'X-Api-Key' = $kR }; $uR = "http://127.0.0.1:$($P.Radarr)/api/v3"
    $ajustados = 0
    foreach ($ix in @(Invoke-RestMethod "$uR/indexer" -Headers $hR | ForEach-Object { $_ })) {
      $f = $ix.fields | Where-Object name -eq 'minimumSeeders'
      if (-not $f -or [int]$f.value -ge 5) { continue }
      if (-not $SoloRevisar) {
        $f | Add-Member -NotePropertyName value -NotePropertyValue 5 -Force
        $null = Invoke-RestMethod "$uR/indexer/$($ix.id)?forceSave=true" -Method Put -Headers $hR -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes(($ix | ConvertTo-Json -Depth 20)))
      }
      $ajustados++
    }
    if ($ajustados) { Log "Radarr: $ajustados indexador/es nuevos pasados a 5 seeders minimos" }
  }
  catch { Log "Radarr: no se pudieron revisar los seeders minimos ($($_.Exception.Message))" 'WARN' }

  $v = Get-Volume -DriveLetter $cfg.Raiz.Substring(0, 1)
  $pct = [math]::Round(100 * ($v.Size - $v.SizeRemaining) / $v.Size)
  Add-Resultado "Disco $($cfg.Raiz.Substring(0, 2))" ($pct -lt $cfg.Reporte.UmbralPct) ("{0}% usado, {1:N0} GB libres" -f $pct, ($v.SizeRemaining / 1GB))
}

function Invoke-Actualizaciones {
  Log '--- Actualizaciones ---'
  $wg = Get-Winget
  if (-not $wg) { Add-Resultado 'winget' $false 'no se encontro winget.exe'; return }
  foreach ($a in $winget) {
    $salida = (& $wg list --id $a.Id --exact --upgrade-available --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
    if ($salida -notmatch [regex]::Escape($a.Id)) { Log "$($a.Nombre): al dia"; continue }
    Log "$($a.Nombre): hay una version nueva"
    if ($SoloRevisar) { continue }
    if ($a.Servicio) { Stop-Service -Name $a.Servicio -Force -ErrorAction SilentlyContinue }
    if ($a.Tarea) { Stop-ScheduledTask -TaskName $a.Tarea -ErrorAction SilentlyContinue; Get-Process qbittorrent -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 5 }
    $argWg = @('upgrade', '--id', $a.Id, '--exact', '--silent', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + $a.Extra
    $out = (& $wg @argWg 2>&1 | Out-String)
    Add-Resultado "$($a.Nombre) (actualizacion)" ($LASTEXITCODE -eq 0) ("winget codigo {0}" -f $LASTEXITCODE)
    Add-Content -LiteralPath $log -Value $out -Encoding UTF8
    if ($a.Tarea) { Start-ScheduledTask -TaskName $a.Tarea -ErrorAction SilentlyContinue }
    # La cuenta del servicio y el arranque los corrige Invoke-Salud despues
  }

  $docker = Get-Docker
  if (-not $docker) { Log 'Seerr: Docker no esta corriendo, se actualiza la proxima vez' 'WARN'; return }
  $antes = & $docker image inspect -f '{{.Id}}' $seerr.Imagen 2>$null
  & $docker pull $seerr.Imagen 2>&1 | Out-Null
  $despues = & $docker image inspect -f '{{.Id}}' $seerr.Imagen 2>$null
  $usada = & $docker inspect -f '{{.Image}}' $seerr.Contenedor 2>$null
  if ($despues -and $usada -ne $despues) {
    Log "Seerr: imagen nueva, se recrea el contenedor (la configuracion queda en el volumen seerr-config)"
    if (-not $SoloRevisar) {
      & $docker stop $seerr.Contenedor 2>&1 | Out-Null
      & $docker rm $seerr.Contenedor 2>&1 | Out-Null
      $argRun = $seerr.Run
      & $docker @argRun 2>&1 | Out-Null
      Add-Resultado 'Seerr (actualizacion)' ($LASTEXITCODE -eq 0) 'contenedor recreado'
    }
  }
  else { Log 'Seerr: al dia' }
}

Log "=== Mantenimiento del servidor de medios: modo $Modo$(if ($SoloRevisar) { ' (solo revisar)' }) ==="
if ($Modo -eq 'Completo') { Invoke-Actualizaciones }
Invoke-Salud
if ($Modo -eq 'Completo' -and -not $SoloRevisar) {
  try { & (Join-Path $PSScriptRoot 'Reporte-Espacio.ps1') *>&1 | ForEach-Object { Log "$_" }; Add-Resultado 'Reporte de espacio' $true (Join-Path $cfg.Raiz 'Reporte-espacio.html') }
  catch { Add-Resultado 'Reporte de espacio' $false $_.Exception.Message }
}

$fallas = @($resumen | Where-Object { -not $_.Ok })
Log ("=== Fin: {0} chequeos, {1} con falla ===" -f $resumen.Count, $fallas.Count)
if (-not $SoloRevisar) {
  [pscustomobject]@{ Fecha = (Get-Date).ToString('s'); Modo = $Modo; Log = $log; Resultados = $resumen } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $base 'ultimo-estado.json') -Encoding UTF8
}
# Se guardan los ultimos 30 logs
Get-ChildItem -LiteralPath $dirLogs -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
