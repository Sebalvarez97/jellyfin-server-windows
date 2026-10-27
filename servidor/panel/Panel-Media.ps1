<#
  Panel-Media.ps1 - Panel del servidor de medios en una sola pantalla.
  Lo abre <Raiz>\Panel-Media.bat (doble clic). Corre con tu usuario, sin administrador.
  Los datos de la instalacion (rutas, IP, red, puertos, zrok) salen de <Raiz>\config.local.json
  via <Raiz>\Config-Media.ps1; si no existen, se usan los valores por defecto.

  - Escucha SOLO en 127.0.0.1, en un puerto al azar: nada queda expuesto a la red.
  - Cada apertura genera un token secreto; sin el, el panel no responde.
  - Las API keys se leen del disco y nunca se mandan al navegador.
  - Lo que necesita administrador (iniciar o reiniciar servicios y tareas) lo hace
    Panel-Accion.ps1, y Windows pide permiso (UAC) cada vez.
  - Borrar candidatos usa Borrar-Candidatos.ps1 (borra tambien el torrent, por los hardlinks).
  - Si se cierra la ventana, el servidor se apaga solo a los $Inactividad segundos.

  Esta carpeta (panel) tiene que tener permisos propios: solo tu usuario, Administradores y SYSTEM,
  asi qBittorrent (usuario de descargas) y los servicios no pueden modificar el panel.
  Log y archivos de la sesion: panel\estado\
#>
param(
  [int]$Inactividad = 180,
  [switch]$SinNavegador
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Panel = $PSScriptRoot
$Web = Join-Path $Panel 'web'
$DirEstado = Join-Path $Panel 'estado'
New-Item -ItemType Directory -Force -Path $DirEstado | Out-Null
$LogPanel = Join-Path $DirEstado 'panel.log'
$ArchInstancia = Join-Path $DirEstado 'instancia.json'
$Docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$DockerDesktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Log([string]$t) {
  try { Add-Content -LiteralPath $LogPanel -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $t) -Encoding UTF8 } catch {}
}

# --- Configuracion de esta instalacion: el panel vive en <Raiz>\panel ---
$ArchConfig = Join-Path (Split-Path -Parent $Panel) 'Config-Media.ps1'
if (Test-Path -LiteralPath $ArchConfig) { . $ArchConfig; $cfg = Get-ConfigMedia (Join-Path (Split-Path -Parent $Panel) 'config.local.json') }
else {
  # Sin Config-Media.ps1: los mismos valores por defecto que trae ese archivo
  $r = Split-Path -Parent $Panel
  $cfg = [pscustomobject]@{
    Raiz = $r; RutaPeliculas = (Join-Path $r 'Movies'); RutaSeries = (Join-Path $r 'Shows'); RutaDescargas = (Join-Path $r 'Descargas')
    IpServidor = ''; RedLocal = ''; UsuarioDescargas = 'media'
    Puertos = [pscustomobject]@{ Jellyfin = 8096; Seerr = 5055; Radarr = 7878; Sonarr = 8989; Prowlarr = 9696; Bazarr = 6767; qBittorrent = 8080 }
    Seerr = [pscustomobject]@{ Contenedor = 'seerr' }
    Zrok = [pscustomobject]@{ Habilitado = $false; NombreJellyfin = ''; NombreSeerr = '' }
    Reporte = [pscustomobject]@{ DiasVisto = 60; UmbralPct = 80 }
  }
  function Test-EnRed([string]$Ip, [string]$Red) { $false }
}
$Raiz = $cfg.Raiz
$P = $cfg.Puertos
$ArchCsv = Join-Path $Raiz 'candidatos-borrar.csv'
$UmbralDisco = [int]$cfg.Reporte.UmbralPct
$IpFija = [string]$cfg.IpServidor
$TareaQbit = "qBittorrent ($($cfg.UsuarioDescargas))"
function Get-Local([int]$puerto, [string]$ruta = '') { "http://127.0.0.1:$puerto$ruta" }

# --- Que hay en el stack (mismas cuentas que Mantenimiento-Media.ps1) ---
$Servicios = @(
  @{ Id = 'jellyfin'; Nombre = 'Jellyfin'; Servicio = 'JellyfinServer'; Cuenta = 'NT AUTHORITY\NetworkService'; Url = (Get-Local $P.Jellyfin '/health'); Web = (Get-Local $P.Jellyfin) },
  @{ Id = 'radarr';   Nombre = 'Radarr';   Servicio = 'Radarr';         Cuenta = 'NT AUTHORITY\LocalService';   Url = (Get-Local $P.Radarr '/ping');     Web = (Get-Local $P.Radarr) },
  @{ Id = 'sonarr';   Nombre = 'Sonarr';   Servicio = 'Sonarr';         Cuenta = 'NT AUTHORITY\LocalService';   Url = (Get-Local $P.Sonarr '/ping');     Web = (Get-Local $P.Sonarr) },
  @{ Id = 'prowlarr'; Nombre = 'Prowlarr'; Servicio = 'Prowlarr';       Cuenta = 'NT AUTHORITY\LocalService';   Url = (Get-Local $P.Prowlarr '/ping');   Web = (Get-Local $P.Prowlarr) },
  @{ Id = 'bazarr';   Nombre = 'Bazarr';   Servicio = 'Bazarr';         Cuenta = 'NT AUTHORITY\LocalService';   Url = (Get-Local $P.Bazarr '/');         Web = (Get-Local $P.Bazarr) }
)
# Contenedores de Docker que el panel puede iniciar o reiniciar (FlareSolverr es opcional y lo arma
# cada uno: el panel solo lo mira y lo reinicia, no cambia su configuracion)
$Contenedores = @(
  @{ Id = 'seerr';        Docker = [string]$cfg.Seerr.Contenedor; Nombre = 'Seerr';        Url = (Get-Local $P.Seerr '/api/v1/status'); Web = (Get-Local $P.Seerr); Opcional = $false },
  @{ Id = 'flaresolverr'; Docker = 'flaresolverr';                Nombre = 'FlareSolverr'; Url = (Get-Local 8191 '/');                  Web = $null;                Opcional = $true }
)
# Puertos que tienen que escuchar solo en la PC (Jellyfin y Seerr se abren a la red a proposito)
$PuertosLocales = @(
  @{ P = $P.Radarr; App = 'Radarr' }, @{ P = $P.Sonarr; App = 'Sonarr' }, @{ P = $P.Prowlarr; App = 'Prowlarr' },
  @{ P = $P.qBittorrent; App = 'qBittorrent' }, @{ P = $P.Bazarr; App = 'Bazarr' }
)

# --- Credenciales: se leen del disco y quedan solo en este proceso ---
function Get-ArrKey([string]$app) {
  try { ([xml](Get-Content -LiteralPath "C:\ProgramData\$app\config.xml" -Raw)).Config.ApiKey } catch { '' }
}
function Get-BazarrKey {
  $enAuth = $false
  foreach ($l in @(Get-Content -LiteralPath 'C:\ProgramData\Bazarr\config\config.yaml' -ErrorAction SilentlyContinue)) {
    if ($l -match '^(\S[^:]*):') { $enAuth = ($matches[1] -eq 'auth') }
    elseif ($enAuth -and $l -match '^\s+apikey:\s*(.+)$') { return $matches[1].Trim().Trim("'", '"') }
  }
  ''
}
function Get-JellyfinKey {
  $f = Join-Path $Raiz 'secretos\jellyfin-api.txt'
  if (Test-Path -LiteralPath $f) { (Get-Content -LiteralPath $f -Raw).Trim() } else { '' }
}

$Apps = @{
  radarr   = @{ Url = (Get-Local $P.Radarr '/api/v3');      H = @{ 'X-Api-Key' = (Get-ArrKey 'Radarr') } }
  sonarr   = @{ Url = (Get-Local $P.Sonarr '/api/v3');      H = @{ 'X-Api-Key' = (Get-ArrKey 'Sonarr') } }
  prowlarr = @{ Url = (Get-Local $P.Prowlarr '/api/v1');    H = @{ 'X-Api-Key' = (Get-ArrKey 'Prowlarr') } }
  bazarr   = @{ Url = (Get-Local $P.Bazarr '/api');         H = @{ 'X-API-KEY' = (Get-BazarrKey) } }
  # Jellyfin 12 ya no acepta X-Emby-Token: va en el encabezado Authorization
  jellyfin = @{ Url = (Get-Local $P.Jellyfin);              H = @{ Authorization = ('MediaBrowser Token="{0}"' -f (Get-JellyfinKey)) } }
  qbit     = @{ Url = (Get-Local $P.qBittorrent '/api/v2'); H = @{} }
  seerr    = @{ Url = (Get-Local $P.Seerr '/api/v1');       H = @{} }
}

