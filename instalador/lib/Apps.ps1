# Apps.ps1 - Instalacion y configuracion de las apps (idempotente). Requiere Comun.ps1 y Arr.ps1.

$script:Winget = @(
  @{ Id = 'Jellyfin.Server';         Nombre = 'Jellyfin';    Servicio = 'JellyfinServer'; Extra = @() },
  @{ Id = 'TeamRadarr.Radarr';       Nombre = 'Radarr';      Servicio = 'Radarr';         Extra = @() },
  @{ Id = 'TeamSonarr.Sonarr';       Nombre = 'Sonarr';      Servicio = 'Sonarr';         Extra = @() },
  @{ Id = 'TeamProwlarr.Prowlarr';   Nombre = 'Prowlarr';    Servicio = 'Prowlarr';       Extra = @() },
  @{ Id = 'Morpheus.Bazarr';         Nombre = 'Bazarr';      Servicio = 'Bazarr';         Extra = @('--location', 'C:\Bazarr') },
  @{ Id = 'qBittorrent.qBittorrent'; Nombre = 'qBittorrent'; Servicio = $null;            Extra = @() }
)
$script:Excluidos = '*.exe, *.lnk, *.scr, *.bat, *.cmd, *.com, *.pif, *.vbs, *.js, *.msi, *.zipx'

