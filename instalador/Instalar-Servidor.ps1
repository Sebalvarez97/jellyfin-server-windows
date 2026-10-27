<#
  Instalar-Servidor.ps1 - Instala y configura el servidor de medios completo en Windows.
  Se ejecuta con Instalar.bat (pide permisos de administrador). Se puede volver a ejecutar:
  cada paso revisa lo que ya esta hecho y solo cambia lo que falta.

    -SoloRevisar   No cambia nada: informa que haria (sirve sobre una instalacion existente).
    -Fases a,b,c   Ejecuta solo esas fases (ver $Fases abajo).
    -Raiz <ruta>   Carpeta del servidor; si ya tiene config.local.json, no hace las preguntas.

  Lo que el usuario siempre hace a mano (el instalador lo pide y espera):
  - Contrasenas: usuario de qBittorrent, Web UI de qBittorrent, login de Radarr/Sonarr/Prowlarr.
  - Aceptar el aviso legal de qBittorrent y el acuerdo de Docker Desktop.
  - Asistentes de Jellyfin y Seerr, y la clave de API de Jellyfin.
  - Indexadores (Prowlarr) y cuenta de subtitulos (Bazarr): son decision del usuario.
#>
param(
  [switch]$SoloRevisar,
  [string[]]$Fases,
  [string]$Raiz
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\Comun.ps1')
. (Join-Path $PSScriptRoot 'lib\Arr.ps1')
. (Join-Path $PSScriptRoot 'lib\Apps.ps1')
$script:SoloRevisar = [bool]$SoloRevisar

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Hay que ejecutarlo como administrador (usa Instalar.bat).' }
Initialize-Log ('C:\ProgramData\MediaStack\logs\instalacion-{0:yyyyMMdd-HHmm}.log' -f (Get-Date))

$todas = 'Preguntas', 'Apps', 'Carpetas', 'Desplegar', 'Arr', 'qBittorrent', 'Bazarr', 'Jellyfin', 'Seerr', 'Red', 'Proteger', 'Tareas', 'Zrok', 'Extras', 'Salud'
if (-not $Fases) { $Fases = $todas }
function Fase([string]$n) { $n -in $Fases }

Write-Host ''
Write-Host '  Servidor de medios para Windows - instalador' -ForegroundColor Cyan
Write-Host "  Modo: $(if ($SoloRevisar) { 'SOLO REVISAR (no cambia nada)' } else { 'instalar / completar' })" -ForegroundColor Cyan
Write-Host "  Fases: $($Fases -join ', ')"

# --- Preguntas: arma config.local.json ---
. (Join-Path $repo 'servidor\Config-Media.ps1')
if (-not $Raiz) { $Raiz = Preguntar 'Carpeta del servidor (biblioteca, descargas y scripts; mismo disco para todo)' 'D:\JellyFin' }
$Raiz = $Raiz.Trim().TrimEnd('\')
$archivoCfg = Join-Path $Raiz 'config.local.json'
if ((Fase 'Preguntas') -and -not (Test-Path -LiteralPath $archivoCfg)) {
  Paso 'Preguntas'
  $vol = Get-Volume -DriveLetter $Raiz.Substring(0, 1) -ErrorAction SilentlyContinue
  if (-not $vol) { throw "No existe la unidad $($Raiz.Substring(0, 2))" }
  if ($vol.FileSystem -ne 'NTFS') { throw "La unidad $($Raiz.Substring(0, 2)) es $($vol.FileSystem): hace falta NTFS para los hardlinks" }
  Info ("Unidad {0}: {1:N0} GB libres de {2:N0} GB" -f $Raiz.Substring(0, 1), ($vol.SizeRemaining / 1GB), ($vol.Size / 1GB))
  $ipAct = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 1)
  $redSug = $(if ($ipAct) { ($ipAct.IPAddress -replace '\.\d+$', '.0') + "/$($ipAct.PrefixLength)" } else { '' })
  $nuevo = [ordered]@{
    Raiz = $Raiz
    Peliculas = Preguntar 'Subcarpeta de peliculas' 'Movies'
    Series = Preguntar 'Subcarpeta de series' 'Shows'
    Descargas = Preguntar 'Subcarpeta de descargas' 'Descargas'
    IpServidor = Preguntar 'IP de esta PC en la red de la casa (conviene que sea fija)' $(if ($ipAct) { $ipAct.IPAddress } else { '' })
    RedLocal = Preguntar 'Red de la casa' $redSug
    ZonaHoraria = Preguntar 'Zona horaria (formato IANA)' 'America/Argentina/Buenos_Aires'
    UsuarioDescargas = Preguntar 'Usuario de Windows restringido para qBittorrent' 'media'
    Zrok = [ordered]@{ Habilitado = $false; Exe = ''; Entorno = ''; NombreJellyfin = ''; NombreSeerr = '' }
  }
  if (Preguntar-SiNo 'Acceso desde fuera de casa con zrok? (necesitas cuenta en zrok.io y haber corrido "zrok2 enable")' $false) {
    $nuevo.Zrok.Habilitado = $true
    $nuevo.Zrok.Exe = Preguntar 'Ruta de zrok2.exe' "$env:USERPROFILE\zrok\zrok2.exe"
    $nuevo.Zrok.Entorno = Preguntar 'Carpeta del entorno de zrok' "$env:USERPROFILE\.zrok2"
    $nuevo.Zrok.NombreJellyfin = Preguntar 'Nombre reservado para Jellyfin (vacio = no publicar)' ''
    $nuevo.Zrok.NombreSeerr = Preguntar 'Nombre reservado para Seerr (vacio = no publicar)' ''
  }
  Invoke-Cambio "guardar $archivoCfg" {
    New-Item -ItemType Directory -Force -Path $Raiz | Out-Null
    $nuevo | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $archivoCfg -Encoding UTF8
  }
}
$cfg = Get-ConfigMedia $archivoCfg
$cfg.Raiz = $Raiz; $cfg.RutaPeliculas = Join-Path $Raiz $cfg.Peliculas; $cfg.RutaSeries = Join-Path $Raiz $cfg.Series; $cfg.RutaDescargas = Join-Path $Raiz $cfg.Descargas
$P = $cfg.Puertos
Register-Arr radarr $P.Radarr 'v3' 'Radarr'; Register-Arr sonarr $P.Sonarr 'v3' 'Sonarr'; Register-Arr prowlarr $P.Prowlarr 'v1' 'Prowlarr'

function Invoke-Fase([string]$nombre, [scriptblock]$cuerpo) {
  if (-not (Fase $nombre)) { return }
  Paso $nombre
  try { & $cuerpo } catch { Falla "${nombre}: $($_.Exception.Message)"; Add-Pendiente "Fase $nombre con error: revisar el log ($script:LogInstalacion)" }
}

Invoke-Fase 'Apps' { Install-Apps }
Invoke-Fase 'Carpetas' { Set-Carpetas $cfg }
Invoke-Fase 'Desplegar' {
  $arg = @{ Raiz = $Raiz }; if ($SoloRevisar) { $arg.SoloMostrar = $true }
  & (Join-Path $repo 'Desplegar.ps1') @arg
}
Invoke-Fase 'Arr' {
  foreach ($a in 'radarr', 'sonarr', 'prowlarr') {
    if (-not (Wait-Url "http://127.0.0.1:$($script:Apps[$a].Puerto)/ping" 180)) { throw "$a no responde" }
  }
  $faltaLogin = @('radarr', 'sonarr', 'prowlarr' | Where-Object { (Arr $_ GET 'config/host').authenticationMethod -ne 'forms' })
  $usr = $null; $cl = $null
  if ($faltaLogin -and -not $SoloRevisar) {
    Info "Login para $($faltaLogin -join ', ') (desde esta PC no lo piden; protege si algun dia se abren a la red)."
    $usr = Preguntar 'Usuario' 'admin'; $cl = Preguntar-Clave 'Contrasena' 6
  }
  foreach ($a in 'radarr', 'sonarr', 'prowlarr') { Set-HostArr $a $usr $cl }
  Set-CarpetaRaizArr radarr $cfg.RutaPeliculas; Set-CarpetaRaizArr sonarr $cfg.RutaSeries
  foreach ($a in 'radarr', 'sonarr') { Set-NombresArr $a; Set-MediaArr $a; Set-ClienteDescargaArr $a $P.qBittorrent; Set-CustomFormatsArr $a; Set-PerfilesArr $a }
  Set-AppsProwlarr @{ Prowlarr = $P.Prowlarr; Radarr = $P.Radarr; Sonarr = $P.Sonarr }
  Set-SeedersRadarr 5
}
Invoke-Fase 'qBittorrent' { Set-Qbittorrent $cfg }
Invoke-Fase 'Bazarr' { Set-Bazarr $cfg }
Invoke-Fase 'Jellyfin' {
  Set-Jellyfin $cfg
  # Se anota con que cuenta quedo el servicio (el mantenimiento la respeta)
  $cuenta = (Get-CimInstance Win32_Service -Filter "Name='JellyfinServer'").StartName
  if ($cuenta -and -not $SoloRevisar) {
    $j = Get-Content -LiteralPath $archivoCfg -Raw | ConvertFrom-Json
    $j | Add-Member -NotePropertyName CuentaJellyfin -NotePropertyValue $cuenta -Force
    $j | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $archivoCfg -Encoding UTF8
  }
}
Invoke-Fase 'Seerr' { if (Preguntar-SiNo 'Instalar Seerr (pagina de pedidos, usa Docker Desktop)?' $true) { Set-Seerr $cfg } }
Invoke-Fase 'Red' { Set-Red $cfg }
Invoke-Fase 'Proteger' {
  # La raiz (scripts que corre SYSTEM) queda de solo lectura para LocalService y el usuario de descargas
  $script = Join-Path $Raiz 'panel\Proteger-Scripts.ps1'
  if (-not (Test-Path -LiteralPath $script)) { Aviso 'No esta panel\Proteger-Scripts.ps1: la raiz queda sin proteger'; Add-Pendiente 'Proteger la raiz del servidor (Proteger-Scripts.bat)'; return }
  $sids = @('S-1-5-19') + @((Get-LocalUser -Name $cfg.UsuarioDescargas -ErrorAction SilentlyContinue).SID.Value)
  $escriben = @((Get-Acl -LiteralPath $Raiz).Access | Where-Object {
      $_.AccessControlType -eq 'Allow' -and $_.PropagationFlags -ne 'InheritOnly' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete') -and
      $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $sids })
  if (-not $escriben) { Ok 'La raiz ya esta protegida (los servicios solo escriben en las carpetas de datos)'; return }
  Invoke-Cambio 'proteger la raiz (Proteger-Scripts.ps1, guarda un respaldo de permisos)' { & $script -Raiz $Raiz }
}
Invoke-Fase 'Tareas' {
  if ($SoloRevisar) { Info '(revision) se crearian las tareas "Media - Arranque" y "Media - Mantenimiento"'; return }
  & (Join-Path $Raiz 'Instalar-Mantenimiento.ps1')
}
Invoke-Fase 'Zrok' {
  if (-not $cfg.Zrok.Habilitado) { Info 'zrok deshabilitado en la configuracion'; return }
  foreach ($s in @(@{ S = 'Jellyfin'; N = $cfg.Zrok.NombreJellyfin }, @{ S = 'Seerr'; N = $cfg.Zrok.NombreSeerr })) {
    if (-not $s.N) { continue }
    if (Get-ScheduledTask -TaskName "zrok $($s.S)" -ErrorAction SilentlyContinue) { Ok "Tunel zrok $($s.S)"; continue }
    Invoke-Cambio "tunel zrok para $($s.S) ($($s.N))" { & (Join-Path $Raiz 'Tunel-zrok.ps1') -Servicio $s.S }
  }
}
Invoke-Fase 'Extras' {
  $extras = @(Get-ChildItem -LiteralPath (Join-Path $repo 'extras') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)
  if (-not $extras) { Info 'No hay pasos adicionales en extras\'; return }
  foreach ($e in $extras) {
    Invoke-Cambio "paso adicional $($e.Name)" {
      try { Push-Location $Raiz; & $e.FullName -Config $archivoCfg; Ok $e.Name } catch { Falla "$($e.Name): $($_.Exception.Message)" } finally { Pop-Location }
    }
  }
}
Invoke-Fase 'Salud' {
  $arg = @{ Modo = 'Salud' }; if ($SoloRevisar) { $arg.SoloRevisar = $true }
  & (Join-Path $Raiz 'Mantenimiento-Media.ps1') @arg
}

# --- Resumen ---
Add-Pendiente "Prowlarr: agregar indexadores en http://127.0.0.1:$($P.Prowlarr) > Indexers (son decision tuya; Prowlarr los pasa solo a Radarr y Sonarr)"
Add-Pendiente 'Jellyfin: crear un usuario por persona; con ese mismo usuario entran a Seerr'
Write-Host ''
Write-Host '== Lo que queda de tu lado' -ForegroundColor Cyan
$i = 0; foreach ($p in $script:Pendientes) { $i++; Write-Host "  $i. $p" }
Write-Host ''
Write-Host "Log de la instalacion: $script:LogInstalacion"
Write-Host "Panel de control: $(Join-Path $Raiz 'Panel-Media.bat')"
