<#
  Borrar-Candidatos.ps1 - Borra lo marcado con SI en la columna Borrar de candidatos-borrar.csv.
  Lo genera Reporte-Espacio.ps1. Muestra una vista previa y pide SI antes de borrar.

  Pelicula: Radarr la quita de la biblioteca y borra el archivo.
  Temporada: Sonarr borra sus episodios y deja de monitorearla (no la vuelve a bajar).
  En los dos casos tambien se borra el torrent y su copia en Descargas (hardlink), si no
  el espacio no se libera. Cada borrado queda anotado en borrados-log.csv.

  -Confirmado  No pregunta (lo usa el panel, que ya pidio confirmacion en pantalla).
#>
param([string]$Raiz, [switch]$Confirmado)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Config-Media.ps1'); $cfg = Get-ConfigMedia
if (-not $Raiz) { $Raiz = $cfg.Raiz }
$P = $cfg.Puertos

function Get-ArrKey([string]$app) { ([xml](Get-Content -LiteralPath "C:\ProgramData\$app\config.xml" -Raw)).Config.ApiKey }
$api = @{
  radarr = @{ Url = "http://127.0.0.1:$($P.Radarr)/api/v3"; H = @{ 'X-Api-Key' = (Get-ArrKey 'Radarr') } }
  sonarr = @{ Url = "http://127.0.0.1:$($P.Sonarr)/api/v3"; H = @{ 'X-Api-Key' = (Get-ArrKey 'Sonarr') } }
}
function Api([string]$app, [string]$metodo, [string]$ruta, $cuerpo) {
  $p = @{ Uri = "$($api[$app].Url)/$ruta"; Method = $metodo; Headers = $api[$app].H; ContentType = 'application/json' }
  if ($null -ne $cuerpo) { $p.Body = [Text.Encoding]::UTF8.GetBytes(($cuerpo | ConvertTo-Json -Depth 20)) }
  Invoke-RestMethod @p | ForEach-Object { $_ }
}
function Test-Si([string]$r) { ("$r".Trim().Normalize('FormD') -replace '\p{Mn}', '').ToUpper() -eq 'SI' }

$csv = Join-Path $Raiz 'candidatos-borrar.csv'
if (-not (Test-Path -LiteralPath $csv)) { Write-Host 'No existe candidatos-borrar.csv: ejecuta primero Reporte-Espacio.bat' -ForegroundColor Yellow; return }
$marcados = @(Import-Csv -LiteralPath $csv -Encoding UTF8 | Where-Object { Test-Si $_.Borrar })
if (-not $marcados.Count) { Write-Host 'No hay filas con SI en la columna Borrar. Nada que hacer.' -ForegroundColor Yellow; return }

Write-Host ''
Write-Host '=== Se va a borrar (todavia no se borro nada) ===' -ForegroundColor Cyan
foreach ($m in $marcados) {
  $t = $(if ($m.Tipo -eq 'Serie') { '{0} - temporada {1}' -f $m.Titulo, $m.Temporada } else { $m.Titulo })
  Write-Host ('  {0,-9} {1}  ({2} GB)' -f $m.Tipo, $t, $m.GB)
}
# El CSV puede venir con coma decimal (si lo genero un proceso con configuracion regional en espanol)
Write-Host ('  Total: {0:N1} GB' -f (($marcados | ForEach-Object { [double]::Parse(("$($_.GB)" -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture) }) | Measure-Object -Sum).Sum)
Write-Host ''
if (-not $Confirmado -and -not (Test-Si (Read-Host 'Escribi SI para borrar (cualquier otra cosa cancela)'))) { Write-Host 'Cancelado. No se borro nada.'; return }

$log = Join-Path $Raiz 'borrados-log.csv'
foreach ($m in $marcados) {
  try {
    if ($m.App -eq 'radarr') {
      $hashes = @((Api radarr GET "history/movie?movieId=$($m.Id)&eventType=1") | Where-Object { $_.downloadId } | ForEach-Object { $_.downloadId.ToLower() } | Select-Object -Unique)
      Api radarr DELETE "movie/$($m.Id)?deleteFiles=true&addImportExclusion=false" | Out-Null
    }
    else {
      $temp = [int]$m.Temporada
      $archivos = @(Api sonarr GET "episodefile?seriesId=$($m.Id)") | Where-Object { $_.seasonNumber -eq $temp }
      $hashes = @((Api sonarr GET "history/series?seriesId=$($m.Id)&seasonNumber=$temp&eventType=1") | Where-Object { $_.downloadId } | ForEach-Object { $_.downloadId.ToLower() } | Select-Object -Unique)
      if ($archivos) { Api sonarr DELETE 'episodefile/bulk' @{ episodeFileIds = @($archivos.id) } | Out-Null }
      $serie = Api sonarr GET "series/$($m.Id)"
      foreach ($s in $serie.seasons) { if ($s.seasonNumber -eq $temp) { $s.monitored = $false } }
      Api sonarr PUT "series/$($m.Id)" $serie | Out-Null
    }
    foreach ($h in $hashes) {
      Invoke-RestMethod -Uri "http://127.0.0.1:$($P.qBittorrent)/api/v2/torrents/delete" -Method Post -Body @{ hashes = $h; deleteFiles = 'true' } | Out-Null
    }
    [pscustomobject]@{ Fecha = (Get-Date).ToString('s'); Tipo = $m.Tipo; Titulo = $m.Titulo; Temporada = $m.Temporada; GB = $m.GB; Torrents = $hashes.Count } |
      Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8 -Append
    Write-Host "  Borrado: $($m.Titulo) $(if ($m.Temporada) { "T$($m.Temporada)" }) ($($hashes.Count) torrent/s)" -ForegroundColor Green
  }
  catch { Write-Host "  ERROR con $($m.Titulo): $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host ''
Write-Host 'Listo. Se regenera el reporte...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Reporte-Espacio.ps1') -Raiz $Raiz