function Test-Instalado([string]$id) {
  $s = (winget list --id $id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
  $s -match [regex]::Escape($id)
}

function Install-Apps {
  foreach ($a in $script:Winget) {
    if (Test-Instalado $a.Id) { Ok "$($a.Nombre) ya esta instalado" }
    else {
      Invoke-Cambio "instalar $($a.Nombre) con winget" {
        $arg = @('install', '--id', $a.Id, '--exact', '--silent', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + $a.Extra
        winget @arg 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "$($a.Nombre) instalado" } else { Falla "winget no pudo instalar $($a.Nombre) (codigo $LASTEXITCODE)" }
      }
    }
    # El instalador silencioso de Sonarr a veces no crea el servicio
    if ($a.Servicio -and -not (Get-Service -Name $a.Servicio -ErrorAction SilentlyContinue)) {
      $si = "C:\ProgramData\$($a.Nombre)\bin\ServiceInstall.exe"
      if (Test-Path -LiteralPath $si) { Invoke-Cambio "registrar el servicio de $($a.Nombre)" { & $si | Out-Null; Start-Sleep -Seconds 5; Ok "Servicio $($a.Servicio) creado" } }
      elseif (-not $script:SoloRevisar) { Falla "No existe el servicio $($a.Servicio)" }
    }
  }
}

# Carpetas donde los servicios y el usuario de descargas escriben. La raiz NO: ahi estan los scripts
# que el mantenimiento ejecuta como SYSTEM (Proteger-Scripts la deja de solo lectura para ellos).
function Get-CarpetasDatos($cfg) { @($cfg.RutaPeliculas, $cfg.RutaSeries, $cfg.RutaDescargas, (Join-Path $cfg.Raiz '_obsoleto')) }

function Set-Carpetas($cfg) {
  foreach ($d in @($cfg.Raiz) + (Get-CarpetasDatos $cfg) + @((Join-Path $cfg.RutaDescargas 'radarr'), (Join-Path $cfg.RutaDescargas 'sonarr'))) {
    if (Test-Path -LiteralPath $d) { continue }
    Invoke-Cambio "crear $d" { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
  # LocalService: Radarr, Sonarr y Bazarr mueven, renombran y escriben subtitulos
  foreach ($d in Get-CarpetasDatos $cfg) { Grant-Modificar $d '*S-1-5-19' }
  $sec = Join-Path $cfg.Raiz 'secretos'
  if (-not (Test-Path -LiteralPath $sec)) {
    Invoke-Cambio "crear $sec (solo tu usuario, Administradores y SYSTEM)" {
      New-Item -ItemType Directory -Force -Path $sec | Out-Null
      icacls $sec /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    }
  }
  Ok "Carpetas en $($cfg.Raiz)"
}

# --- qBittorrent con usuario restringido ---
function Set-Qbittorrent($cfg) {
  $usuario = $cfg.UsuarioDescargas
  $perfil = "C:\ProgramData\qBittorrent-$usuario"
  $ini = Join-Path $perfil 'qBittorrent\config\qBittorrent.ini'
  $tarea = "qBittorrent ($usuario)"
  $api = "http://127.0.0.1:$($cfg.Puertos.qBittorrent)/api/v2"

  $clave = $null
  if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
    Info "Se crea el usuario de Windows '$usuario' (estandar, sin acceso a tus documentos) para correr qBittorrent."
    if (-not $script:SoloRevisar) { $clave = Preguntar-Clave "Contrasena para el usuario '$usuario'" 8 }
    Invoke-Cambio "crear el usuario '$usuario'" {
      New-LocalUser -Name $usuario -Password $clave -FullName 'qBittorrent' -Description 'Usuario restringido para qBittorrent' -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
      Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $usuario
      $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
      New-Item -Path $k -Force | Out-Null; New-ItemProperty -Path $k -Name $usuario -Value 0 -PropertyType DWord -Force | Out-Null
      Ok "Usuario '$usuario' creado y oculto del inicio de sesion"
    }
  }
  else { Ok "El usuario '$usuario' ya existe" }

  # Derecho "Iniciar sesion como proceso por lotes" (sin esto la tarea programada no arranca)
  if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) {
    $sid = (Get-LocalUser -Name $usuario).SID.Value
    $tmp = Join-Path $env:TEMP 'media-sec'
    secedit /export /cfg "$tmp.inf" /areas USER_RIGHTS | Out-Null
    $linea = (Select-String -LiteralPath "$tmp.inf" -Pattern '^SeBatchLogonRight\s*=' | Select-Object -First 1).Line
    if ("$linea" -notmatch [regex]::Escape("*$sid")) {
      Invoke-Cambio "dar a '$usuario' el derecho de iniciar sesion como proceso por lotes" {
        $nueva = $(if ($linea) { "$linea,*$sid" } else { "SeBatchLogonRight = *$sid" })
        @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]', $nueva) | Set-Content -LiteralPath "$tmp-nuevo.inf" -Encoding Unicode
        secedit /configure /db "$tmp.sdb" /cfg "$tmp-nuevo.inf" /areas USER_RIGHTS | Out-Null
      }
    }
    Remove-Item -Path "$tmp*" -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $ini)) {
    Info 'qBittorrent muestra un aviso legal: el software no se hace responsable de lo que descargues.'
    $acepta = $script:SoloRevisar -or (Preguntar-SiNo 'Aceptas el aviso legal de qBittorrent?' $false)
    if (-not $acepta) { Add-Pendiente 'qBittorrent: aceptar su aviso legal (sin eso no arranca)'; return }
    Info 'La Web UI de qBittorrent (solo en esta PC) necesita usuario y contrasena.'
    $webClave = $(if ($script:SoloRevisar) { $null } else { Preguntar-Clave 'Contrasena para la Web UI de qBittorrent (usuario admin)' 6 })
    Invoke-Cambio "crear la configuracion de qBittorrent en $perfil" {
      New-Item -ItemType Directory -Force -Path (Split-Path $ini) | Out-Null
      @('[LegalNotice]', 'Accepted=true', '', '[WebUI]', 'Enabled=true', 'Address=127.0.0.1', "Port=$($cfg.Puertos.qBittorrent)", 'LocalHostAuth=false',
        'Username=admin', ('Password_PBKDF2="{0}"' -f (Get-HashQbittorrent $webClave))) | Set-Content -LiteralPath $ini -Encoding UTF8
      Ok 'Configuracion inicial de qBittorrent'
    }
  }
  if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) { foreach ($d in Get-CarpetasDatos $cfg) { Grant-Modificar $d $usuario } }
  if (Test-Path -LiteralPath $perfil) { Grant-Modificar $perfil $usuario }

  if (-not (Get-ScheduledTask -TaskName $tarea -ErrorAction SilentlyContinue)) {
    if (-not $clave -and -not $script:SoloRevisar) { $clave = Read-Host "Contrasena del usuario '$usuario' (la necesita la tarea programada)" -AsSecureString }
    Invoke-Cambio "tarea programada '$tarea'" {
      Get-Process qbittorrent -ErrorAction SilentlyContinue | Stop-Process -Force
      $accion = New-ScheduledTaskAction -Execute 'C:\Program Files\qBittorrent\qbittorrent.exe' -Argument "--profile=$perfil"
      $ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
      Register-ScheduledTask -TaskName $tarea -Action $accion -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $ajustes `
        -User "$env:COMPUTERNAME\$usuario" -Password (Get-Plano $clave) -RunLevel Limited -Description "qBittorrent como '$usuario'" -Force | Out-Null
      Start-ScheduledTask -TaskName $tarea
      Ok "Tarea '$tarea' creada y en marcha"
    }
  }
  else { Ok "Tarea '$tarea'" }

  if ($script:SoloRevisar) { return }
  if (-not (Wait-Url "$api/app/version" 90)) { Falla "qBittorrent no responde en $api"; Add-Pendiente "qBittorrent no responde: revisar la tarea '$tarea'"; return }
  $prefs = @{ save_path = $cfg.RutaDescargas; auto_tmm_enabled = $true; torrent_changed_tmm_enabled = $true; save_path_changed_tmm_enabled = $true
    category_changed_tmm_enabled = $true; excluded_file_names_enabled = $true; excluded_file_names = ($script:Excluidos -replace ', ', "`n"); web_ui_address = '127.0.0.1' } | ConvertTo-Json -Compress
  Invoke-RestMethod "$api/app/setPreferences" -Method Post -Body @{ json = $prefs } | Out-Null
  $cats = Invoke-RestMethod "$api/torrents/categories"
  foreach ($c in 'radarr', 'sonarr') {
    $accion = $(if ($cats.PSObject.Properties.Name -contains $c) { 'editCategory' } else { 'createCategory' })
    Invoke-RestMethod "$api/torrents/$accion" -Method Post -Body @{ category = $c; savePath = (Join-Path $cfg.RutaDescargas $c) } | Out-Null
  }
  Ok 'qBittorrent: rutas, categorias radarr/sonarr, modo automatico y archivos peligrosos excluidos'
}

# --- Bazarr ---
function Get-BazarrKey { [regex]::Match((Get-Content -LiteralPath 'C:\ProgramData\Bazarr\config\config.yaml' -Raw), '(?ms)^auth:.*?^\s+apikey:\s*([0-9a-f]+)').Groups[1].Value }
function Invoke-Bazarr([string]$metodo, [string]$ruta, [object[]]$pares) {
  $cuerpo = $null
  if ($pares) { $cuerpo = ($pares | ForEach-Object { [uri]::EscapeDataString($_[0]) + '=' + [uri]::EscapeDataString([string]$_[1]) }) -join '&' }
  Invoke-Api "http://127.0.0.1:$($script:PuertoBazarr)/api/$ruta" $metodo $cuerpo @{ 'X-API-KEY' = (Get-BazarrKey) } 'application/x-www-form-urlencoded'
}

function Set-Bazarr($cfg) {
  $script:PuertoBazarr = $cfg.Puertos.Bazarr
  Grant-Modificar 'C:\ProgramData\Bazarr' '*S-1-5-19'
  Set-CuentaServicio 'Bazarr' 'NT AUTHORITY\LocalService'
  if ($script:SoloRevisar) { Info '(revision) Bazarr: se conectaria a Radarr/Sonarr y se crearia el perfil Latino'; return }
  if (-not (Wait-Url "http://127.0.0.1:$($script:PuertoBazarr)/" 120)) { Falla 'Bazarr no responde'; return }
  $s = Invoke-Bazarr GET 'system/settings'
  if ($s.general.use_radarr -and $s.general.use_sonarr -and $s.general.ip -eq '127.0.0.1') { Ok 'Bazarr ya configurado'; return }
  $perfil = ConvertTo-Json -Depth 5 -Compress @(@{ profileId = 1; name = 'Latino'; cutoff = $null; originalFormat = $null; tag = $null; mustContain = @(); mustNotContain = @()
      items = @(@{ id = 1; language = 'ea'; audio_exclude = 'True'; audio_only_include = 'False'; hi = 'False'; forced = 'False' }) })
  # Cada par va en su propio @(): un form de un solo par se aplana en PowerShell
  $null = Invoke-Bazarr POST 'system/settings' @(
    @('settings-general-use_radarr', 'true'), @('settings-general-use_sonarr', 'true'),
    @('settings-radarr-ip', '127.0.0.1'), @('settings-radarr-port', "$($cfg.Puertos.Radarr)"), @('settings-radarr-apikey', (Get-ArrKey 'Radarr')),
    @('settings-sonarr-ip', '127.0.0.1'), @('settings-sonarr-port', "$($cfg.Puertos.Sonarr)"), @('settings-sonarr-apikey', (Get-ArrKey 'Sonarr')),
    @('languages-enabled', 'ea'), @('languages-profiles', $perfil),
    @('settings-general-serie_default_enabled', 'true'), @('settings-general-serie_default_profile', '1'),
    @('settings-general-movie_default_enabled', 'true'), @('settings-general-movie_default_profile', '1'),
    @('settings-general-enabled_providers', 'embeddedsubtitles'), @('settings-general-ip', '127.0.0.1'))
  try { $null = Invoke-Bazarr POST 'system?action=restart' } catch { }
  Ok 'Bazarr: Radarr y Sonarr conectados, perfil Latino por defecto, solo en 127.0.0.1'
  Add-Pendiente "Bazarr: cargar tu cuenta de OpenSubtitles.com en http://127.0.0.1:$($cfg.Puertos.Bazarr) > Settings > Providers"
}

# --- Jellyfin ---
function Set-Jellyfin($cfg) {
  $base = "http://127.0.0.1:$($cfg.Puertos.Jellyfin)"
  if (-not (Wait-Url "$base/System/Info/Public" 180)) { Falla 'Jellyfin no responde'; return }
  $cfg | Add-Member -NotePropertyName CuentaJellyfin -NotePropertyValue (Get-CimInstance Win32_Service -Filter "Name='JellyfinServer'").StartName -Force
  if ($script:SoloRevisar) { Info '(revision) Jellyfin: bibliotecas, redes y limites remotos'; return }
  while (-not (Invoke-Api "$base/System/Info/Public").StartupWizardCompleted) {
    Info "Completa el asistente de Jellyfin en $base (crea tu usuario administrador)."
    Start-Process $base
    Esperar-Enter 'Cuando termines el asistente'
  }
  $archivoKey = Join-Path $cfg.Raiz 'secretos\jellyfin-api.txt'
  if (-not (Test-Path -LiteralPath $archivoKey)) {
    Info 'Jellyfin > Panel de control > Claves de API > + (nombre: Servidor). Copia la clave.'
    $k = Get-Plano (Read-Host 'Pega la clave de API de Jellyfin' -AsSecureString)
    Set-Content -LiteralPath $archivoKey -Value $k.Trim() -Encoding ASCII -NoNewline
  }
  $H = @{ Authorization = ('MediaBrowser Token="{0}"' -f (Get-Content -LiteralPath $archivoKey -Raw).Trim()) }
  try { $null = Invoke-Api "$base/Users" GET $null $H } catch { Falla 'Jellyfin rechazo la clave de API'; Add-Pendiente "Revisar $archivoKey"; return }

  $libs = @(Invoke-Api "$base/Library/VirtualFolders" GET $null $H)
  foreach ($l in @(@{ Nombre = $cfg.Peliculas; Tipo = 'movies'; Ruta = $cfg.RutaPeliculas }, @{ Nombre = $cfg.Series; Tipo = 'tvshows'; Ruta = $cfg.RutaSeries })) {
    if ($libs | Where-Object { $_.Locations -contains $l.Ruta }) { Ok "Jellyfin: biblioteca $($l.Ruta)"; continue }
    $q = 'name={0}&collectionType={1}&refreshLibrary=true' -f [uri]::EscapeDataString($l.Nombre), $l.Tipo
    $null = Invoke-Api "$base/Library/VirtualFolders?$q" POST @{ LibraryOptions = @{ PathInfos = @(@{ Path = $l.Ruta }) } } $H
    Ok "Jellyfin: biblioteca $($l.Nombre) -> $($l.Ruta)"
  }

  $red = Invoke-Api "$base/System/Configuration/network" GET $null $H
  $red.LocalNetworkSubnets = @(@($cfg.RedLocal, '127.0.0.0/8') | Where-Object { $_ })
  if ($cfg.Zrok.Habilitado) { $red.KnownProxies = @('127.0.0.1', '10.0.0.0/8') }
  $null = Invoke-Api "$base/System/Configuration/network" POST $red $H
  $srv = Invoke-Api "$base/System/Configuration" GET $null $H
  $srv.RemoteClientBitrateLimit = 4000000
  $null = Invoke-Api "$base/System/Configuration" POST $srv $H
  foreach ($u in @(Invoke-Api "$base/Users" GET $null $H)) {
    if ($u.Policy.LoginAttemptsBeforeLockout -eq 5) { continue }
    $pol = $u.Policy; $pol.LoginAttemptsBeforeLockout = 5
    $null = Invoke-Api "$base/Users/$($u.Id)/Policy" POST $pol $H
  }
  Ok 'Jellyfin: redes LAN, limite remoto 4 Mbps y bloqueo tras 5 intentos'
  Add-Pendiente 'Jellyfin: reiniciarlo desde el Panel de control para aplicar los cambios de red'
}

# --- Seerr (Docker Desktop) ---
function Get-Docker {
  $p = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  & $p info --format '{{.ServerVersion}}' 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $p } else { $null }
}

