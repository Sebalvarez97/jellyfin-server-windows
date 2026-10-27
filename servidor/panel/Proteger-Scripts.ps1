<#
  Proteger-Scripts.ps1 - Que qBittorrent (usuario de descargas) y los servicios (LocalService) no
  puedan modificar los scripts de <Raiz>. Hay que ejecutarlo como administrador:
  <Raiz>\Proteger-Scripts.bat lo pide solo. Raiz, carpetas y usuario salen de config.local.json.

  Antes: el usuario de descargas y LocalService tenian Modificar sobre TODA la raiz, scripts incluidos,
         y las tareas "Media - Arranque" y "Media - Mantenimiento" ejecutan esos scripts como SYSTEM.
         Ademas cualquier usuario podia crear archivos en la raiz (por ejemplo un powershell.exe falso
         que los .bat ejecutarian antes que el de Windows).
  Despues:
    <Raiz> (la raiz y sus archivos)          escriben solo tu usuario, Administradores y SYSTEM; el resto lee
    Peliculas, Series, Descargas, _obsoleto  descargas y LocalService siguen con Modificar, igual que antes
    panel, secretos                          no cambian (ya tienen permisos propios)

  Antes de tocar nada guarda los permisos de toda la raiz en C:\ProgramData\MediaStack\permisos-<fecha>.txt
  -Deshacer  restaura el respaldo mas reciente (Proteger-Scripts.bat deshacer)
#>
param(
  [switch]$Deshacer,
  [string]$Raiz
)
# Configuracion de la instalacion (este script vive en <Raiz>\panel)
$raizPanel = Split-Path -Parent $PSScriptRoot
$cfg = $null
if (Test-Path -LiteralPath (Join-Path $raizPanel 'Config-Media.ps1')) {
  . (Join-Path $raizPanel 'Config-Media.ps1')
  $cfg = Get-ConfigMedia (Join-Path $raizPanel 'config.local.json')
}
if (-not $Raiz) { $Raiz = $(if ($cfg) { $cfg.Raiz } else { $raizPanel }) }
$usuarioDescargas = $(if ($cfg) { [string]$cfg.UsuarioDescargas } else { 'media' })
$carpetasDatos = $(if ($cfg) { @($cfg.RutaPeliculas, $cfg.RutaSeries, $cfg.RutaDescargas) } else { @('Movies', 'Shows', 'Descargas') | ForEach-Object { Join-Path $Raiz $_ } })
$carpetasDatos += (Join-Path $Raiz '_obsoleto')
$ErrorActionPreference = 'Stop'
$base = 'C:\ProgramData\MediaStack'
New-Item -ItemType Directory -Force -Path (Join-Path $base 'logs') | Out-Null
Start-Transcript -LiteralPath (Join-Path $base ('logs\proteger-{0:yyyyMMdd-HHmm}.log' -f (Get-Date))) | Out-Null

