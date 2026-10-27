<#
  Reorganizar.ps1 - Renombra/mueve archivos de la biblioteca Jellyfin segun renombrar.csv.
  Se lanza con doble click desde Reorganizar.bat.

  renombrar.csv tiene dos columnas: Origen,Destino. Las rutas pueden ser completas
  o relativas a esta carpeta (ej. Movies\Peli\archivo.mp4).
  - Primero van las filas de archivos y al final las de carpetas.
  - Si dos filas van al mismo Destino (episodio repetido), se queda el archivo mas
    grande y el mas chico va a _obsoleto (no se borra: revisalo y borralo a mano).
  - Los *-thumb.jpg y *.trickplay del archivo original van a _obsoleto
    (Jellyfin los regenera).
  - Nunca sobrescribe: si un destino ya existe, no mueve nada.
  - Cada movimiento se agrega a rename-log.csv para poder revertir.

  -Generar recorre Movies y Shows y arma renombrar.csv con los nombres que usan
  Radarr, Sonarr y Jellyfin (despues muestra la vista previa, no mueve nada):
    Movies\Titulo (Anio)\Titulo (Anio).ext
    Shows\Titulo (Anio)\Season 01\Titulo - S01E01 - Episodio.ext
  Si renombrar.csv tenia filas, se guarda antes como renombrar.anterior-<fecha>.csv.