function Set-Seerr($cfg) {
  $S = $cfg.Seerr; $P = $cfg.Puertos
  if (-not (Test-Path 'C:\Program Files\Docker\Docker\Docker Desktop.exe')) {
    if (-not (Preguntar-SiNo 'Seerr necesita Docker Desktop. Lo instalo?' $true)) { Add-Pendiente 'Seerr: instalar Docker Desktop y volver a ejecutar el instalador'; return }
    Invoke-Cambio 'instalar Docker Desktop' { winget install --id Docker.DockerDesktop --exact --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null }
  }
  $docker = Get-Docker
  while (-not $docker -and -not $script:SoloRevisar) {
    Info 'Abri Docker Desktop desde el menu Inicio, acepta su acuerdo y espera "Engine running". Activa "Start Docker Desktop when you sign in".'
    Esperar-Enter 'Cuando Docker Desktop este corriendo'
    $docker = Get-Docker
  }
  if ($script:SoloRevisar -and -not $docker) { Info '(revision) Docker Desktop no esta corriendo'; return }
  $estado = & $docker inspect -f '{{.State.Status}}' $S.Contenedor 2>$null
  if (-not $estado) {
    Invoke-Cambio "crear el contenedor $($S.Contenedor)" {
      & $docker volume create $S.Volumen | Out-Null
      & $docker run -d --name $S.Contenedor --init --restart unless-stopped -p "$($P.Seerr):5055" -e "TZ=$($cfg.ZonaHoraria)" -e LOG_LEVEL=info -v "$($S.Volumen):/app/config" $S.Imagen | Out-Null
      Ok "Seerr en http://127.0.0.1:$($P.Seerr)"
    }
  }
  else { Ok "Contenedor $($S.Contenedor): $estado" }
  if ($script:SoloRevisar) { return }
  $base = "http://127.0.0.1:$($P.Seerr)/api/v1"
  if (-not (Wait-Url "$base/status" 120)) { Falla 'Seerr no responde'; return }
  while (-not (Invoke-Api "$base/settings/public").initialized) {
    Info "Completa el asistente de Seerr en http://127.0.0.1:$($P.Seerr):"
    Info "  Jellyfin -> host.docker.internal, puerto $($P.Jellyfin), tu usuario admin de Jellyfin. En Radarr/Sonarr toca Finish Setup sin completar nada."
    Start-Process "http://127.0.0.1:$($P.Seerr)"
    Esperar-Enter 'Cuando termines el asistente'
  }
  $key = ((& $docker exec $S.Contenedor cat /app/config/settings.json) -join "`n" | ConvertFrom-Json).main.apiKey
  $H = @{ 'X-Api-Key' = $key }
  $ip = $(if ($cfg.IpServidor) { $cfg.IpServidor } else { '127.0.0.1' })
  foreach ($a in @(@{ App = 'radarr'; Puerto = $P.Radarr; Perfil = 'Mejor disponible'; Ruta = $cfg.RutaPeliculas }, @{ App = 'sonarr'; Puerto = $P.Sonarr; Perfil = 'HD-1080p'; Ruta = $cfg.RutaSeries })) {
    if (@(Invoke-Api "$base/settings/$($a.App)" GET $null $H) | Where-Object { $_ }) { Ok "Seerr: $($a.App) conectado"; continue }
    $perfil = @(Arr $a.App GET 'qualityprofile') | Where-Object name -eq $a.Perfil | Select-Object -First 1
    $c = @{ name = (Get-Culture).TextInfo.ToTitleCase($a.App); hostname = 'host.docker.internal'; port = $a.Puerto; apiKey = (Get-ArrKey ((Get-Culture).TextInfo.ToTitleCase($a.App))); useSsl = $false; baseUrl = ''
      activeProfileId = $perfil.id; activeProfileName = $perfil.name; activeDirectory = $a.Ruta; tags = @(); is4k = $false; isDefault = $true
      externalUrl = "http://localhost:$($a.Puerto)"; syncEnabled = $true; preventSearch = $false }
    if ($a.App -eq 'radarr') { $c.minimumAvailability = 'released' }
    else { $c += @{ seriesType = 'standard'; animeSeriesType = 'anime'; activeAnimeProfileId = $perfil.id; activeAnimeProfileName = $perfil.name; activeAnimeDirectory = $a.Ruta; animeTags = @(); enableSeasonFolders = $true } }
    $null = Invoke-Api "$base/settings/$($a.App)" POST $c $H
    Ok "Seerr: $($a.App) conectado (perfil $($perfil.name))"
  }
  $main = Invoke-Api "$base/settings/main" GET $null $H | Select-Object * -ExcludeProperty apiKey
  $main.applicationUrl = "http://${ip}:$($P.Seerr)"; $main.locale = 'es'
  $null = Invoke-Api "$base/settings/main" POST $main $H
  $jf = Invoke-Api "$base/settings/jellyfin" GET $null $H
  $null = Invoke-Api "$base/settings/jellyfin" POST @{ ip = $jf.ip; port = $jf.port; useSsl = $jf.useSsl; urlBase = $jf.urlBase; externalHostname = "http://${ip}:$($P.Jellyfin)"; jellyfinForgotPasswordUrl = $jf.jellyfinForgotPasswordUrl } $H
  Ok 'Seerr: direcciones de la red de la casa e idioma espanol'
}

