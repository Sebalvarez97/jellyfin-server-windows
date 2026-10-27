<#
  Reporte-Espacio.ps1 - Arma <Raiz>\Reporte-espacio.html y candidatos-borrar.csv.
  No borra nada. Lo corre el mantenimiento semanal y se puede ejecutar a mano (Reporte-Espacio.bat).

  Candidato a borrar = lo visto completo hace mas de $DiasVisto dias y que nadie tiene a medias.
  Se sugiere borrar solo cuando el disco pasa el $UmbralPct % de uso.
  Para saber que se vio hace falta una API key de Jellyfin en <Raiz>\secretos\jellyfin-api.txt
  (Jellyfin > Panel de control > Claves de API > +). Sin ella el reporte muestra solo el espacio.

  Para borrar: en candidatos-borrar.csv poner SI en la columna Borrar y ejecutar Borrar-Candidatos.bat.
  Los valores por defecto salen de config.local.json (ver Config-Media.ps1).
#>
param(
  [string]$Raiz,
  [int]$DiasVisto,
  [int]$UmbralPct
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Config-Media.ps1'); $cfg = Get-ConfigMedia
if (-not $Raiz) { $Raiz = $cfg.Raiz }
if (-not $DiasVisto) { $DiasVisto = $cfg.Reporte.DiasVisto }
if (-not $UmbralPct) { $UmbralPct = $cfg.Reporte.UmbralPct }
$P = $cfg.Puertos

function Get-ArrKey([string]$app) { ([xml](Get-Content -LiteralPath "C:\ProgramData\$app\config.xml" -Raw)).Config.ApiKey }
function Invoke-Api([string]$url, [hashtable]$headers) { Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60 | ForEach-Object { $_ } }
function Html([string]$t) { [Net.WebUtility]::HtmlEncode($t) }
function GB([double]$b) { '{0:N1} GB' -f ($b / 1GB) }

$radarr = @{ Url = "http://127.0.0.1:$($P.Radarr)/api/v3"; H = @{ 'X-Api-Key' = (Get-ArrKey 'Radarr') } }
$sonarr = @{ Url = "http://127.0.0.1:$($P.Sonarr)/api/v3"; H = @{ 'X-Api-Key' = (Get-ArrKey 'Sonarr') } }
$jellyfinUrl = "http://127.0.0.1:$($P.Jellyfin)"

# --- Que se vio (Jellyfin) ---
$jfKeyFile = Join-Path $Raiz 'secretos\jellyfin-api.txt'
$vistos = @{}   # ruta del archivo (minusculas) -> @{ Usuarios = @(); Ultimo = fecha; AMedias = bool }
$hayJellyfin = $false
if (Test-Path -LiteralPath $jfKeyFile) {
  # Jellyfin 12 ya no acepta X-Emby-Token: va en el encabezado Authorization
  $jfH = @{ Authorization = ('MediaBrowser Token="{0}"' -f (Get-Content -LiteralPath $jfKeyFile -Raw).Trim()) }
  try {
    foreach ($u in @(Invoke-Api "$jellyfinUrl/Users" $jfH)) {
      $items = (Invoke-RestMethod -Uri "$jellyfinUrl/Users/$($u.Id)/Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=Path&EnableUserData=true" -Headers $jfH -TimeoutSec 120).Items
      foreach ($i in $items) {
        if (-not $i.Path) { continue }
        $k = $i.Path.ToLower()
        if (-not $vistos.ContainsKey($k)) { $vistos[$k] = @{ Usuarios = @(); Ultimo = $null; AMedias = $false } }
        $d = $i.UserData
        if ($d.Played) {
          $vistos[$k].Usuarios += $u.Name
          if ($d.LastPlayedDate -and (-not $vistos[$k].Ultimo -or [datetime]$d.LastPlayedDate -gt $vistos[$k].Ultimo)) { $vistos[$k].Ultimo = [datetime]$d.LastPlayedDate }
        }
        elseif ($d.PlaybackPositionTicks -gt 0) { $vistos[$k].AMedias = $true }
      }
    }
    $hayJellyfin = $true
  }
  catch { Write-Warning "No se pudo leer Jellyfin: $($_.Exception.Message)" }
}

# Hash del torrent con que se bajo cada cosa (para borrar tambien la copia de Descargas)
function Get-Hashes($api, [string]$filtro) {
  @(Invoke-Api "$($api.Url)/history?pageSize=500&eventType=1&$filtro" $api.H | ForEach-Object { $_.records } |
    Where-Object { $_.downloadId } | ForEach-Object { $_.downloadId.ToLower() } | Select-Object -Unique)
}

$filas = New-Object System.Collections.Generic.List[object]
$hoy = Get-Date

# --- Peliculas ---
foreach ($m in @(Invoke-Api "$($radarr.Url)/movie" $radarr.H | Where-Object { $_.hasFile })) {
  $f = $m.movieFile
  $v = $vistos[$f.path.ToLower()]
  $filas.Add([pscustomobject]@{
    Tipo = 'Pelicula'; Titulo = "$($m.title) ($($m.year))"; Temporada = ''; Bytes = [double]$f.size
    Agregado = ([datetime]$f.dateAdded).ToString('yyyy-MM-dd')
    VistoPor = $(if ($v) { ($v.Usuarios | Select-Object -Unique) -join ', ' } else { '' })
    UltimoVisto = $(if ($v -and $v.Ultimo) { $v.Ultimo.ToString('yyyy-MM-dd') } else { '' })
    AMedias = [bool]($v -and $v.AMedias)
    App = 'radarr'; Id = $m.id
  })
}

# --- Series, por temporada ---
foreach ($s in @(Invoke-Api "$($sonarr.Url)/series" $sonarr.H)) {
  $archivos = @(Invoke-Api "$($sonarr.Url)/episodefile?seriesId=$($s.id)" $sonarr.H)
  foreach ($g in ($archivos | Group-Object seasonNumber)) {
    $vs = @($g.Group | ForEach-Object { $vistos[$_.path.ToLower()] })
    $todosVistos = $hayJellyfin -and $vs.Count -eq $g.Count -and -not ($vs | Where-Object { -not $_ -or -not $_.Usuarios.Count })
    $ultimo = ($vs | Where-Object { $_ -and $_.Ultimo } | ForEach-Object { $_.Ultimo } | Sort-Object | Select-Object -Last 1)
    $filas.Add([pscustomobject]@{
      Tipo = 'Serie'; Titulo = $s.title; Temporada = [int]$g.Name; Bytes = [double](($g.Group | Measure-Object size -Sum).Sum)
      Agregado = (($g.Group | ForEach-Object { [datetime]$_.dateAdded } | Sort-Object | Select-Object -Last 1)).ToString('yyyy-MM-dd')
      VistoPor = $(if ($todosVistos) { (($vs | ForEach-Object { $_.Usuarios }) | Select-Object -Unique) -join ', ' }
        elseif (@($vs | Where-Object { $_ -and $_.Usuarios.Count }).Count) { '{0} de {1} episodios' -f @($vs | Where-Object { $_ -and $_.Usuarios.Count }).Count, $g.Count }
        else { '' })
      UltimoVisto = $(if ($todosVistos -and $ultimo) { $ultimo.ToString('yyyy-MM-dd') } else { '' })
      AMedias = [bool]($vs | Where-Object { $_ -and $_.AMedias })
      App = 'sonarr'; Id = $s.id
    })
  }
}

foreach ($r in $filas) {
  $r | Add-Member -NotePropertyName Candidato -NotePropertyValue ([bool]($r.UltimoVisto -and -not $r.AMedias -and ($hoy - [datetime]$r.UltimoVisto).TotalDays -gt $DiasVisto))
}

# --- Disco ---
$vol = Get-Volume -DriveLetter ($Raiz.Substring(0, 1))
$usado = $vol.Size - $vol.SizeRemaining
$pct = [math]::Round(100 * $usado / $vol.Size)
$tamDir = { param($p) [double]((Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) }
$pelis = & $tamDir (Join-Path $Raiz $cfg.Peliculas); $series = & $tamDir (Join-Path $Raiz $cfg.Series); $desc = & $tamDir (Join-Path $Raiz $cfg.Descargas)
$candidatos = @($filas | Where-Object Candidato)
$liberable = ($candidatos | Measure-Object Bytes -Sum).Sum

# --- CSV para aprobar borrados ---
$csv = Join-Path $Raiz 'candidatos-borrar.csv'
$filas | Sort-Object @{ e = { -not $_.Candidato } }, @{ e = { $_.Bytes }; Descending = $true } |
  Select-Object @{ n = 'Borrar'; e = { '' } }, Tipo, Titulo, Temporada, @{ n = 'GB'; e = { ([math]::Round($_.Bytes / 1GB, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) } }, Agregado, VistoPor, UltimoVisto, Candidato, App, Id |
  Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

# --- HTML ---
$color = $(if ($pct -ge $UmbralPct) { '#c0392b' } elseif ($pct -ge $UmbralPct - 10) { '#d68910' } else { '#1e8449' })
$aviso = $(if ($pct -ge $UmbralPct) { "El disco pas&oacute; el $UmbralPct%: conviene borrar algunos candidatos." } else { "El disco est&aacute; por debajo del $UmbralPct%: no hace falta borrar nada." })
if (-not $hayJellyfin) { $aviso += ' <b>Sin API key de Jellyfin:</b> no se sabe qu&eacute; se vio, as&iacute; que no hay candidatos (ver secretos\jellyfin-api.txt).' }
$filasHtml = ($filas | Sort-Object @{ e = { -not $_.Candidato } }, @{ e = { $_.Bytes }; Descending = $true } | ForEach-Object {
  $t = Html $_.Titulo; if ($_.Tipo -eq 'Serie') { $t += ' &middot; T{0:00}' -f $_.Temporada }
  $estado = $(if ($_.Candidato) { '<span class="cand">Candidato</span>' } elseif ($_.AMedias) { 'Alguien la est&aacute; viendo' } elseif ($_.UltimoVisto) { 'Vista hace poco' } else { 'Sin ver' })
  "<tr><td>$($_.Tipo)</td><td>$t</td><td class='n'>$(GB $_.Bytes)</td><td>$($_.Agregado)</td><td>$(Html $_.VistoPor)</td><td>$($_.UltimoVisto)</td><td>$estado</td></tr>"
}) -join "`n"

$html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Espacio del servidor de medios</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222;background:#fafafa;max-width:1100px}
h1{font-size:22px;margin:0 0 4px} .sub{color:#666;margin-bottom:20px}
.bar{height:22px;background:#e5e5e5;border-radius:6px;overflow:hidden;position:relative}
.bar div{height:100%;background:$color} .bar span{position:absolute;left:8px;top:2px;font-size:13px;font-weight:600}
.umbral{position:absolute;top:0;bottom:0;left:$UmbralPct%;border-left:2px dashed #555}
.kpis{display:flex;gap:16px;flex-wrap:wrap;margin:16px 0} .kpi{background:#fff;border:1px solid #ddd;border-radius:8px;padding:10px 14px;min-width:150px}
.kpi b{display:block;font-size:20px} .aviso{margin:12px 0;padding:10px 14px;border-left:4px solid $color;background:#fff}
table{border-collapse:collapse;width:100%;background:#fff;font-size:14px} th,td{border-bottom:1px solid #eee;padding:6px 8px;text-align:left}
th{background:#f0f0f0} td.n{text-align:right;white-space:nowrap} .cand{background:#fdebd0;color:#7e5109;padding:2px 6px;border-radius:4px;font-weight:600}
code{background:#eee;padding:1px 4px;border-radius:3px}
</style></head><body>
<h1>Espacio del servidor de medios</h1>
<div class="sub">Generado el $($hoy.ToString('yyyy-MM-dd HH:mm')) &middot; candidatos: vistos hace m&aacute;s de $DiasVisto d&iacute;as y que nadie tiene a medias</div>
<div class="bar"><div style="width:$pct%"></div><i class="umbral"></i><span>$pct% usado &middot; $(GB $usado) de $(GB $vol.Size)</span></div>
<div class="aviso">$aviso</div>
<div class="kpis">
<div class="kpi">Pel&iacute;culas<b>$(GB $pelis)</b></div>
<div class="kpi">Series<b>$(GB $series)</b></div>
<div class="kpi">Descargas (compartiendo)<b>$(GB $desc)</b></div>
<div class="kpi">Libre<b>$(GB $vol.SizeRemaining)</b></div>
<div class="kpi">Candidatos<b>$($candidatos.Count) &middot; $(GB $liberable)</b></div>
</div>
<p>Lo que se baja por torrent aparece en <code>Descargas</code> y en la biblioteca, pero es el mismo archivo (hardlink): ocupa espacio una sola vez y se libera cuando se borran las dos copias. <code>Borrar-Candidatos.bat</code> borra las dos.</p>
<table><tr><th>Tipo</th><th>T&iacute;tulo</th><th>Tama&ntilde;o</th><th>Agregado</th><th>Visto por</th><th>&Uacute;ltima vez</th><th>Estado</th></tr>
$filasHtml
</table>
<p>Para borrar: abr&iacute; <code>candidatos-borrar.csv</code>, pon&eacute; <code>SI</code> en la columna <b>Borrar</b> de lo que quieras eliminar y ejecut&aacute; <code>Borrar-Candidatos.bat</code>. Muestra una vista previa y pide confirmaci&oacute;n.</p>
</body></html>
"@
Set-Content -LiteralPath (Join-Path $Raiz 'Reporte-espacio.html') -Value $html -Encoding UTF8
Write-Host ("Reporte: {0}  |  disco {1}% usado  |  {2} candidatos ({3})" -f (Join-Path $Raiz 'Reporte-espacio.html'), $pct, $candidatos.Count, (GB $liberable))
