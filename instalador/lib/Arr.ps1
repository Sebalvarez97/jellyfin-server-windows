# Arr.ps1 - Configuracion de Radarr, Sonarr y Prowlarr por API (idempotente).
# Requiere Comun.ps1 y que Register-Arr haya registrado 'radarr', 'sonarr' y 'prowlarr'.

$script:ExtSubtitulos = 'srt,ass,ssa,sub,idx,vtt'
$script:RegexEspanol = '\b(LATINO|LATAM|CASTELLANO|SPANISH|ESPA(N|' + [char]0xD1 + ')OL|ESP|SPA)\b'
$script:RegexMulti = '\b(MULTi(\d+)?|DUAL([ ._-]?AUDIO)?)\b'

function Set-HostArr([string]$app, [string]$usuario, [Security.SecureString]$clave) {
  $h = Arr $app GET 'config/host'
  $hosts = 'localhost,127.0.0.1,host.docker.internal'
  $cambiar = $h.bindAddress -ne '127.0.0.1' -or $h.allowedHosts -ne $hosts -or $h.authenticationMethod -ne 'forms'
  if (-not $cambiar) { Ok "$app escucha solo en 127.0.0.1 y tiene login"; return }
  Invoke-Cambio "${app}: login, Bind Address 127.0.0.1 y Allowed Hosts" {
    $h.bindAddress = '127.0.0.1'; $h.allowedHosts = $hosts
    if ($h.authenticationMethod -ne 'forms') {
      $plano = Get-Plano $clave
      $h = Set-Props $h @{ authenticationMethod = 'forms'; authenticationRequired = 'disabledForLocalAddresses'; username = $usuario; password = $plano; passwordConfirmation = $plano }
    }
    $null = Arr $app PUT "config/host/$($h.id)" $h
    try { $null = Arr $app POST 'system/restart' } catch { }
    Start-Sleep -Seconds 8
    if (Wait-Url "http://127.0.0.1:$($script:Apps[$app].Puerto)/ping" 120) { Ok "$app reiniciado, solo en 127.0.0.1" } else { Falla "$app no volvio despues del reinicio" }
  }
}