# Invoke-RestMethod de PowerShell 5.1 devuelve los arrays JSON como un solo objeto: se desarman aca
function Api([string]$app, [string]$ruta, [string]$metodo = 'GET', $cuerpo = $null, [int]$timeout = 10) {
  $a = $Apps[$app]
  $p = @{ Uri = "$($a.Url)/$ruta"; Method = $metodo; Headers = $a.H; TimeoutSec = $timeout; UseBasicParsing = $true }
  if ($null -ne $cuerpo) { $p.ContentType = 'application/json'; $p.Body = [Text.Encoding]::UTF8.GetBytes(($cuerpo | ConvertTo-Json -Depth 20)) }
  Invoke-RestMethod @p | ForEach-Object { $_ }
}

# Mensaje de error de una API (Servarr devuelve una lista de validaciones)
function Get-MensajeError($err) {
  $txt = "$($err.ErrorDetails.Message)"
  if ($txt) {
    try {
      $j = $txt | ConvertFrom-Json
      $m = @($j | ForEach-Object { $_ } | ForEach-Object { if ($_.errorMessage) { $_.errorMessage } elseif ($_.message) { $_.message } }) | Where-Object { $_ }
      if ($m) { return ($m -join ' | ') }
    } catch {}
    return $txt.Substring(0, [Math]::Min(400, $txt.Length))
  }
  $err.Exception.Message
}

function Test-Url([string]$url, [int]$seg = 3) {
  try { $null = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $seg; $true }
  catch {
    # Una respuesta 401/403 tambien significa que la app esta viva
    [bool]($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in 401, 403)
  }
}

function Invoke-Docker {
  $ErrorActionPreference = 'Continue'
  if (-not (Test-Path -LiteralPath $Docker)) { return [pscustomobject]@{ Ok = $false; Salida = 'docker.exe no esta instalado' } }
  $salida = & $Docker @args 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Salida = (($salida -join "`n").Trim()) }
}

function Get-Duenio($proc) {
  try { $o = Invoke-CimMethod -InputObject $proc -MethodName GetOwner; if ($o.ReturnValue -eq 0) { "$($o.Domain)\$($o.User)" } } catch {}
}

# Copias de qBittorrent abiertas con tu usuario (desde el menu Inicio) en vez de la tarea del usuario media
function Get-QbitPropias {
  @(Get-CimInstance Win32_Process -Filter "Name='qbittorrent.exe'" | Where-Object { (Get-Duenio $_) -like "*\$env:USERNAME" } | ForEach-Object { [int]$_.ProcessId })
}

# Tuneles de zrok (los arma Tunel-zrok.ps1: tarea "zrok <App>", log en C:\ProgramData\zrok\home)
function Get-Tuneles {
  if (-not $cfg.Zrok.Habilitado) { return }
  foreach ($t in @(@{ App = 'Jellyfin'; Nombre = [string]$cfg.Zrok.NombreJellyfin; Prueba = '/health' },
                   @{ App = 'Seerr';    Nombre = [string]$cfg.Zrok.NombreSeerr;    Prueba = '/api/v1/status' })) {
    if (-not $t.Nombre) { continue }
    $log = Join-Path 'C:\ProgramData\zrok\home' "zrok-$($t.Nombre).log"
    # La primera version del tunel de Jellyfin escribia en zrok.log
    if (-not (Test-Path -LiteralPath $log) -and $t.App -eq 'Jellyfin') { $log = 'C:\ProgramData\zrok\home\zrok.log' }
    [pscustomobject]@{ App = $t.App; Nombre = $t.Nombre; Url = "https://$($t.Nombre).shares.zrok.io"; Prueba = $t.Prueba; Log = $log; Tarea = "zrok $($t.App)" }
  }
}
$Tuneles = @(Get-Tuneles)

function Test-Tuneles {
  $r = @{}
  foreach ($t in $Tuneles) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = $false; $codigo = 0
    try { $resp = Invoke-WebRequest -Uri ($t.Url + $t.Prueba) -UseBasicParsing -TimeoutSec 15; $ok = $true; $codigo = [int]$resp.StatusCode }
    catch { if ($_.Exception.Response) { $codigo = [int]$_.Exception.Response.StatusCode } }
    $r[$t.Nombre] = @{ ok = $ok; codigo = $codigo; ms = $sw.ElapsedMilliseconds; fecha = (Get-Date).ToString('s') }
  }
  $r
}

# --- Cache simple: lo caro (salud, diagnostico, tamano de carpetas) no se recalcula en cada pedido ---
$Cache = @{}
function Get-Cacheado([string]$clave, [int]$segundos, [scriptblock]$calcular, [bool]$forzar = $false) {
  $c = $Cache[$clave]
  if (-not $forzar -and $c -and ((Get-Date) - $c.Fecha).TotalSeconds -lt $segundos) { return $c.Valor }
  $v = & $calcular
  $Cache[$clave] = @{ Fecha = Get-Date; Valor = $v }
  $v
}

