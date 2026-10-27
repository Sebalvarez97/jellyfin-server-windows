<#
  Config-Media.ps1 - Lee la configuracion de esta instalacion (config.local.json, junto a este archivo).
  La genera el instalador con las respuestas del usuario y NO se sube al repositorio.
  Los scripts la cargan asi:   . (Join-Path $PSScriptRoot 'Config-Media.ps1'); $cfg = Get-ConfigMedia
  Si falta un valor, se usa el de $Predeterminado.
#>

$Predeterminado = [ordered]@{
  Raiz             = $PSScriptRoot                       # carpeta del servidor (biblioteca + scripts)
  Peliculas        = 'Movies'                            # subcarpetas, relativas a Raiz
  Series           = 'Shows'
  Descargas        = 'Descargas'
  IpServidor       = ''                                  # IP fija de la PC en la red de la casa
  RedLocal         = ''                                  # por ejemplo 192.168.1.0/24
  ZonaHoraria      = 'America/Argentina/Buenos_Aires'
  UsuarioDescargas = 'media'                             # usuario restringido que corre qBittorrent
  CuentaJellyfin   = 'NT AUTHORITY\NetworkService'       # con que cuenta quedo el servicio de Jellyfin
  Puertos          = [ordered]@{ Jellyfin = 8096; Seerr = 5055; Radarr = 7878; Sonarr = 8989; Prowlarr = 9696; Bazarr = 6767; qBittorrent = 8080 }
  Seerr            = [ordered]@{ Imagen = 'ghcr.io/seerr-team/seerr:latest'; Contenedor = 'seerr'; Volumen = 'seerr-config' }
  Zrok             = [ordered]@{ Habilitado = $false; Exe = ''; Entorno = ''; NombreJellyfin = ''; NombreSeerr = '' }
  Reporte          = [ordered]@{ DiasVisto = 60; UmbralPct = 80 }
}

function Merge-Config($base, $valores) {
  $r = [ordered]@{}
  foreach ($k in $base.Keys) {
    $v = $null
    if ($valores -and $valores.PSObject.Properties.Name -contains $k) { $v = $valores.$k }
    if ($base[$k] -is [System.Collections.IDictionary]) { $r[$k] = Merge-Config $base[$k] $v }
    elseif ($null -ne $v -and "$v" -ne '') { $r[$k] = $v }
    else { $r[$k] = $base[$k] }
  }
  $r
}

function Get-ConfigMedia([string]$Archivo = (Join-Path $PSScriptRoot 'config.local.json')) {
  $valores = $null
  if (Test-Path -LiteralPath $Archivo) { $valores = Get-Content -LiteralPath $Archivo -Raw -Encoding UTF8 | ConvertFrom-Json }
  $c = Merge-Config $Predeterminado $valores
  $c['RutaPeliculas'] = Join-Path $c.Raiz $c.Peliculas
  $c['RutaSeries'] = Join-Path $c.Raiz $c.Series
  $c['RutaDescargas'] = Join-Path $c.Raiz $c.Descargas
  [pscustomobject]$c
}

# true si la IP pertenece a la red "a.b.c.d/nn"
function Test-EnRed([string]$Ip, [string]$Red) {
  if (-not $Red -or $Red -notmatch '^(.+)/(\d+)$') { return $false }
  $bits = [int]$Matches[2]
  try {
    $a = [Net.IPAddress]::Parse($Ip).GetAddressBytes(); $b = [Net.IPAddress]::Parse($Matches[1]).GetAddressBytes()
  } catch { return $false }
  if ($a.Length -ne $b.Length) { return $false }
  for ($i = 0; $i -lt $a.Length; $i++) {
    $n = [Math]::Max(0, [Math]::Min(8, $bits - 8 * $i))
    $mask = [byte](0xFF -shl (8 - $n) -band 0xFF)
    if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { return $false }
  }
  $true
}
