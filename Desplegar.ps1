<#
  Desplegar.ps1 - Copia los scripts del repositorio (carpeta servidor\) a la carpeta del servidor.
  La usa el instalador y sirve para actualizar una instalacion existente despues de un "git pull".

  - Nunca pisa config.local.json, secretos\ ni lo que generan los scripts (logs, CSV, reportes).
  - Antes de reemplazar un archivo distinto, guarda el anterior en <Raiz>\_obsoleto\despliegue-<fecha>\.
  - -SoloMostrar: informa que cambiaria, sin copiar nada.
#>
param(
  [string]$Raiz,
  [switch]$SoloMostrar
)
$ErrorActionPreference = 'Stop'
$origen = Join-Path $PSScriptRoot 'servidor'

if (-not $Raiz) {
  $Raiz = Read-Host 'Carpeta del servidor (por ejemplo D:\JellyFin)'
}
$Raiz = $Raiz.Trim().TrimEnd('\')
if (-not (Test-Path -LiteralPath $Raiz)) { throw "No existe la carpeta $Raiz" }

$respaldo = Join-Path $Raiz ('_obsoleto\despliegue-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
$nuevos = 0; $cambiados = 0; $iguales = 0
foreach ($f in Get-ChildItem -LiteralPath $origen -Recurse -File) {
  $rel = $f.FullName.Substring($origen.Length + 1)
  if ($rel -match '(^|\\)(config\.local\.json|secretos\\|estado\\|logs\\)') { continue }
  $dest = Join-Path $Raiz $rel
  if (Test-Path -LiteralPath $dest) {
    if ((Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { $iguales++; continue }
    Write-Host "  cambia: $rel"
    $cambiados++
    if (-not $SoloMostrar) {
      $bk = Join-Path $respaldo $rel
      New-Item -ItemType Directory -Force -Path (Split-Path $bk) | Out-Null
      Copy-Item -LiteralPath $dest -Destination $bk -Force
    }
  }
  else { Write-Host "  nuevo:  $rel"; $nuevos++ }
  if (-not $SoloMostrar) {
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
  }
}
Write-Host ("{0}: {1} nuevos, {2} cambiados, {3} iguales{4}" -f $(if ($SoloMostrar) { 'Se copiaria' } else { 'Listo' }), $nuevos, $cambiados, $iguales,
  $(if ($cambiados -and -not $SoloMostrar) { " (anteriores en $respaldo)" } else { '' }))