# ===================== Estado (cada 10 s) =====================
# Get-Volume y Get-NetAdapter tardan 1-2 s cada uno: aca se usa .NET directo
function Get-Disco {
  $d = New-Object IO.DriveInfo($Raiz.Substring(0, 1))
  [pscustomobject]@{ Size = [double]$d.TotalSize; Libre = [double]$d.AvailableFreeSpace }
}
function Get-Placa {
  $nics = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
      $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -in 'Wireless80211', 'Ethernet', 'GigabitEthernet' -and $_.Description -notmatch 'Hyper-V|Virtual|VPN|TAP|WSL' })
  # La de la IP fija primero
  $fija = $nics | Where-Object { $_.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.ToString() -eq $IpFija } } | Select-Object -First 1
  if ($fija) { $fija } else { $nics | Select-Object -First 1 }
}
$RedPrevia = @{}
function Get-Estado {
  $wmi = @{}
  Get-CimInstance Win32_Service -Filter (($Servicios | ForEach-Object { "Name='$($_.Servicio)'" }) -join ' OR ') | ForEach-Object { $wmi[$_.Name] = $_ }
  $filas = New-Object System.Collections.Generic.List[object]
  foreach ($s in $Servicios) {
    $w = $wmi[$s.Servicio]
    $filas.Add([ordered]@{
      id = $s.Id; nombre = $s.Nombre; tipo = 'servicio'
      estado = $(if ($w) { [string]$w.State } else { 'NoExiste' })
      cuenta = $(if ($w) { [string]$w.StartName } else { '' })
      cuentaEsperada = $s.Cuenta
      cuentaOk = [bool]($w -and $w.StartName -eq $s.Cuenta)
      arranque = $(if ($w) { [string]$w.StartMode } else { '' })
      responde = $(if ($w -and $w.State -eq 'Running') { Test-Url $s.Url } else { $false })
      web = $s.Web
    })
  }

  # qBittorrent corre como el usuario media: sin admin no se puede leer el dueno de su proceso,
  # pero si se puede detectar una copia abierta con tu usuario (eso si es un problema)
  $qp = @(Get-CimInstance Win32_Process -Filter "Name='qbittorrent.exe'")
  $propias = Get-QbitPropias
  $filas.Add([ordered]@{
    id = 'qbittorrent'; nombre = 'qBittorrent'; tipo = 'tarea'
    estado = $(if ($qp.Count) { 'Running' } else { 'Stopped' })
    cuenta = $(if ($propias.Count) { "$env:USERDOMAIN\$env:USERNAME" } elseif ($qp.Count) { [string]$cfg.UsuarioDescargas } else { '' })
    cuentaEsperada = [string]$cfg.UsuarioDescargas; cuentaOk = (-not $propias.Count); propias = @($propias)
    responde = Test-Url (Get-Local $P.qBittorrent '/api/v2/app/version')
    web = (Get-Local $P.qBittorrent)
  })

  # Tuneles: el proceso se ve, la prueba publica se hace en Salud (cada 2 min) y aca se reusa
  $zp = @(Get-Process zrok2 -ErrorAction SilentlyContinue).Count
  $pub = $(if ($Cache['zrok']) { $Cache['zrok'].Valor } else { @{} })
  foreach ($t in $Tuneles) {
    $p = $pub[$t.Nombre]
    $filas.Add([ordered]@{
      id = 'zrok-' + $t.App.ToLower(); nombre = "Tunel $($t.App)"; tipo = 'tunel'
      estado = $(if ($zp) { 'Running' } else { 'Stopped' }); procesos = $zp
      cuenta = 'LocalService'; cuentaEsperada = 'LocalService'; cuentaOk = $true
      responde = $(if ($p) { $p.ok } else { $null }); ms = $(if ($p) { $p.ms } else { $null })
      web = $t.Url
    })
  }

  # Contenedores de Docker Desktop (arranca solo cuando alguien inicia sesion)
  $dd = [bool](Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)
  foreach ($c in $Contenedores) {
    $ins = Invoke-Docker inspect -f '{{.State.Status}}' $c.Docker
    $contenedor = $(if ($ins.Ok) { $ins.Salida } elseif ($ins.Salida -match 'No such') { 'no existe' } else { '' })
    if ($contenedor -eq 'no existe' -and $c.Opcional) { continue }
    $filas.Add([ordered]@{
      id = $c.Id; nombre = $c.Nombre; tipo = 'contenedor'
      estado = $(if ($contenedor -eq 'running') { 'Running' } else { 'Stopped' })
      contenedor = $contenedor; docker = $dd; motor = ($ins.Ok -or $contenedor -eq 'no existe')
      cuenta = 'Docker Desktop'; cuentaEsperada = 'Docker Desktop'; cuentaOk = $true
      responde = $(if ($contenedor -eq 'running') { Test-Url $c.Url } else { $false })
      web = $c.Web
    })
  }

  # --- Descargas ---
  $tr = $null; $tor = @()
  try { $tr = Api qbit 'transfer/info' 'GET' $null 5; $tor = @(Api qbit 'torrents/info' 'GET' $null 10) } catch {}
  $cola = @{}
  foreach ($app in 'radarr', 'sonarr') {
    try {
      foreach ($r in @((Api $app 'queue?pageSize=200' 'GET' $null 5).records)) {
        if (-not $r.downloadId) { continue }
        $msgs = @(@($r.statusMessages | ForEach-Object { $_.messages } | ForEach-Object { $_ }) + @($r.errorMessage) | Where-Object { $_ })
        $cola[$r.downloadId.ToLower()] = [ordered]@{ app = $app; estado = $r.trackedDownloadState; aviso = $r.trackedDownloadStatus; mensajes = $msgs }
      }
    } catch {}
  }
  $activas = @($tor | Where-Object { $_.progress -lt 1 } | Sort-Object added_on -Descending | ForEach-Object {
    [ordered]@{
      nombre = $_.name; estado = $_.state; progreso = [math]::Round($_.progress * 100, 1)
      bajada = $_.dlspeed; subida = $_.upspeed; eta = $_.eta
      semillas = $_.num_seeds; semillasTotal = $_.num_complete; tamano = $_.size; categoria = $_.category
      agregado = $_.added_on; cola = $cola[$_.hash]
    } })
  $grupos = @{ bajando = 0; trabadas = 0; enCola = 0; pausadas = 0; compartiendo = 0 }
  foreach ($t in $tor) {
    switch -Regex ($t.state) {
      '^(downloading|forcedDL|metaDL|forcedMetaDL|checkingDL|allocating|moving)$' { $grupos.bajando++ }
      '^stalledDL$' { $grupos.trabadas++ }
      '^queuedDL$' { $grupos.enCola++ }
      '^(pausedDL|stoppedDL|error|missingFiles)$' { $grupos.pausadas++ }
      '^(uploading|forcedUP|stalledUP|queuedUP|checkingUP)$' { $grupos.compartiendo++ }
    }
  }

  # --- Red: velocidad de la placa fisica (diferencia contra la medicion anterior) ---
  $red = $null
  $ad = Get-Placa
  if ($ad) {
    $st = $ad.GetIPStatistics()
    $ahora = Get-Date
    $red = [ordered]@{ placa = $ad.Name; enlace = $ad.Speed; bajada = $null; subida = $null }
    if ($RedPrevia.Nombre -eq $ad.Name) {
      $seg = ($ahora - $RedPrevia.Fecha).TotalSeconds
      if ($seg -gt 0) {
        $red.bajada = [math]::Max(0, [math]::Round(($st.BytesReceived - $RedPrevia.Rx) / $seg))
        $red.subida = [math]::Max(0, [math]::Round(($st.BytesSent - $RedPrevia.Tx) / $seg))
      }
    }
    $RedPrevia.Nombre = $ad.Name; $RedPrevia.Fecha = $ahora; $RedPrevia.Rx = $st.BytesReceived; $RedPrevia.Tx = $st.BytesSent
  }

  # --- Quien esta mirando algo en Jellyfin ---
  $repro = @()
  try {
    $repro = @(Api jellyfin 'Sessions?ActiveWithinSeconds=300' 'GET' $null 5 | Where-Object { $_.NowPlayingItem } | ForEach-Object {
      $ip = "$($_.RemoteEndPoint)"
      [ordered]@{
        usuario = $_.UserName; cliente = $_.Client; dispositivo = $_.DeviceName
        titulo = $(if ($_.NowPlayingItem.SeriesName) { "$($_.NowPlayingItem.SeriesName) - $($_.NowPlayingItem.Name)" } else { $_.NowPlayingItem.Name })
        metodo = $_.PlayState.PlayMethod; pausado = [bool]$_.PlayState.IsPaused
        # En casa = red local, la propia PC o la red interna de Docker (Seerr)
        remoto = -not ((Test-EnRed $ip $cfg.RedLocal) -or $ip -like '127.*' -or $ip -eq '::1' -or (Test-EnRed $ip '172.16.0.0/12'))
        bitrate = $(if ($_.TranscodingInfo) { $_.TranscodingInfo.Bitrate } else { $null })
      } })
  } catch {}

  $v = Get-Disco
  [ordered]@{
    generado = (Get-Date).ToString('s')
    servicios = $filas
    descargas = [ordered]@{
      ok = [bool]$tr
      bajada = $(if ($tr) { $tr.dl_info_speed } else { 0 }); subida = $(if ($tr) { $tr.up_info_speed } else { 0 })
      conexion = $(if ($tr) { $tr.connection_status } else { '' })
      total = $tor.Count; grupos = $grupos; activas = $activas
    }
    red = $red
    reproducciones = $repro
    disco = [ordered]@{ total = $v.Size; libre = $v.Libre; pct = [math]::Round(100 * ($v.Size - $v.Libre) / $v.Size); umbral = $UmbralDisco }
    trabajos = @(Get-TrabajosEnCurso)
  }
}