#>
param(
  [string]$Raiz = $PSScriptRoot,
  [string]$Csv,
  [switch]$Generar,
  [string]$Peliculas,
  [string]$Series,
  [switch]$SoloMostrar,
  [switch]$SinPreguntar
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Config-Media.ps1'); $cfg = Get-ConfigMedia
if (-not $Peliculas) { $Peliculas = $cfg.Peliculas }
if (-not $Series) { $Series = $cfg.Series }
$Raiz = (Resolve-Path -LiteralPath $Raiz).Path.TrimEnd('\')
if (-not $Csv) { $Csv = Join-Path $Raiz 'renombrar.csv' }
$obsoleto = Join-Path $Raiz '_obsoleto'
$log = Join-Path $Raiz 'rename-log.csv'
$invalidos = [char[]]'\/:*?"<>|'

function Resolve-Ruta([string]$p) {
  $p = $p.Trim()
  if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Raiz $p }
  [IO.Path]::GetFullPath($p).TrimEnd('\')
}

function Test-DentroDeRaiz([string]$p) {
  $p.StartsWith($Raiz + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-Relativa([string]$p) {
  if (Test-DentroDeRaiz $p) { $p.Substring($Raiz.Length + 1) } else { $p }
}

# Ruta en $dir que no pise nada: agrega " (2)", " (3)"... si hace falta
function Get-RutaLibre([string]$dir, [string]$nombre) {
  $dest = Join-Path $dir $nombre
  $base = [IO.Path]::GetFileNameWithoutExtension($nombre)
  $ext = [IO.Path]::GetExtension($nombre)
  $n = 2
  while (Test-Path -LiteralPath $dest) {
    $dest = Join-Path $dir ('{0} ({1}){2}' -f $base, $n, $ext)
    $n++
  }
  $dest
}

# *-thumb.jpg y *.trickplay que Jellyfin genero para un video
function Get-Acompanantes([string]$archivo) {
  $dir = [IO.Path]::GetDirectoryName($archivo)
  $base = [IO.Path]::GetFileNameWithoutExtension($archivo)
  @((Join-Path $dir "$base-thumb.jpg"), (Join-Path $dir "$base.trickplay")) |
    Where-Object { Test-Path -LiteralPath $_ }
}

$registro = New-Object System.Collections.Generic.List[object]

function Move-Seguro([string]$de, [string]$a) {
  if (Test-Path -LiteralPath $a) { throw "El destino ya existe: $a" }
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($a))
  if ((Get-Item -LiteralPath $de -Force).PSIsContainer) { [IO.Directory]::Move($de, $a) }
  else { [IO.File]::Move($de, $a) }
  $registro.Add([pscustomobject]@{ Origen = $de; Destino = $a })
  Write-Host ('  {0}  ->  {1}' -f (Get-Relativa $de), (Get-Relativa $a))
}

# --- Generar: arma renombrar.csv a partir de lo que hay en Movies y Shows ---
$extVideo = '.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.ts', '.webm'
$extSub = '.srt', '.ass', '.ssa', '.sub', '.idx', '.vtt'
# Desde el primer tag de release (calidad, origen, codec...) en adelante no es parte del titulo
$basura = '(?i)[\s\.\-_\[\(](480p|576p|720p|1080p|2160p|4k|uhd|web-?dl|web-?rip|bluray|blu-ray|brrip|bdrip|dvdrip|hdtv|hdrip|remux|x26[45]|h\.?26[45]|hevc|ddp?5\.1|amzn|dsnp|hmax)(?=[\s\.\-_\]\)]|$)'

function Limpiar-Titulo([string]$t) {
  $t = $t -replace '\[[^\]]*\]', ''
  if ($t -notmatch ' ') { $t = $t -replace '[\._]', ' ' }
  ($t -replace '\s+', ' ').Trim(' ', '-', '_', '.', '(', '[')
}

# "Obsession.2026.1080p.AMZN..." / "Obsession (2026)" -> Titulo y Anio (el ultimo anio antes de los tags)
function Get-TituloAnio([string]$nombre) {
  $n = ($nombre -split $basura)[0]
  if ($n -match '^(?<t>.+)[\s\.\-_\(\[]+(?<y>(19|20)\d{2})[\)\]]?(?:[\s\.\-_].*)?$') {
    $t = Limpiar-Titulo $Matches.t
    if ($t) { return [pscustomobject]@{ Titulo = $t; Anio = $Matches.y } }
  }
  $null
}

# Numero de temporada de una carpeta (Season 1, Season 01, Temporada 2, S03, Specials); $null si no es temporada
function Get-NumeroTemporada([string]$nombre) {
  if ($nombre -match '^(?i)(Season|Temporada|S)[\s\._-]*(?<n>\d{1,3})$') { return [int]$Matches.n }
  if ($nombre -match '^(?i)(Specials|Especiales)$') { return 0 }
  $null
}

function Get-NombreTemporada([int]$n) {
  if ($n -eq 0) { 'Specials' } else { 'Season {0:00}' -f $n }
}

$propuesta = New-Object System.Collections.Generic.List[object]
$carpetasProp = New-Object System.Collections.Generic.List[object]
$avisos = New-Object System.Collections.Generic.List[string]

function Add-Fila([string]$o, [string]$d, [switch]$Carpeta) {
  if ($o -ceq $d) { return }
  if ($o -eq $d) { $avisos.Add("Solo cambian mayusculas/minusculas, renombralo a mano: $(Get-Relativa $o) -> $([IO.Path]::GetFileName($d))"); return }
  $fila = [pscustomobject]@{ Origen = (Get-Relativa $o); Destino = (Get-Relativa $d) }
  if ($Carpeta) { $carpetasProp.Add($fila) } else { $propuesta.Add($fila) }
}

# Subtitulos que acompanan a un video (Peli.srt, Peli.es.srt, Peli.es.forced.srt...)
function Add-Subtitulos([string]$video, [string]$dirDestino, [string]$baseDestino) {
  $dir = [IO.Path]::GetDirectoryName($video)
  $base = [IO.Path]::GetFileNameWithoutExtension($video)
  Get-ChildItem -LiteralPath $dir -File |
    Where-Object { $extSub -contains $_.Extension.ToLower() -and $_.Name.StartsWith("$base.", [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Add-Fila $_.FullName (Join-Path $dirDestino ($baseDestino + $_.Name.Substring($base.Length))) }
}

function Get-Videos([string]$dir, [switch]$Recursivo) {
  @(Get-ChildItem -LiteralPath $dir -File -Recurse:$Recursivo |
    Where-Object { $extVideo -contains $_.Extension.ToLower() -and $_.BaseName -notmatch '(?i)\bsample\b' } |
    Sort-Object Length -Descending)
}

function New-Propuesta {
  # Peliculas: una carpeta (o un video suelto) por pelicula
  $dirPelis = Join-Path $Raiz $Peliculas
  foreach ($item in @(Get-ChildItem -LiteralPath $dirPelis)) {
    if ($item.PSIsContainer) {
      $videos = Get-Videos $item.FullName
      $ta = Get-TituloAnio $item.Name
      if (-not $ta -and $videos.Count) { $ta = Get-TituloAnio $videos[0].BaseName }
    }
    elseif ($extVideo -contains $item.Extension.ToLower()) {
      $videos = @($item)
      $ta = Get-TituloAnio $item.BaseName
    }
    else { continue }

    if (-not $videos.Count) { $avisos.Add("Carpeta sin video: $(Get-Relativa $item.FullName)"); continue }
    if (-not $ta) { $avisos.Add("No encontre el anio en el nombre (Radarr lo necesita): $(Get-Relativa $item.FullName)"); continue }
    if ($videos.Count -gt 1) { $avisos.Add("Hay $($videos.Count) videos, solo renombro el mas grande: $(Get-Relativa $item.FullName)") }

    $nombre = '{0} ({1})' -f $ta.Titulo, $ta.Anio
    $v = $videos[0]
    if ($item.PSIsContainer) {
      # Primero el archivo dentro de la carpeta original; la carpeta se renombra al final
      Add-Fila $v.FullName (Join-Path $item.FullName "$nombre$($v.Extension)")
      Add-Subtitulos $v.FullName $item.FullName $nombre
      Add-Fila $item.FullName (Join-Path $dirPelis $nombre) -Carpeta
    }
    else {
      $dest = Join-Path $dirPelis $nombre
      Add-Fila $v.FullName (Join-Path $dest "$nombre$($v.Extension)")
      Add-Subtitulos $v.FullName $dest $nombre
    }
  }

  # Series: Serie\Season NN\Serie - SNNENN - Titulo.ext
  $dirSeries = Join-Path $Raiz $Series
  foreach ($serie in @(Get-ChildItem -LiteralPath $dirSeries -Directory)) {
    $ta = Get-TituloAnio $serie.Name
    $titulo = $(if ($ta) { $ta.Titulo } else { Limpiar-Titulo $serie.Name })
    if (-not $ta) { $avisos.Add("La serie no tiene anio en la carpeta (Sonarr la encuentra mejor como 'Titulo (Anio)'): $(Get-Relativa $serie.FullName)") }

    # Carpetas de temporada que ya existen: numero -> carpeta actual
    $temporadas = @{}
    foreach ($d in @(Get-ChildItem -LiteralPath $serie.FullName -Directory)) {
      $n = Get-NumeroTemporada $d.Name
      if ($null -eq $n) { continue }
      # Si hay dos (Season 1 y Season 01) se queda la que ya tiene el nombre correcto
      if (-not $temporadas.ContainsKey($n) -or $d.Name -ceq (Get-NombreTemporada $n)) { $temporadas[$n] = $d.FullName }
    }

    foreach ($v in (Get-Videos $serie.FullName -Recursivo)) {
      if ($v.BaseName -match '(?i)S(?<s>\d{1,2})[\s\._-]*E(?<e>\d{1,3})(?:-?E(?<e2>\d{1,3}))?' -or
          $v.BaseName -match '(?<!\d)(?<s>\d{1,2})x(?<e>\d{2,3})(?!\d)') {
        $m = $Matches
        $resto = $v.BaseName.Substring($v.BaseName.IndexOf($m[0]) + $m[0].Length)
        $ep = Limpiar-Titulo (($resto -split $basura)[0])
      }
      else {
        $avisos.Add("No encontre SxxEyy en el nombre: $(Get-Relativa $v.FullName)")
        continue
      }
      $s = [int]$m.s
      $codigo = 'S{0:00}E{1:00}' -f $s, [int]$m.e
      if ($m.e2) { $codigo += '-E{0:00}' -f [int]$m.e2 }
      $base = "$titulo - $codigo"
      if ($ep) { $base += " - $ep" }

      # Si la temporada ya tiene carpeta va ahi (con su nombre actual: se renombra al final)
      $dirDest = $(if ($temporadas.ContainsKey($s)) { $temporadas[$s] } else { Join-Path $serie.FullName (Get-NombreTemporada $s) })
      Add-Fila $v.FullName (Join-Path $dirDest "$base$($v.Extension)")
      Add-Subtitulos $v.FullName $dirDest $base
    }

    foreach ($n in ($temporadas.Keys | Sort-Object)) {
      Add-Fila $temporadas[$n] (Join-Path $serie.FullName (Get-NombreTemporada $n)) -Carpeta
    }
    if ($ta) { Add-Fila $serie.FullName (Join-Path $dirSeries ('{0} ({1})' -f $ta.Titulo, $ta.Anio)) -Carpeta }
  }
}

if ($Generar) {
  New-Propuesta
  if (Test-Path -LiteralPath $Csv) {
    if (@(Import-Csv -LiteralPath $Csv -Encoding UTF8 | Where-Object { $_.Origen -and $_.Destino }).Count) {
      $anterior = 'renombrar.anterior-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date)
      Rename-Item -LiteralPath $Csv -NewName $anterior
      Write-Host "renombrar.csv tenia filas: quedo guardado como $anterior" -ForegroundColor Yellow
    }
  }
  $todas = $propuesta.ToArray() + $carpetasProp.ToArray()
  if ($todas.Count) { $todas | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8 }
  else { 'Origen,Destino' | Out-File -LiteralPath $Csv -Encoding utf8 }

  Write-Host ''
  Write-Host "Propuesta: $($todas.Count) cambios escritos en renombrar.csv" -ForegroundColor Cyan
  if ($avisos.Count) {
    Write-Host 'Revisar a mano:' -ForegroundColor Yellow
    $avisos | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
  }
  if (-not $todas.Count) { Write-Host 'Todo tiene el nombre correcto. Nada que hacer.' -ForegroundColor Green; return }
  Write-Host 'Revisa renombrar.csv (podes editarlo o borrar filas) y despues usa la opcion 2 para ejecutarlo.'
  $SoloMostrar = $true
}

# --- Leer renombrar.csv ---
if (-not (Test-Path -LiteralPath $Csv)) {
  'Origen,Destino' | Out-File -LiteralPath $Csv -Encoding utf8
  Write-Host "No existia $Csv. Cree uno vacio: completalo y volve a ejecutar." -ForegroundColor Yellow
  return
}
$filas = @(Import-Csv -LiteralPath $Csv -Encoding UTF8 | Where-Object { $_.Origen -and $_.Destino })
if ($filas.Count -eq 0) {
  Write-Host 'renombrar.csv no tiene filas. Nada que hacer.' -ForegroundColor Yellow
  return
}

# --- Armar y validar el plan ---
$plan = @()
$errores = @()
foreach ($f in $filas) {
  $o = Resolve-Ruta $f.Origen
  $d = Resolve-Ruta $f.Destino
  if (-not (Test-DentroDeRaiz $o) -or -not (Test-DentroDeRaiz $d)) { $errores += "Fuera de ${Raiz}: $o -> $d"; continue }
  if (-not (Test-Path -LiteralPath $o)) { $errores += "No existe el origen: $o"; continue }
  if ([IO.Path]::GetFileName($d).IndexOfAny($invalidos) -ge 0) { $errores += "Nombre con caracteres invalidos: $d"; continue }
  $item = Get-Item -LiteralPath $o -Force
  $plan += [pscustomobject]@{
    Origen    = $o
    Destino   = $d
    EsCarpeta = $item.PSIsContainer
    Tamano    = $(if ($item.PSIsContainer) { 0 } else { $item.Length })
    Accion    = 'Mover'
  }
}

# Repetidos: mismo destino -> queda el mas grande, el resto a _obsoleto
foreach ($g in ($plan | Group-Object Destino | Where-Object Count -gt 1)) {
  foreach ($p in ($g.Group | Sort-Object Tamano -Descending | Select-Object -Skip 1)) {
    $p.Accion = 'Repetido'
  }
}

foreach ($p in ($plan | Where-Object Accion -eq 'Mover')) {
  if (Test-Path -LiteralPath $p.Destino) { $errores += "El destino ya existe: $($p.Destino)" }
}

# --- Vista previa ---
Write-Host ''
Write-Host '=== Vista previa (todavia no se movio nada) ===' -ForegroundColor Cyan
foreach ($p in $plan) {
  $tam = $(if ($p.EsCarpeta) { 'carpeta' } else { '{0:N2} GB' -f ($p.Tamano / 1GB) })
  $color = $(if ($p.Accion -eq 'Mover') { 'White' } else { 'Yellow' })
  Write-Host ('[{0}] {1}  ({2})' -f $p.Accion, (Get-Relativa $p.Origen), $tam) -ForegroundColor $color
  if ($p.Accion -eq 'Mover') { Write-Host "    -> $(Get-Relativa $p.Destino)" -ForegroundColor Green }
  else { Write-Host '    -> _obsoleto\ (es el mas chico del repetido)' -ForegroundColor Yellow }
}
Write-Host ''

$extras = @($plan | Where-Object { -not $_.EsCarpeta } | ForEach-Object { Get-Acompanantes $_.Origen })
if ($extras.Count) {
  Write-Host 'Ademas van a _obsoleto (Jellyfin los regenera):'
  $extras | ForEach-Object { Write-Host "  $(Get-Relativa $_)" }
  Write-Host ''
}

if ($errores.Count) {
  Write-Host 'No se puede ejecutar. Corregi renombrar.csv:' -ForegroundColor Red
  $errores | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  return
}
if ($SoloMostrar) { return }

if (-not $SinPreguntar) {
  $r = Read-Host 'Escribi SI para ejecutar (cualquier otra cosa cancela)'
  # "SI", "si", "SI" con tilde... (sin tildes para comparar)
  if (("$r".Trim().Normalize('FormD') -replace '\p{Mn}', '').ToUpper() -ne 'SI') { Write-Host 'Cancelado. No se movio nada.'; return }
}

# --- Ejecutar ---
Write-Host ''
Write-Host '=== Moviendo ===' -ForegroundColor Cyan
$ok = $false
try {
  foreach ($p in $plan) {
    if (-not $p.EsCarpeta) {
      foreach ($a in (Get-Acompanantes $p.Origen)) {
        Move-Seguro $a (Get-RutaLibre $obsoleto ([IO.Path]::GetFileName($a)))
      }
    }
    if ($p.Accion -eq 'Mover') { Move-Seguro $p.Origen $p.Destino }
    else { Move-Seguro $p.Origen (Get-RutaLibre $obsoleto ([IO.Path]::GetFileName($p.Origen))) }
  }
  $ok = $true
}
catch {
  Write-Host ''
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'Se freno ahi. Lo que ya se movio quedo anotado en rename-log.csv.' -ForegroundColor Red
}
finally {
  if ($registro.Count) { $registro | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8 -Append }
}

if ($ok) {
  # Archivar el csv usado para que un doble click accidental no lo vuelva a correr
  $hecho = 'renombrar.hecho-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date)
  Rename-Item -LiteralPath $Csv -NewName $hecho
  'Origen,Destino' | Out-File -LiteralPath $Csv -Encoding utf8
  Write-Host ''
  Write-Host "Listo: $($registro.Count) movimientos anotados en rename-log.csv." -ForegroundColor Green
  Write-Host "El csv usado quedo como $hecho y renombrar.csv quedo vacio."
  Write-Host 'Ahora en Jellyfin: Dashboard -> Libraries -> Scan All Libraries.' -ForegroundColor Yellow
}