function Set-CarpetaRaizArr([string]$app, [string]$ruta) {
  if (@(Arr $app GET 'rootfolder') | Where-Object { $_.path.TrimEnd('\') -eq $ruta.TrimEnd('\') }) { Ok "${app}: carpeta raiz $ruta"; return }
  Invoke-Cambio "${app}: carpeta raiz $ruta" { $null = Arr $app POST 'rootfolder' @{ path = $ruta }; Ok "${app}: carpeta raiz $ruta" }
}

function Set-NombresArr([string]$app) {
  $n = Arr $app GET 'config/naming'
  if ($app -eq 'radarr') {
    $deseado = @{ renameMovies = $true; standardMovieFormat = '{Movie Title} ({Release Year})'; movieFolderFormat = '{Movie Title} ({Release Year})' }
  }
  else {
    $ep = '{Series Title} - S{season:00}E{episode:00} - {Episode Title}'
    $deseado = @{ renameEpisodes = $true; standardEpisodeFormat = $ep; animeEpisodeFormat = $ep; seasonFolderFormat = 'Season {season:00}'; seriesFolderFormat = '{Series TitleYear}'; multiEpisodeStyle = 5 }
  }
  $dif = @($deseado.Keys | Where-Object { "$($n.$_)" -ne "$($deseado[$_])" })
  if (-not $dif) { Ok "${app}: formato de nombres"; return }
  Invoke-Cambio "${app}: formato de nombres ($($dif -join ', '))" { $null = Arr $app PUT "config/naming/$($n.id)" (Set-Props $n $deseado); Ok "${app}: formato de nombres" }
}

function Set-MediaArr([string]$app) {
  $m = Arr $app GET 'config/mediamanagement'
  $deseado = @{ copyUsingHardlinks = $true; importExtraFiles = $true; extraFileExtensions = $script:ExtSubtitulos; downloadPropersAndRepacks = 'doNotPrefer' }
  $dif = @($deseado.Keys | Where-Object { "$($m.$_)" -ne "$($deseado[$_])" })
  if (-not $dif) { Ok "${app}: hardlinks, subtitulos y repacks"; return }
  Invoke-Cambio "${app}: manejo de archivos ($($dif -join ', '))" { $null = Arr $app PUT "config/mediamanagement/$($m.id)" (Set-Props $m $deseado); Ok "${app}: hardlinks, subtitulos y repacks" }
}

function Set-ClienteDescargaArr([string]$app, [int]$puertoQbit) {
  $campo = $(if ($app -eq 'radarr') { 'movieCategory' } else { 'tvCategory' })
  $existente = @(Arr $app GET 'downloadclient') | Where-Object { $_.implementation -eq 'QBittorrent' } | Select-Object -First 1
  if ($existente) {
    $h = ($existente.fields | Where-Object name -eq 'host').value; $p = ($existente.fields | Where-Object name -eq 'port').value
    if ($h -eq '127.0.0.1' -and [int]$p -eq $puertoQbit) { Ok "${app}: cliente qBittorrent"; return }
    Invoke-Cambio "${app}: cliente qBittorrent a 127.0.0.1:$puertoQbit" { $null = Arr $app PUT "downloadclient/$($existente.id)" (Set-Fields $existente @{ host = '127.0.0.1'; port = $puertoQbit }) }
    return
  }
  Invoke-Cambio "${app}: agregar qBittorrent (categoria $app)" {
    $s = @(Arr $app GET 'downloadclient/schema') | Where-Object { $_.implementation -eq 'QBittorrent' } | Select-Object -First 1
    $s = Set-Props $s @{ name = 'qBittorrent'; enable = $true; priority = 1; removeCompletedDownloads = $true; removeFailedDownloads = $true }
    $s = Set-Fields $s @{ host = '127.0.0.1'; port = $puertoQbit; useSsl = $false; urlBase = ''; $campo = $app }
    $null = Arr $app POST 'downloadclient' $s
    Ok "${app}: cliente qBittorrent"
  }
}

# --- Custom Formats: idioma antes que resolucion ---
function Get-IdIdioma([string]$app, [string]$nombre) {
  (@(Arr $app GET 'language') | Where-Object { $_.name -eq $nombre } | Select-Object -First 1).id
}

function New-Spec($esquema, [string]$impl, [string]$nombre, $valor, [bool]$requerido, [bool]$negado = $false) {
  $s = Copy-Objeto ($esquema | Where-Object { $_.implementation -eq $impl } | Select-Object -First 1)
  $s = Set-Props $s @{ name = $nombre; required = $requerido; negate = $negado }
  foreach ($f in $s.fields) { if ($f.name -eq 'value') { $f | Add-Member -NotePropertyName value -NotePropertyValue $valor -Force } }
  $s
}

function Set-CustomFormatsArr([string]$app) {
  $esq = @(Arr $app GET 'customformat/schema')
  $latino = Get-IdIdioma $app 'Spanish (Latino)'; $espanol = Get-IdIdioma $app 'Spanish'; $original = -2
  $defs = [ordered]@{
    'Multi-audio con espanol' = @((New-Spec $esq 'ReleaseTitleSpecification' 'MULTi / DUAL en el titulo' $script:RegexMulti $true),
                                  (New-Spec $esq 'LanguageSpecification' 'Uno de los idiomas es Spanish' $espanol $false),
                                  (New-Spec $esq 'LanguageSpecification' 'Uno de los idiomas es Spanish (Latino)' $latino $false))
    'Original + espanol'      = @((New-Spec $esq 'LanguageSpecification' 'Incluye el idioma original' $original $true),
                                  (New-Spec $esq 'ReleaseTitleSpecification' 'Espanol o latino en el titulo' $script:RegexEspanol $true))
    'Latino'                  = @((New-Spec $esq 'LanguageSpecification' 'Idioma Spanish (Latino)' $latino $false),
                                  (New-Spec $esq 'ReleaseTitleSpecification' 'LATINO / LATAM en el titulo' '\b(LATINO|LATAM|LAT)\b' $false))
    'Doblada sin original'    = @((New-Spec $esq 'LanguageSpecification' 'NO incluye el idioma original' $original $true $true),
                                  (New-Spec $esq 'ReleaseTitleSpecification' 'Espanol o latino en el titulo' $script:RegexEspanol $true),
                                  (New-Spec $esq 'ReleaseTitleSpecification' 'NO es MULTi ni DUAL' $script:RegexMulti $true $true))
  }
  if ($app -eq 'radarr') { $defs['4K'] = @((New-Spec $esq 'ResolutionSpecification' 'Resolucion 2160p' 2160 $true)) }
  $existentes = @(Arr $app GET 'customformat')
  foreach ($nombre in $defs.Keys) {
    $e = $existentes | Where-Object { $_.name -eq $nombre } | Select-Object -First 1
    if ($e -and $e.specifications.Count -eq $defs[$nombre].Count) { Ok "${app}: Custom Format '$nombre'"; continue }
    Invoke-Cambio "${app}: Custom Format '$nombre'" {
      $cuerpo = @{ name = $nombre; includeCustomFormatWhenRenaming = $false; specifications = $defs[$nombre] }
      if ($e) { $cuerpo.id = $e.id; $null = Arr $app PUT "customformat/$($e.id)" $cuerpo } else { $null = Arr $app POST 'customformat' $cuerpo }
      Ok "${app}: Custom Format '$nombre'"
    }
  }
}

# Agrupa las calidades de ciertas resoluciones (sin Remux) para que valgan igual y decida el idioma
function Set-GrupoCalidad($perfil, [int[]]$resoluciones, [int]$idGrupo, [string]$nombre) {
  $todas = foreach ($it in $perfil.items) { if ($it.quality) { $it.quality } else { foreach ($s in $it.items) { $s.quality } } }
  $elegidas = @($todas | Where-Object { [int]$_.resolution -in $resoluciones -and $_.name -notmatch 'Remux|BR-DISK|Raw-HD' })
  $resto = @($todas | Where-Object { $_.id -notin $elegidas.id } | ForEach-Object { [pscustomobject]@{ quality = $_; items = @(); allowed = $false } })
  $grupo = [pscustomobject]@{ id = $idGrupo; name = $nombre; items = @($elegidas | ForEach-Object { [pscustomobject]@{ quality = $_; items = @(); allowed = $true } }); allowed = $true }
  $perfil.items = $resto + $grupo
  $perfil.cutoff = $idGrupo
  $perfil
}

function Set-PerfilesArr([string]$app) {
  $cfs = @(Arr $app GET 'customformat')
  $puntos = @{ 'Multi-audio con espanol' = 150; 'Original + espanol' = 150; 'Latino' = 100; 'Doblada sin original' = -300; '4K' = 0 }
  $perfiles = @(Arr $app GET 'qualityprofile')

  # Radarr: perfil "Mejor disponible" (1080p y 4K en un solo grupo; el 4K suma poco)
  if ($app -eq 'radarr' -and -not ($perfiles | Where-Object name -eq 'Mejor disponible')) {
    Invoke-Cambio 'radarr: crear el perfil "Mejor disponible"' {
      $base = Copy-Objeto ($perfiles | Where-Object name -eq 'HD-1080p' | Select-Object -First 1)
      $nuevo = $base | Select-Object * -ExcludeProperty id
      $nuevo.name = 'Mejor disponible'
      $nuevo = Set-GrupoCalidad $nuevo @(1080, 2160) 1004 '1080p o 4K'
      $null = Arr radarr POST 'qualityprofile' $nuevo
      Ok 'radarr: perfil "Mejor disponible"'
    }
    $perfiles = @(Arr $app GET 'qualityprofile')
  }

  foreach ($p in $perfiles) {
    $antes = $p | ConvertTo-Json -Depth 30
    foreach ($fi in $p.formatItems) {
      $n = ($cfs | Where-Object { $_.id -eq $fi.format }).name
      if ($puntos.ContainsKey($n)) { $fi.score = $puntos[$n] }
      if ($app -eq 'radarr' -and $p.name -eq 'Mejor disponible' -and $n -eq '4K') { $fi.score = 50 }
    }
    $p.minFormatScore = -1000
    if ($p.PSObject.Properties.Name -contains 'language' -and $p.language.id -ne -1) { $p.language = [pscustomobject]@{ id = -1; name = 'Any' } }
    $grupo = @{ 'HD-1080p' = @(1080, 1001, '1080p'); 'Ultra-HD' = @(2160, 1002, '2160p') }[$p.name]
    # Ya agrupado = lo unico permitido es un grupo (sin calidades sueltas permitidas)
    $agrupado = @($p.items | Where-Object { $_.allowed -and -not $_.quality }).Count -eq 1 -and -not @($p.items | Where-Object { $_.allowed -and $_.quality }).Count
    if ($grupo -and -not $agrupado) { $p = Set-GrupoCalidad $p @($grupo[0]) $grupo[1] $grupo[2] }
    if ($p.name -in 'HD-1080p', 'Ultra-HD', 'Mejor disponible') { $p.upgradeAllowed = $true; $p.cutoffFormatScore = 250; $p.minUpgradeFormatScore = 100 }
    if (($p | ConvertTo-Json -Depth 30) -eq $antes) { Ok "${app}: perfil '$($p.name)'"; continue }
    Invoke-Cambio "${app}: perfil '$($p.name)' (puntajes de idioma y calidades)" { $null = Arr $app PUT "qualityprofile/$($p.id)" $p; Ok "${app}: perfil '$($p.name)'" }
  }
}

function Set-AppsProwlarr([hashtable]$puertos) {
  $existentes = @(Arr prowlarr GET 'applications')
  $esq = @(Arr prowlarr GET 'applications/schema')
  foreach ($a in @(@{ Impl = 'Radarr'; App = 'radarr'; Carpeta = 'Radarr'; Sync = 'addOnly' }, @{ Impl = 'Sonarr'; App = 'sonarr'; Carpeta = 'Sonarr'; Sync = 'fullSync' })) {
    if ($existentes | Where-Object { $_.implementation -eq $a.Impl }) { Ok "prowlarr: conectado a $($a.Impl)"; continue }
    Invoke-Cambio "prowlarr: conectar $($a.Impl)" {
      $s = Copy-Objeto ($esq | Where-Object { $_.implementation -eq $a.Impl } | Select-Object -First 1)
      $s = Set-Props $s @{ name = $a.Impl; syncLevel = $a.Sync }
      $s = Set-Fields $s @{ prowlarrUrl = "http://localhost:$($puertos.Prowlarr)"; baseUrl = "http://localhost:$($puertos[$a.Impl])"; apiKey = (Get-ArrKey $a.Carpeta) }
      $null = Arr prowlarr POST 'applications' $s
      Ok "prowlarr: conectado a $($a.Impl)"
    }
  }
  $perfil = @(Arr prowlarr GET 'appprofile') | Where-Object { $_.name -eq 'Standard' } | Select-Object -First 1
  if ($perfil -and $perfil.minimumSeeders -lt 3) {
    Invoke-Cambio 'prowlarr: minimo 3 seeders' { $perfil.minimumSeeders = 3; $null = Arr prowlarr PUT "appprofile/$($perfil.id)" $perfil }
  }
}

# Radarr: 5 seeders minimos en todos sus indexadores (los que agrega Prowlarr llegan con 3)
function Set-SeedersRadarr([int]$minimo = 5) {
  foreach ($ix in @(Arr radarr GET 'indexer')) {
    $f = $ix.fields | Where-Object name -eq 'minimumSeeders'
    if (-not $f -or [int]$f.value -ge $minimo) { continue }
    Invoke-Cambio "radarr: $($ix.name) con minimo $minimo seeders" {
      $f | Add-Member -NotePropertyName value -NotePropertyValue $minimo -Force
      $null = Arr radarr PUT "indexer/$($ix.id)?forceSave=true" $ix
    }
  }
}