# ===================== Avisos de salud (cada 60 s) =====================
function Get-Salud {
  $items = New-Object System.Collections.Generic.List[object]
  $caidas = New-Object System.Collections.Generic.List[string]
  $versiones = [ordered]@{}
  # codigo = mensaje propio del panel (el texto lo pone la interfaz); sin codigo = mensaje de la app
  function Add-Item([string]$app, [string]$nivel, [string]$mensaje, [string]$codigo = '', $datos = $null, [string]$fuente = '', [string]$wiki = '') {
    $items.Add([ordered]@{ app = $app; nivel = $nivel; mensaje = $mensaje; codigo = $codigo; datos = $datos; fuente = $fuente; wiki = $wiki })
  }

  foreach ($app in 'radarr', 'sonarr', 'prowlarr') {
    try {
      $versiones[$app] = (Api $app 'system/status' 'GET' $null 5).version
      foreach ($h in @(Api $app 'health' 'GET' $null 10)) {
        $w = $h.wikiUrl; if ($w -and $w -isnot [string]) { $w = $w.fullUri }
        Add-Item $app $h.type $h.message '' $null $h.source $w
      }
    } catch { $caidas.Add($app) }
  }

  try {
    $versiones.bazarr = (Api bazarr 'system/status' 'GET' $null 5).data.bazarr_version
    foreach ($h in @((Api bazarr 'system/health' 'GET' $null 10).data)) { if ($h) { Add-Item 'bazarr' 'warning' ('{0}: {1}' -f $h.object, $h.issue) } }
    foreach ($p in @((Api bazarr 'providers' 'GET' $null 10).data)) {
      if ($p -and $p.status -ne 'Good') { Add-Item 'bazarr' 'warning' '' 'bazarr-proveedor' ([ordered]@{ nombre = $p.name; estado = $p.status; reintento = $p.retry }) }
    }
  } catch { $caidas.Add('bazarr') }

  try {
    $i = Api jellyfin 'System/Info' 'GET' $null 5
    $versiones.jellyfin = $i.Version
    if ($i.HasPendingRestart) { Add-Item 'jellyfin' 'warning' '' 'jf-reinicio' }
    if ($i.HasUpdateAvailable) { Add-Item 'jellyfin' 'notice' '' 'jf-actualizacion' }
    # Intentos de login fallidos en las ultimas 24 h (Jellyfin y Seerr usan el mismo login, y estan en internet por zrok)
    $desde = (Get-Date).AddHours(-24).ToUniversalTime().ToString('o')
    $fallidos = @((Api jellyfin "System/ActivityLog/Entries?limit=500&minDate=$desde" 'GET' $null 10).Items | Where-Object { $_.Type -eq 'AuthenticationFailed' })
    if ($fallidos.Count) {
      $ips = @($fallidos | ForEach-Object { if ($_.ShortOverview -match '(\d{1,3}(\.\d{1,3}){3}|[0-9a-f:]{6,})\s*$') { $matches[1] } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ ip = $_.Name; veces = $_.Count } })
      Add-Item 'jellyfin' $(if ($fallidos.Count -ge 5) { 'warning' } else { 'notice' }) '' 'jf-logins' ([ordered]@{ cantidad = $fallidos.Count; ultimo = $fallidos[0].Date; ips = $ips })
    }
  } catch { $caidas.Add('jellyfin') }

  try {
    $s = Api seerr 'status' 'GET' $null 5
    $versiones.seerr = $s.version
    if ($s.restartRequired) { Add-Item 'seerr' 'warning' '' 'seerr-reinicio' }
    if ($s.updateAvailable) { Add-Item 'seerr' 'notice' '' 'seerr-actualizacion' }
  } catch { $caidas.Add('seerr') }

  try { $versiones.qbittorrent = "$(Api qbit 'app/version' 'GET' $null 5)" } catch { $caidas.Add('qbittorrent') }

  # Ultimo chequeo de las tareas SYSTEM de Mantenimiento-Media.ps1
  $ue = 'C:\ProgramData\MediaStack\ultimo-estado.json'
  if (Test-Path -LiteralPath $ue) {
    try {
      $j = Get-Content -LiteralPath $ue -Raw -Encoding UTF8 | ConvertFrom-Json
      $edad = ((Get-Date) - [datetime]$j.Fecha).TotalDays
      if ($edad -gt 8) { Add-Item 'mantenimiento' 'warning' '' 'mant-viejo' ([ordered]@{ fecha = $j.Fecha }) }
      foreach ($r in @($j.Resultados | ForEach-Object { $_ } | Where-Object { -not $_.Ok })) {
        Add-Item 'mantenimiento' 'warning' '' 'mant-falla' ([ordered]@{ que = $r.Que; detalle = $r.Detalle; fecha = $j.Fecha })
      }
    } catch {}
  } else { Add-Item 'mantenimiento' 'notice' '' 'mant-nunca' }

  # Descargas con problemas en la cola de Radarr y Sonarr
  $cola = New-Object System.Collections.Generic.List[object]
  foreach ($app in 'radarr', 'sonarr') {
    try {
      foreach ($r in @((Api $app 'queue?pageSize=200' 'GET' $null 10).records)) {
        if ($r.trackedDownloadStatus -in 'warning', 'error' -or $r.status -eq 'warning' -or $r.errorMessage) {
          $cola.Add([ordered]@{
            app = $app; titulo = $r.title; estado = $r.trackedDownloadState; nivel = $(if ($r.trackedDownloadStatus -eq 'error') { 'error' } else { 'warning' })
            mensajes = @(@($r.statusMessages | ForEach-Object { $_.messages } | ForEach-Object { $_ }) + @($r.errorMessage) | Where-Object { $_ } | Select-Object -Unique)
          })
        }
      }
    } catch {}
  }

  # Indexadores en pausa por fallas (se pueden reintentar desde el panel).
  # Prowlarr tiene indexerstatus; Radarr y Sonarr no, asi que se sacan del aviso de salud
  $idx = New-Object System.Collections.Generic.List[object]
  try {
    $nombres = @{}
    Api prowlarr 'indexer' 'GET' $null 10 | ForEach-Object { $nombres[[int]$_.id] = $_.name }
    foreach ($st in @(Api prowlarr 'indexerstatus' 'GET' $null 10)) {
      if (-not $st -or -not $nombres.ContainsKey([int]$st.indexerId)) { continue }
      $hasta = $(if ($st.disabledTill) { [datetime]$st.disabledTill } else { $null })
      $idx.Add([ordered]@{
        app = 'prowlarr'; id = [int]$st.indexerId; nombre = $nombres[[int]$st.indexerId]
        hasta = $st.disabledTill; enPausa = [bool]($hasta -and $hasta -gt (Get-Date))
        desde = $st.initialFailure; ultimaFalla = $st.mostRecentFailure
      })
    }
  } catch {}
  foreach ($app in 'radarr', 'sonarr') {
    $avisos = @($items | Where-Object { $_.app -eq $app -and $_.fuente -match '^Indexer(LongTerm)?StatusCheck$' })
    if (-not $avisos) { continue }
    try {
      $porNombre = @{}
      Api $app 'indexer' 'GET' $null 10 | ForEach-Object { $porNombre[$_.name] = [int]$_.id }
      foreach ($av in $avisos) {
        foreach ($n in ($av.mensaje -replace '^[^:]*:\s*', '') -split ',\s*') {
          if ($porNombre.ContainsKey($n) -and -not ($idx | Where-Object { $_.app -eq $app -and $_.nombre -eq $n })) {
            $idx.Add([ordered]@{ app = $app; id = $porNombre[$n]; nombre = $n; hasta = $null; enPausa = $true; largo = ($av.fuente -like '*LongTerm*') })
          }
        }
      }
    } catch {}
  }

  $null = Get-Cacheado 'zrok' 120 { Test-Tuneles }
  [ordered]@{ generado = (Get-Date).ToString('s'); items = $items; cola = $cola; indexadores = $idx; versiones = $versiones; caidas = $caidas }
}