# --- Red ---
function Set-Red($cfg) {
  $actual = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' -and $_.IPAddress -notlike '169.*' } |
    Sort-Object { (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue) -eq $null } | Select-Object -First 1
  if ($actual) { Info "IP actual: $($actual.IPAddress)/$($actual.PrefixLength) ($($actual.PrefixOrigin)) en '$($actual.InterfaceAlias)'" }
  if ($actual -and $actual.PrefixOrigin -eq 'Dhcp' -and $cfg.IpServidor -and $cfg.IpServidor -ne $actual.IPAddress) {
    if (Preguntar-SiNo "Fijar la IP de esta PC en $($cfg.IpServidor)? (elegi una fuera del rango del DHCP del router)" $false) {
      $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $actual.InterfaceIndex | Select-Object -First 1).NextHop
      $m = [uint64]0xFFFFFFFF -shl (32 - $actual.PrefixLength) -band 0xFFFFFFFF
      $mascara = (3..0 | ForEach-Object { ($m -shr (8 * $_)) -band 255 }) -join '.'
      Invoke-Cambio "IP fija $($cfg.IpServidor) (puerta de enlace $gw)" {
        netsh interface ipv4 set address name="$($actual.InterfaceAlias)" static $cfg.IpServidor $mascara $gw | Out-Null
        netsh interface ipv4 set dnsservers name="$($actual.InterfaceAlias)" static $gw primary | Out-Null
      }
    }
  }
  if ($actual) {
    $dns = (Get-DnsClientServerAddress -InterfaceAlias $actual.InterfaceAlias -AddressFamily IPv4).ServerAddresses
    if ($dns -notcontains '1.1.1.1') { Invoke-Cambio 'DNS de respaldo 1.1.1.1' { netsh interface ipv4 add dnsservers name="$($actual.InterfaceAlias)" 1.1.1.1 index=2 | Out-Null } }
  }
  $docker = Get-NetFirewallRule -DisplayName 'Docker Desktop Backend' -ErrorAction SilentlyContinue | Where-Object { $_.Profile -ne 'Private' }
  if ($docker) { Invoke-Cambio 'firewall: Docker Desktop solo en redes privadas' { $docker | Set-NetFirewallRule -Profile Private } }
  $viejas = Get-NetFirewallRule -DisplayName 'NzbDrone' -ErrorAction SilentlyContinue
  if ($viejas) { Invoke-Cambio 'firewall: borrar las reglas "NzbDrone" (Radarr/Sonarr/Prowlarr ya escuchan solo en 127.0.0.1)' { $viejas | Remove-NetFirewallRule } }
  Ok 'Red revisada'
}