function Paso([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Sid([string]$cuenta) { (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value }

try {
  $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Hay que ejecutarlo como administrador (usa Proteger-Scripts.bat).'
  }

  if ($Deshacer) {
    $bk = Get-ChildItem -LiteralPath $base -Filter 'permisos-*.txt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bk) { throw "No hay respaldo de permisos en $base" }
    Paso "Restaurando los permisos de $($bk.Name)"
    # El respaldo guarda los nombres relativos a la carpeta de arriba de la raiz
    & icacls.exe (Split-Path -Parent $Raiz) /restore $bk.FullName /c /q
    if ($LASTEXITCODE -ne 0) { throw "icacls /restore devolvio $LASTEXITCODE" }
    Write-Host 'Listo: los permisos quedaron como antes.' -ForegroundColor Green
    return
  }

  $sidMedia = Sid $usuarioDescargas
  $sidLocal = 'S-1-5-19'      # LocalService (el nombre cambia con el idioma de Windows)
  $sidUsuarios = 'S-1-5-32-545'
  # Tu usuario: el que tiene la sesion abierta en la PC (si UAC pidio otra cuenta, $env:USERNAME seria esa)
  $sesion = (Get-CimInstance Win32_ComputerSystem).UserName
  $sidDueno = Sid $(if ($sesion) { $sesion } else { "$env:USERDOMAIN\$env:USERNAME" })
  if ($sidDueno -in $sidMedia, $sidLocal) { throw 'No se pudo identificar tu usuario (dio el usuario de descargas o LocalService)' }
  Write-Host ("Tu usuario: {0}" -f (New-Object Security.Principal.SecurityIdentifier($sidDueno)).Translate([Security.Principal.NTAccount]).Value)

  Paso 'Respaldo de los permisos actuales'
  $bk = Join-Path $base ('permisos-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
  & icacls.exe $Raiz /save $bk /t /c /q
  if ($LASTEXITCODE -ne 0) { throw "icacls /save devolvio $($LASTEXITCODE): no se cambio nada" }
  Write-Host "Guardado en $bk"

  # 1) Primero las carpetas de datos reciben su propio permiso, asi los servicios nunca se quedan sin acceso
  Paso "Carpetas de datos: $usuarioDescargas y LocalService conservan Modificar"
  foreach ($p in $carpetasDatos) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    & icacls.exe $p /grant "*$($sidMedia):(OI)(CI)M" "*$($sidLocal):(OI)(CI)M" /c /q
    if ($LASTEXITCODE -ne 0) { throw "icacls /grant en $p devolvio $LASTEXITCODE" }
    Write-Host "  $p"
  }

  # 2) La raiz deja de heredar de la carpeta de arriba (se copia lo heredado) y se le sacan los permisos de escritura ajenos
  Paso "Raiz $Raiz`: solo tu usuario, Administradores y SYSTEM escriben"
  $carpeta = Get-Item -LiteralPath $Raiz
  $acl = $carpeta.GetAccessControl('Access')
  $acl.SetAccessRuleProtection($true, $true)
  $carpeta.SetAccessControl($acl)

  $acl = $carpeta.GetAccessControl('Access')
  $crear = [Security.AccessControl.FileSystemRights]'CreateFiles, AppendData'
  foreach ($r in @($acl.Access)) {
    $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -in $sidMedia, $sidLocal) { [void]$acl.RemoveAccessRuleSpecific($r) }
    elseif ($sid -eq $sidUsuarios -and ($r.FileSystemRights -band $crear) -and $r.PropagationFlags -ne 'InheritOnly') {
      # Usuarios podia crear archivos y carpetas en la raiz: se mantiene solo para las subcarpetas (Jellyfin crea miniaturas)
      [void]$acl.RemoveAccessRuleSpecific($r)
      $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($r.IdentityReference, $r.FileSystemRights, 'ContainerInherit', 'InheritOnly', 'Allow')))
    }
  }
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sidDueno)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
  $carpeta.SetAccessControl($acl)

  # 3) Verificacion
  Paso 'Verificacion'
  $escritura = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete, ChangePermissions, TakeOwnership'
  function Get-Escritores([string]$ruta, [switch]$SoloEsteObjeto) {
    @((Get-Acl -LiteralPath $ruta).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band $escritura) -and -not ($SoloEsteObjeto -and $_.PropagationFlags -eq 'InheritOnly')
      } | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } |
      Where-Object { $_ -in $sidMedia, $sidLocal, $sidUsuarios } | Select-Object -Unique)
  }
  $mal = @()
  if (Get-Escritores $Raiz -SoloEsteObjeto) { $mal += $Raiz }
  foreach ($f in Get-ChildItem -LiteralPath $Raiz -File -Force) { if (Get-Escritores $f.FullName) { $mal += $f.FullName } }
  foreach ($p in $carpetasDatos | Select-Object -SkipLast 1) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $w = Get-Escritores $p
    if ($w -notcontains $sidMedia -or $w -notcontains $sidLocal) { Write-Host "  OJO: $p quedo sin Modificar para $usuarioDescargas o LocalService" -ForegroundColor Red; $mal += $p }
    else { Write-Host "  $p`: $usuarioDescargas y LocalService pueden escribir (bien)" }
  }
  if ($mal) {
    Write-Host ''
    Write-Host 'Algo no quedo como se esperaba:' -ForegroundColor Red
    $mal | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host 'Para volver atras: Proteger-Scripts.bat deshacer' -ForegroundColor Yellow
  }
  else {
    Write-Host "  Raiz y scripts: $usuarioDescargas, LocalService y Usuarios solo pueden leer (bien)"
    Write-Host ''
    Write-Host 'Listo. Abri el panel y toca "Volver a revisar" en Diagnostico.' -ForegroundColor Green
    Write-Host 'Si Radarr, Sonarr o qBittorrent muestran errores de permisos: Proteger-Scripts.bat deshacer'
  }
}
catch {
  Write-Host ''
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'Si el error fue despues del respaldo: Proteger-Scripts.bat deshacer' -ForegroundColor Yellow
}
finally { Stop-Transcript | Out-Null }