# ===================== Diagnostico: problemas que ya pasaron y pueden volver =====================
function Get-Diagnostico {
  $l = New-Object System.Collections.Generic.List[object]
  function Chequeo([string]$id, [scriptblock]$sb) {
    try { $r = @(& $sb); $l.Add([ordered]@{ id = $id; estado = $r[0]; datos = $r[1] }) }
    catch { $l.Add([ordered]@{ id = $id; estado = 'error'; datos = @{ error = $_.Exception.Message } }) }
  }

  Chequeo 'cuentas' {
    $mal = @(); $faltan = @()
    foreach ($s in $Servicios) {
      $w = Get-CimInstance Win32_Service -Filter "Name='$($s.Servicio)'"
      if (-not $w) { $faltan += $s.Nombre }
      elseif ($w.StartName -ne $s.Cuenta) { $mal += [ordered]@{ id = $s.Id; nombre = $s.Nombre; actual = $w.StartName; esperada = $s.Cuenta } }
    }
    $(if ($faltan -or $mal) { 'falla' } else { 'ok' }), @{ mal = $mal; faltan = $faltan }
  }

  Chequeo 'puertos' {
    $esc = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    $expuestos = @(); $sinEscuchar = @()
    foreach ($p in $PuertosLocales) {
      $e = @($esc | Where-Object LocalPort -eq $p.P)
      if (-not $e) { $sinEscuchar += $p.App; continue }
      foreach ($x in $e) { if ($x.LocalAddress -notin '127.0.0.1', '::1') { $expuestos += [ordered]@{ app = $p.App; puerto = $p.P; direccion = $x.LocalAddress } } }
    }
    $(if ($expuestos) { 'falla' } elseif ($sinEscuchar) { 'aviso' } else { 'ok' }), @{ expuestos = $expuestos; sinEscuchar = $sinEscuchar }
  }

  Chequeo 'qbit-copia' {
    $propias = Get-QbitPropias
    $(if ($propias.Count) { 'falla' } else { 'ok' }), @{ propias = @($propias) }
  }

  Chequeo 'qbit-conexion' {
    $tr = Api qbit 'transfer/info' 'GET' $null 5
    $(if ($tr.connection_status -eq 'connected') { 'ok' } elseif ($tr.connection_status -eq 'firewalled') { 'info' } else { 'falla' }), @{ estado = $tr.connection_status; dht = $tr.dht_nodes }
  }

  Chequeo 'clientes-descarga' {
    $fallas = @()
    foreach ($app in 'radarr', 'sonarr') {
      $nom = @{}; Api $app 'downloadclient' | ForEach-Object { $nom[[int]$_.id] = $_.name }
      foreach ($t in @(Api $app 'downloadclient/testall' 'POST' $null 30)) {
        if ($t -and -not $t.isValid) { $fallas += [ordered]@{ app = $app; nombre = $nom[[int]$t.id]; error = (@($t.validationFailures | ForEach-Object { $_.errorMessage }) -join '; ') } }
      }
    }
    $(if ($fallas) { 'falla' } else { 'ok' }), @{ fallas = $fallas }
  }

  Chequeo 'prowlarr-apps' {
    $nom = @{}; Api prowlarr 'applications' | ForEach-Object { $nom[[int]$_.id] = $_.name }
    $fallas = @()
    foreach ($t in @(Api prowlarr 'applications/testall' 'POST' $null 30)) {
      if ($t -and -not $t.isValid) { $fallas += [ordered]@{ nombre = $nom[[int]$t.id]; error = (@($t.validationFailures | ForEach-Object { $_.errorMessage }) -join '; ') } }
    }
    $(if ($fallas) { 'falla' } else { 'ok' }), @{ fallas = $fallas; apps = @($nom.Values) }
  }

  Chequeo 'seerr-conexiones' {
    $dd = [bool](Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)
    $cs = [string]$cfg.Seerr.Contenedor
    $ins = Invoke-Docker inspect -f '{{.State.Status}}' $cs
    $destinos = @()
    if ($ins.Ok -and $ins.Salida -eq 'running') {
      foreach ($d in @(@{ n = 'Radarr'; u = "http://host.docker.internal:$($P.Radarr)/ping" }, @{ n = 'Sonarr'; u = "http://host.docker.internal:$($P.Sonarr)/ping" }, @{ n = 'Jellyfin'; u = "http://host.docker.internal:$($P.Jellyfin)/health" })) {
        $r = Invoke-Docker exec $cs wget -q -T 5 -O- $d.u
        $destinos += [ordered]@{ nombre = $d.n; ok = $r.Ok }
      }
    }
    $estado = $(if (-not $ins.Ok -or $ins.Salida -ne 'running') { 'falla' } elseif ($destinos | Where-Object { -not $_.ok }) { 'falla' } else { 'ok' })
    $estado, @{ docker = $dd; motor = $ins.Ok; contenedor = $(if ($ins.Ok) { $ins.Salida } else { '' }); destinos = $destinos }
  }

  # FlareSolverr resuelve el desafio de Cloudflare para algunos indexadores; su Chrome interno a veces se cae
  Chequeo 'flaresolverr' {
    $ins = Invoke-Docker inspect -f '{{.State.Status}}|{{.State.StartedAt}}' flaresolverr
    if (-not $ins.Ok -and $ins.Salida -match 'No such') { return 'ok', @{ existe = $false } }
    $usan = @()
    try {
      $tag = @(Api prowlarr 'tag' | Where-Object { $_.label -eq 'flaresolverr' } | ForEach-Object { [int]$_.id })
      if ($tag) { $usan = @(Api prowlarr 'indexer' | Where-Object { @($_.tags | Where-Object { [int]$_ -in $tag }).Count } | ForEach-Object { $_.name }) }
    } catch {}
    if (-not $ins.Ok) { return 'falla', @{ existe = $true; corriendo = $false; contenedor = ''; usan = $usan } }
    $estadoC, $desde = $ins.Salida -split '\|'
    # docker logs escribe los logs del contenedor por stderr: Invoke-Docker junta los dos
    $cuenta = {
      param($lineas)
      @{
        ok = @($lineas | Where-Object { $_ -match 'POST http://\S+/v1 200' }).Count
        error = @($lineas | Where-Object { $_ -match 'POST http://\S+/v1 500' }).Count
        chrome = @($lineas | Where-Object { $_ -match 'cannot connect to chrome|chrome not reachable|session not created' }).Count
      }
    }
    $h24 = & $cuenta @((Invoke-Docker logs --since 24h flaresolverr).Salida -split "`n")
    $h1 = & $cuenta @((Invoke-Docker logs --since 1h flaresolverr).Salida -split "`n")
    $responde = Test-Url 'http://127.0.0.1:8191/'
    $estado = $(if ($estadoC -ne 'running' -or -not $responde) { 'falla' } elseif ($h1.chrome -or ($h1.error -and $h1.error -ge $h1.ok)) { 'falla' } elseif ($h24.error) { 'aviso' } else { 'ok' })
    $estado, @{ existe = $true; corriendo = ($estadoC -eq 'running'); contenedor = $estadoC; desde = $desde; responde = $responde; h1 = $h1; h24 = $h24; usan = $usan }
  }

  Chequeo 'minseeders' {
    $bajos = @()
    foreach ($i in @(Api radarr 'indexer')) {
      $f = $i.fields | Where-Object name -eq 'minimumSeeders'
      if ($f -and [int]$f.value -lt 5) { $bajos += [ordered]@{ id = $i.id; nombre = $i.name; valor = [int]$f.value } }
    }
    $(if ($bajos) { 'aviso' } else { 'ok' }), @{ bajos = $bajos }
  }

  Chequeo 'jellyfin-red' {
    try { $n = Api jellyfin 'System/Configuration/network' 'GET' $null 5 }
    catch {
      $cod = $(if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 })
      return 'falla', @{ key = $false; codigo = $cod }
    }
    $c = Api jellyfin 'System/Configuration' 'GET' $null 5
    $lan = @($n.LocalNetworkSubnets); $prox = @($n.KnownProxies)
    # 10.0.0.0/8 = los servidores de zrok, solo hace falta si el acceso remoto esta habilitado
    $faltan = @(@($cfg.RedLocal, '127.0.0.0/8') | Where-Object { $_ -and $_ -notin $lan }) + @(@($(if ($cfg.Zrok.Habilitado) { '10.0.0.0/8' })) | Where-Object { $_ -and $_ -notin $prox })
    $sinLimite = (-not $c.RemoteClientBitrateLimit)
    $(if ($faltan) { 'falla' } elseif ($sinLimite) { 'aviso' } else { 'ok' }), @{ key = $true; lan = $lan; proxies = $prox; faltan = $faltan; bitrate = $c.RemoteClientBitrateLimit }
  }

  Chequeo 'ip-fija' {
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike 'vEthernet*' })
    $fija = $(if ($IpFija) { $ips | Where-Object IPAddress -eq $IpFija | Select-Object -First 1 })
    $(if (-not $IpFija) { 'info' } elseif ($fija -and $fija.PrefixOrigin -eq 'Manual') { 'ok' } elseif ($fija) { 'aviso' } else { 'falla' }), @{
      esperada = $IpFija; origen = $(if ($fija) { [string]$fija.PrefixOrigin } else { '' })
      actuales = @($ips | ForEach-Object { [ordered]@{ ip = $_.IPAddress; placa = $_.InterfaceAlias; origen = [string]$_.PrefixOrigin } })
    }
  }

  Chequeo 'dns' {
    $alias = $(if ($IpFija) { (Get-NetIPAddress -IPAddress $IpFija -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceAlias })
    if (-not $alias) { $alias = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1).Name }
    $serv = @((Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    # El nombre de un tunel propio: es lo que zrok tiene que resolver para reconectarse
    $nombre = $(if ($Tuneles) { ([uri]$Tuneles[0].Url).Host } else { 'one.one.one.one' })
    try { $null = Resolve-DnsName -Name $nombre -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop } catch { $ok = $false }
    $ms = $sw.ElapsedMilliseconds
    $(if (-not $ok) { 'falla' } elseif ($ms -gt 2000 -or $serv.Count -lt 2) { 'aviso' } else { 'ok' }), @{ servidores = $serv; ms = $ms; resuelve = $ok; placa = $alias; nombre = $nombre }
  }

  Chequeo 'zrok' {
    if (-not $Tuneles.Count) { return 'ok', @{ habilitado = $false; procesos = 0; tuneles = @() } }
    $pub = Get-Cacheado 'zrok' 0 { Test-Tuneles } $true
    $desde = (Get-Date).ToUniversalTime().AddHours(-24)
    $tun = @()
    foreach ($t in $Tuneles) {
      $err = 0; $dns = 0; $r429 = 0
      foreach ($linea in @(Get-Content -LiteralPath $t.Log -Tail 800 -ErrorAction SilentlyContinue)) {
        if ($linea -notmatch '"time":"([^"]+)"') { continue }
        try { if ([datetime]::Parse($matches[1]).ToUniversalTime() -lt $desde) { continue } } catch { continue }
        if ($linea -match '"level":"error"') { $err++ }
        if ($linea -match 'no such host') { $dns++ }
        if ($linea -match '\b429\b|Too Many Requests') { $r429++ }
      }
      $p = $pub[$t.Nombre]
      $tun += [ordered]@{ app = $t.App; url = $t.Url; ok = [bool]($p -and $p.ok); codigo = $(if ($p) { $p.codigo } else { 0 }); ms = $(if ($p) { $p.ms } else { $null }); errores = $err; dns = $dns; r429 = $r429 }
    }
    $proc = @(Get-Process zrok2 -ErrorAction SilentlyContinue).Count
    $estado = $(if ($tun | Where-Object { -not $_.ok }) { 'falla' } elseif ($tun | Where-Object { $_.r429 -or $_.dns }) { 'aviso' } else { 'ok' })
    $estado, @{ procesos = $proc; tuneles = $tun }
  }

  Chequeo 'mantenimiento' {
    $ue = 'C:\ProgramData\MediaStack\ultimo-estado.json'
    if (-not (Test-Path -LiteralPath $ue)) { return 'aviso', @{ existe = $false } }
    $j = Get-Content -LiteralPath $ue -Raw -Encoding UTF8 | ConvertFrom-Json
    $edad = [math]::Round(((Get-Date) - [datetime]$j.Fecha).TotalHours)
    $fallas = @($j.Resultados | ForEach-Object { $_ } | Where-Object { -not $_.Ok } | ForEach-Object { [ordered]@{ que = $_.Que; detalle = $_.Detalle } })
    $(if ($fallas) { 'aviso' } elseif ($edad -gt 192) { 'aviso' } else { 'ok' }), @{ existe = $true; fecha = $j.Fecha; modo = $j.Modo; horas = $edad; fallas = $fallas }
  }

  Chequeo 'bazarr-proveedores' {
    $p = @((Api bazarr 'providers' 'GET' $null 10).data | Where-Object { $_ })
    $os = $p | Where-Object name -eq 'opensubtitlescom'
    $(if (-not $os) { 'falla' } elseif ($os.status -ne 'Good') { 'aviso' } else { 'ok' }), @{ proveedores = @($p | ForEach-Object { [ordered]@{ nombre = $_.name; estado = $_.status; reintento = $_.retry } }) }
  }

  Chequeo 'disco' {
    $v = Get-Disco
    $pct = [math]::Round(100 * ($v.Size - $v.Libre) / $v.Size)
    $(if ($pct -ge $UmbralDisco) { 'aviso' } else { 'ok' }), @{ pct = $pct; umbral = $UmbralDisco; libre = $v.Libre }
  }

  # Scripts que las tareas SYSTEM ejecutan: si media (qBittorrent) o LocalService pueden modificarlos,
  # una descarga maliciosa podria terminar corriendo como SYSTEM
  Chequeo 'permisos-scripts' {
    $sids = @{ 'S-1-5-19' = 'LocalService' }
    $ud = [string]$cfg.UsuarioDescargas
    try { $sids[(New-Object Security.Principal.NTAccount($ud)).Translate([Security.Principal.SecurityIdentifier]).Value] = $ud } catch {}
    $escritura = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete, ChangePermissions, TakeOwnership'
    $mal = @()
    foreach ($f in 'Mantenimiento-Media.ps1', 'Reporte-Espacio.ps1') {
      $ruta = Join-Path $Raiz $f
      if (-not (Test-Path -LiteralPath $ruta)) { continue }
      $quien = @((Get-Acl -LiteralPath $ruta).Access | Where-Object {
          $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band $escritura) -and
          $sids.ContainsKey($(try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }))
        } | ForEach-Object { $sids[$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value] } | Select-Object -Unique)
      if ($quien) { $mal += [ordered]@{ archivo = $f; cuentas = $quien } }
    }
    # Crear archivos en la raiz: un powershell.exe falso ahi lo ejecutarian los .bat antes que el de Windows
    $sids['S-1-5-32-545'] = 'Usuarios'
    $crean = @((Get-Acl -LiteralPath $Raiz).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and $_.PropagationFlags -ne 'InheritOnly' -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]'CreateFiles, AppendData') -and
        $sids.ContainsKey($(try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }))
      } | ForEach-Object { $sids[$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value] } | Select-Object -Unique)
    if ($crean) { $mal += [ordered]@{ archivo = "$Raiz (crear archivos en la raiz)"; cuentas = $crean } }
    $(if ($mal) { 'aviso' } else { 'ok' }), @{ archivos = $mal }
  }

  Chequeo 'firewall' {
    $reglas = @(Get-NetFirewallRule -DisplayName 'NzbDrone', 'Bazarr' -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } | ForEach-Object { $_.DisplayName } | Select-Object -Unique)
    $(if ($reglas) { 'info' } else { 'ok' }), @{ reglas = $reglas }
  }

  [ordered]@{ generado = (Get-Date).ToString('s'); chequeos = $l }
}

# ===================== Espacio y candidatos =====================
function Get-Clave($f) { '{0}|{1}|{2}' -f $f.App, $f.Id, $f.Temporada }
function Get-TamDir([string]$ruta) {
  [double]((Get-ChildItem -LiteralPath $ruta -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum)
}
function Get-Espacio([bool]$forzar) {
  $v = Get-Disco
  $carpetas = Get-Cacheado 'carpetas' 900 { [ordered]@{ peliculas = Get-TamDir $cfg.RutaPeliculas; series = Get-TamDir $cfg.RutaSeries; descargas = Get-TamDir $cfg.RutaDescargas } } $forzar
  $filas = @(); $fecha = $null
  if (Test-Path -LiteralPath $ArchCsv) {
    $fecha = (Get-Item -LiteralPath $ArchCsv).LastWriteTime.ToString('s')
    $filas = @(Import-Csv -LiteralPath $ArchCsv -Encoding UTF8 | ForEach-Object {
      [ordered]@{
        # Como SYSTEM (mantenimiento semanal) el CSV sale con coma decimal: se aceptan las dos
        clave = Get-Clave $_; tipo = $_.Tipo; titulo = $_.Titulo; temporada = $_.Temporada
        gb = [double]::Parse(("$($_.GB)" -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
        agregado = $_.Agregado; vistoPor = $_.VistoPor; ultimoVisto = $_.UltimoVisto; candidato = ($_.Candidato -eq 'True')
      } })
  }
  $borrados = @()
  $logB = Join-Path $Raiz 'borrados-log.csv'
  if (Test-Path -LiteralPath $logB) { $borrados = @(Import-Csv -LiteralPath $logB -Encoding UTF8 | Select-Object -Last 8 | ForEach-Object { [ordered]@{ fecha = $_.Fecha; tipo = $_.Tipo; titulo = $_.Titulo; temporada = $_.Temporada; gb = $_.GB } }) }
  [ordered]@{
    total = $v.Size; libre = $v.Libre; pct = [math]::Round(100 * ($v.Size - $v.Libre) / $v.Size); umbral = $UmbralDisco
    carpetas = $carpetas; csvFecha = $fecha; filas = $filas; borrados = $borrados
  }
}

# ===================== Datos de la instalacion para la interfaz (sin secretos) =====================
function Get-ConfigPublica {
  [ordered]@{
    raiz = $Raiz
    bat = (Join-Path $Raiz 'Panel-Media.bat'); proteger = (Join-Path $Raiz 'Proteger-Scripts.bat')
    archivoKeyJellyfin = (Join-Path $Raiz 'secretos\jellyfin-api.txt')
    carpetas = [ordered]@{ peliculas = (Split-Path -Leaf $cfg.RutaPeliculas); series = (Split-Path -Leaf $cfg.RutaSeries); descargas = (Split-Path -Leaf $cfg.RutaDescargas) }
    ipServidor = $IpFija; redLocal = [string]$cfg.RedLocal
    usuarioDescargas = [string]$cfg.UsuarioDescargas; tareaQbit = $TareaQbit
    zrok = [bool]$cfg.Zrok.Habilitado
    diasVisto = [int]$cfg.Reporte.DiasVisto; umbralPct = $UmbralDisco
    puertos = $P
    web = [ordered]@{
      jellyfin = (Get-Local $P.Jellyfin); seerr = (Get-Local $P.Seerr); radarr = (Get-Local $P.Radarr); sonarr = (Get-Local $P.Sonarr)
      prowlarr = (Get-Local $P.Prowlarr); bazarr = (Get-Local $P.Bazarr); qbittorrent = (Get-Local $P.qBittorrent)
    }
  }
}

# ===================== Trabajos (acciones que tardan) =====================
$Trabajos = @{}
$NumTrabajo = 0

# Acciones de administrador: Panel-Accion.ps1 solo acepta acciones y objetivos de su lista
function Start-Elevado([string]$accion, [string]$objetivo, [string]$titulo) {
  $script:NumTrabajo++
  $id = $script:NumTrabajo
  $res = "accion-$id.json"
  $argumentos = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Accion {1} -Objetivo "{2}" -Resultado {3}' -f (Join-Path $Panel 'Panel-Accion.ps1'), $accion, $objetivo, $res
  try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $argumentos | Out-Null }
  catch { Log "UAC cancelado o fallido ($titulo): $($_.Exception.Message)"; return [ordered]@{ ok = $false; codigo = 'uac-cancelado' } }
  $Trabajos[$id] = @{ id = $id; tipo = 'elevado'; titulo = $titulo; inicio = Get-Date; resultado = (Join-Path $DirEstado $res); elevado = $true }
  Log "Accion elevada $id`: $accion $objetivo"
  [ordered]@{ ok = $true; trabajo = $id }
}

# Scripts propios en segundo plano (borrar, regenerar reporte), con la salida guardada para mostrarla
function Start-Trabajo([string]$tipo, [string]$titulo, [string]$comando) {
  $script:NumTrabajo++
  $id = $script:NumTrabajo
  $sal = Join-Path $DirEstado "trabajo-$id.txt"
  # *>&1 junta Write-Host y los errores en la salida normal (si no, llegan como CLIXML por stderr)
  $cmd = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; `$ProgressPreference = 'SilentlyContinue'; $comando *>&1 | Out-String -Stream -Width 300"
  $cod = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $cod" -NoNewWindow -PassThru -RedirectStandardOutput $sal -RedirectStandardError "$sal.err"
  $null = $p.Handle  # sin esto PowerShell 5.1 a veces pierde el codigo de salida
  $Trabajos[$id] = @{ id = $id; tipo = $tipo; titulo = $titulo; inicio = Get-Date; proceso = $p; salida = $sal; elevado = $false }
  Log "Trabajo $id`: $titulo"
  [ordered]@{ ok = $true; trabajo = $id }
}

function Get-Trabajo([int]$id) {
  $t = $Trabajos[$id]
  if (-not $t) { return [ordered]@{ id = $id; estado = 'desconocido' } }
  $r = [ordered]@{ id = $id; tipo = $t.tipo; titulo = $t.titulo; estado = 'corriendo'; codigo = ''; mensaje = ''; salida = '' }
  if ($t.elevado) {
    if (Test-Path -LiteralPath $t.resultado) {
      $j = Get-Content -LiteralPath $t.resultado -Raw -Encoding UTF8 | ConvertFrom-Json
      $r.estado = $(if ($j.ok) { 'ok' } else { 'error' }); $r.codigo = $j.codigo; $r.mensaje = $j.mensaje
    }
    elseif (((Get-Date) - $t.inicio).TotalMinutes -gt 5) { $r.estado = 'error'; $r.codigo = 'sin-respuesta' }
  }
  else {
    $txt = ''
    # El proceso todavia puede estar escribiendo: se abre compartido
    foreach ($f in $t.salida, "$($t.salida).err") {
      if (-not (Test-Path -LiteralPath $f)) { continue }
      try {
        $fs = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $txt += $sr.ReadToEnd(); $sr.Close()
      } catch {}
    }
    if ($txt.Length -gt 6000) { $txt = '...' + $txt.Substring($txt.Length - 6000) }
    $r.salida = $txt
    if ($t.proceso.HasExited) { $r.estado = $(if ($t.proceso.ExitCode -eq 0) { 'ok' } else { 'error' }) }
  }
  if ($r.estado -ne 'corriendo') { $t.terminado = $true }
  $r
}

function Get-TrabajosEnCurso {
  foreach ($k in @($Trabajos.Keys)) {
    if (-not $Trabajos[$k].terminado) { $x = Get-Trabajo $k; if ($x.estado -eq 'corriendo') { [ordered]@{ id = $k; titulo = $x.titulo; tipo = $x.tipo } } }
  }
}

function Test-Indexador([string]$app, [int]$id) {
  $def = Api $app "indexer/$id"
  try { $null = Api $app 'indexer/test' 'POST' $def 90; [ordered]@{ ok = $true } }
  catch { [ordered]@{ ok = $false; mensaje = (Get-MensajeError $_) } }
}

# ===================== Acciones (todas piden confirmacion en la interfaz) =====================
function Invoke-Accion($a) {
  switch ([string]$a.tipo) {
    'servicio' {
      $s = $Servicios | Where-Object { $_.Id -eq [string]$a.objetivo }
      $op = @{ iniciar = 'Iniciar'; reiniciar = 'Reiniciar'; cuenta = 'CorregirCuenta' }[[string]$a.op]
      if (-not $s -or -not $op) { throw 'Servicio u operacion desconocidos' }
      return Start-Elevado $op $s.Servicio "$($s.Nombre): $([string]$a.op)"
    }
    'tarea' {
      # Panel-Accion.ps1 recibe la clave (qbittorrent, zrok-jellyfin, zrok-seerr) y arma el nombre de la tarea
      $tareas = @{ 'qbittorrent' = $TareaQbit }
      foreach ($t in $Tuneles) { $tareas['zrok-' + $t.App.ToLower()] = $t.Tarea }
      $clave = [string]$a.objetivo
      $tn = $tareas[$clave]
      if (-not $tn) { throw 'Tarea desconocida' }
      # Los tuneles de zrok no se reinician a la fuerza: dejan el nombre ocupado y los reintentos dan 429
      if ($a.op -eq 'reiniciar' -and $clave -eq 'qbittorrent') { return Start-Elevado 'Reiniciar' $clave "$tn`: reiniciar" }
      if ($a.op -eq 'iniciar') { return Start-Elevado 'Iniciar' $clave "$tn`: iniciar" }
      throw 'Operacion no permitida'
    }
    'qbit-cerrar-copia' {
      $propias = Get-QbitPropias
      foreach ($p in $propias) { Stop-Process -Id $p -ErrorAction SilentlyContinue }
      return [ordered]@{ ok = $true; cerradas = $propias.Count }
    }
    'contenedor' {
      $c = $Contenedores | Where-Object { $_.Id -eq [string]$a.objetivo }
      $op = @{ iniciar = 'start'; reiniciar = 'restart' }[[string]$a.op]
      if (-not $c -or -not $op) { throw 'Contenedor u operacion desconocidos' }
      $r = Invoke-Docker $op $c.Docker
      return [ordered]@{ ok = $r.Ok; mensaje = $(if ($r.Ok) { '' } else { [string]$r.Salida }) }
    }
    'docker-abrir' {
      Start-Process -FilePath $DockerDesktop
      return [ordered]@{ ok = $true }
    }
    'indexador' {
      if ([string]$a.app -notin 'prowlarr', 'radarr', 'sonarr') { throw 'App desconocida' }
      return Test-Indexador ([string]$a.app) ([int]$a.id)
    }
    'minseeders' {
      $hechos = @()
      foreach ($i in @(Api radarr 'indexer')) {
        $f = $i.fields | Where-Object name -eq 'minimumSeeders'
        if ($f -and [int]$f.value -lt 5) {
          $f.value = 5
          # forceSave: si el indexador esta en pausa, la prueba previa al guardado fallaria
          $null = Api radarr "indexer/$($i.id)?forceSave=true" 'PUT' $i 30
          $hechos += $i.name
        }
      }
      return [ordered]@{ ok = $true; cambiados = $hechos }
    }
    'borrar' {
      if (@(Get-TrabajosEnCurso | Where-Object { $_.tipo -in 'borrar', 'reporte' }).Count) { return [ordered]@{ ok = $false; codigo = 'ocupado' } }
      $claves = @($a.claves | ForEach-Object { [string]$_ })
      if (-not $claves.Count) { throw 'No hay nada seleccionado' }
      if (-not (Test-Path -LiteralPath $ArchCsv)) { return [ordered]@{ ok = $false; codigo = 'csv-cambio' } }
      # Si el CSV cambio desde que lo viste (lo regenera el mantenimiento semanal), no se borra nada
      if ((Get-Item -LiteralPath $ArchCsv).LastWriteTime.ToString('s') -ne [string]$a.csvFecha) { return [ordered]@{ ok = $false; codigo = 'csv-cambio' } }
      $filas = @(Import-Csv -LiteralPath $ArchCsv -Encoding UTF8)
      $n = 0
      foreach ($f in $filas) { if ($claves -contains (Get-Clave $f)) { $f.Borrar = 'SI'; $n++ } else { $f.Borrar = '' } }
      if ($n -ne $claves.Count) { return [ordered]@{ ok = $false; codigo = 'csv-cambio' } }
      $filas | Export-Csv -LiteralPath $ArchCsv -NoTypeInformation -Encoding UTF8
      Log ("Borrar: {0}" -f ($claves -join ', '))
      return Start-Trabajo 'borrar' "Borrar $n elemento(s)" ("& '{0}' -Confirmado" -f (Join-Path $Raiz 'Borrar-Candidatos.ps1'))
    }
    'reporte' {
      if (@(Get-TrabajosEnCurso | Where-Object { $_.tipo -in 'borrar', 'reporte' }).Count) { return [ordered]@{ ok = $false; codigo = 'ocupado' } }
      $Cache.Remove('carpetas')
      return Start-Trabajo 'reporte' 'Regenerar la lista de candidatos' ("& '{0}'" -f (Join-Path $Raiz 'Reporte-Espacio.ps1'))
    }
  }
  throw "Accion desconocida: $($a.tipo)"
}

# ===================== Servidor HTTP (solo 127.0.0.1) =====================
function Open-Ventana([int]$puerto, [string]$token) {
  $url = "http://127.0.0.1:$puerto/?t=$token"
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ($edge) { Start-Process -FilePath $edge -ArgumentList "--app=$url", '--window-size=1440,960' } else { Start-Process $url }
}

function Test-Igual([string]$a, [string]$b) {
  if ($a.Length -ne $b.Length) { return $false }
  $d = 0; for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ([int]$a[$i] -bxor [int]$b[$i]) }
  $d -eq 0
}

function Send-Respuesta($ctx, [int]$codigo, $cuerpo, [string]$tipo = 'application/json; charset=utf-8') {
  $res = $ctx.Response
  $res.StatusCode = $codigo
  $res.ContentType = $tipo
  $res.AddHeader('Cache-Control', 'no-store')
  $res.AddHeader('X-Content-Type-Options', 'nosniff')
  $res.AddHeader('X-Frame-Options', 'DENY')
  $res.AddHeader('Referrer-Policy', 'no-referrer')
  $res.AddHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
  if ($cuerpo -is [byte[]]) { $bytes = $cuerpo }
  elseif ($cuerpo -is [string]) { $bytes = [Text.Encoding]::UTF8.GetBytes($cuerpo) }
  else { $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $cuerpo -Depth 10 -Compress)) }
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}

$Estaticos = @{
  '/'           = @{ Archivo = 'index.html'; Tipo = 'text/html; charset=utf-8' }
  '/app.js'     = @{ Archivo = 'app.js';     Tipo = 'text/javascript; charset=utf-8' }
  '/estilo.css' = @{ Archivo = 'estilo.css'; Tipo = 'text/css; charset=utf-8' }
}

function Invoke-Pedido($ctx) {
  $req = $ctx.Request
  $ruta = $req.Url.AbsolutePath
  # Solo esta PC, y solo con el Host exacto (evita DNS rebinding)
  if (-not [Net.IPAddress]::IsLoopback($req.RemoteEndPoint.Address) -or $req.Headers['Host'] -ne "127.0.0.1:$Puerto") {
    return Send-Respuesta $ctx 403 'Prohibido' 'text/plain; charset=utf-8'
  }
  if ($ruta -eq '/ping') { return Send-Respuesta $ctx 200 'ok' 'text/plain; charset=utf-8' }

  # Primera entrada: el token viaja en la URL una sola vez, se guarda en una cookie y se saca de la URL
  if ($ruta -eq '/' -and $req.QueryString['t']) {
    if (-not (Test-Igual $req.QueryString['t'] $Token)) { return Send-Respuesta $ctx 403 'Token invalido. Abri el panel con Panel-Media.bat.' 'text/plain; charset=utf-8' }
    $ctx.Response.AddHeader('Set-Cookie', "$NombreCookie=$Token; Path=/; HttpOnly; SameSite=Strict")
    $ctx.Response.AddHeader('Location', '/')
    return Send-Respuesta $ctx 302 '' 'text/plain; charset=utf-8'
  }
  $c = $req.Cookies[$NombreCookie]
  if (-not $c -or -not (Test-Igual $c.Value $Token)) { return Send-Respuesta $ctx 403 "Abri el panel con $(Join-Path $Raiz 'Panel-Media.bat')." 'text/plain; charset=utf-8' }

  if ($req.HttpMethod -eq 'GET' -and $Estaticos.ContainsKey($ruta)) {
    $e = $Estaticos[$ruta]
    return Send-Respuesta $ctx 200 ([IO.File]::ReadAllBytes((Join-Path $Web $e.Archivo))) $e.Tipo
  }

  $forzar = ($req.QueryString['forzar'] -eq '1')
  if ($req.HttpMethod -eq 'GET') {
    switch ($ruta) {
      '/api/config'      { return Send-Respuesta $ctx 200 (Get-ConfigPublica) }
      '/api/estado'      { return Send-Respuesta $ctx 200 (Get-Estado) }
      '/api/salud'       { return Send-Respuesta $ctx 200 (Get-Cacheado 'salud' 60 { Get-Salud } $forzar) }
      '/api/diagnostico' { return Send-Respuesta $ctx 200 (Get-Cacheado 'diag' 300 { Get-Diagnostico } $forzar) }
      '/api/espacio'     { return Send-Respuesta $ctx 200 (Get-Espacio $forzar) }
      '/api/trabajo'     { return Send-Respuesta $ctx 200 (Get-Trabajo ([int]$req.QueryString['id'])) }
    }
  }
  if ($req.HttpMethod -eq 'POST' -and $ruta -eq '/api/accion') {
    # Solo desde la propia pagina del panel: mismo origen y encabezado propio
    if ($req.Headers['Origin'] -ne "http://127.0.0.1:$Puerto" -or $req.Headers['X-Panel'] -ne '1') { return Send-Respuesta $ctx 403 'Origen no permitido' 'text/plain; charset=utf-8' }
    if ($req.ContentLength64 -gt 100000) { return Send-Respuesta $ctx 413 'Demasiado grande' 'text/plain; charset=utf-8' }
    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    $a = $sr.ReadToEnd() | ConvertFrom-Json
    $sr.Close()
    Log "Accion: $($a.tipo) $($a.op) $($a.objetivo)$($a.app) $($a.id)"
    $r = Invoke-Accion $a
    # Lo que cambio se vuelve a medir en el proximo pedido
    $Cache.Remove('diag'); $Cache.Remove('salud')
    return Send-Respuesta $ctx 200 $r
  }
  Send-Respuesta $ctx 404 'No existe' 'text/plain; charset=utf-8'
}

# --- Una sola instancia: si ya hay un panel abierto, se abre otra ventana del mismo ---
if (Test-Path -LiteralPath $ArchInstancia) {
  try {
    $i = Get-Content -LiteralPath $ArchInstancia -Raw | ConvertFrom-Json
    if (Get-Process -Id $i.Pid -ErrorAction SilentlyContinue) {
      $null = Invoke-WebRequest -Uri "http://127.0.0.1:$($i.Puerto)/ping" -UseBasicParsing -TimeoutSec 3
      if (-not $SinNavegador) { Open-Ventana $i.Puerto $i.Token }
      return
    }
  } catch {}
}

# Puerto libre al azar en 127.0.0.1
$tcp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$tcp.Start(); $Puerto = ([Net.IPEndPoint]$tcp.LocalEndpoint).Port; $tcp.Stop()
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$Token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
$NombreCookie = "panel_media_$Puerto"

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Puerto/")
$listener.Start()
[ordered]@{ Pid = $PID; Puerto = $Puerto; Token = $Token; Inicio = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -LiteralPath $ArchInstancia -Encoding UTF8
Log "Panel iniciado en http://127.0.0.1:$Puerto (pid $PID)"
if (-not $SinNavegador) { Open-Ventana $Puerto $Token }

$UltimoPedido = Get-Date
try {
  while ($true) {
    $ar = $listener.BeginGetContext($null, $null)
    while (-not $ar.AsyncWaitHandle.WaitOne(1000)) {
      # Sin pedidos (ventana cerrada) y sin trabajos en curso: se apaga
      if (((Get-Date) - $UltimoPedido).TotalSeconds -gt $Inactividad -and -not @(Get-TrabajosEnCurso).Count) { throw 'inactivo' }
    }
    $ctx = $listener.EndGetContext($ar)
    $UltimoPedido = Get-Date
    try { Invoke-Pedido $ctx }
    catch {
      Log "Error en $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath): $($_.Exception.Message)"
      try { Send-Respuesta $ctx 500 ([ordered]@{ error = $_.Exception.Message }) } catch {}
    }
  }
}
catch { if ("$_" -ne 'inactivo') { Log "Error fatal: $($_.Exception.Message)" } }
finally {
  $listener.Stop(); $listener.Close()
  Remove-Item -LiteralPath $ArchInstancia -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $DirEstado -Include 'trabajo-*', 'accion-*' -File -Recurse | Where-Object LastWriteTime -lt (Get-Date).AddDays(-7) | Remove-Item -ErrorAction SilentlyContinue
  Log 'Panel cerrado'
}
