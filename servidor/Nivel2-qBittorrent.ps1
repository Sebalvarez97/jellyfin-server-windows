<#
  Nivel2-qBittorrent.ps1 - Corre qBittorrent con un usuario de Windows propio ("media" por defecto,
  ver config.local.json) que solo puede escribir en la carpeta del servidor y en su configuracion.
  Hay que ejecutarlo como administrador: Nivel2-qBittorrent.bat lo pide solo.

  Que hace:
   1. Crea el usuario local estandar "media" (la contrasena la elegis vos al ejecutarlo;
      no se guarda en ningun archivo) y lo oculta de la pantalla de inicio de sesion.
   2. Le da permiso de Modificar sobre la carpeta del servidor y C:\ProgramData\qBittorrent-<usuario>.
   3. Cierra el qBittorrent de tu usuario.
   4. Copia tu configuracion de qBittorrent (rutas, categorias, Web UI, archivos excluidos)
      a C:\ProgramData\qBittorrent-media y deja la tuya como qBittorrent.anterior-nivel2.
   5. Crea la tarea programada "qBittorrent (media)": lo arranca al iniciar Windows, sin ventana.
   6. Lo arranca y verifica que responda en http://127.0.0.1:8080.
  Se puede volver a ejecutar: lo que ya esta hecho lo saltea.
#>
param(
  [string]$Usuario,
  [string]$Perfil,
  [string]$Biblioteca,
  [string]$Exe = 'C:\Program Files\qBittorrent\qbittorrent.exe'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Config-Media.ps1'); $cfg = Get-ConfigMedia
if (-not $Usuario) { $Usuario = $cfg.UsuarioDescargas }
if (-not $Biblioteca) { $Biblioteca = $cfg.Raiz }
if (-not $Perfil) { $Perfil = "C:\ProgramData\qBittorrent-$Usuario" }
$tarea = "qBittorrent ($Usuario)"
$origen = Join-Path $env:APPDATA 'qBittorrent'
$config = Join-Path $Perfil 'qBittorrent\config'
$api = "http://127.0.0.1:$($cfg.Puertos.qBittorrent)/api/v2"

function Paso([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }

function Get-Plano([Security.SecureString]$s) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# "SI", "si", "SI" con tilde... (sin tildes para comparar)
function Test-Si([string]$r) { ($r.Trim().Normalize('FormD') -replace '\p{Mn}', '').ToUpper() -eq 'SI' }

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Hay que ejecutarlo como administrador (usa Nivel2-qBittorrent.bat).'
}
if (-not (Test-Path -LiteralPath $Exe)) { throw "No encontre qBittorrent en $Exe" }

Write-Host "Esto va a crear el usuario '$Usuario', darle permisos sobre $Biblioteca y $Perfil,"
Write-Host 'cerrar tu qBittorrent y dejarlo corriendo con ese usuario al iniciar Windows.'
if (-not (Test-Si (Read-Host 'Escribi SI para continuar'))) { Write-Host 'Cancelado. No se cambio nada.'; return }

# --- 1. Usuario ---
Paso "1. Usuario '$Usuario'"
if (Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue) {
  Write-Host 'El usuario ya existe. Escribi su contrasena actual (la necesita la tarea programada).'
  $pw = Read-Host "Contrasena de $Usuario" -AsSecureString
}
else {
  $pw = Read-Host "Elegi una contrasena para $Usuario (no se muestra)" -AsSecureString
  $pw2 = Read-Host 'Repetila' -AsSecureString
  if ((Get-Plano $pw) -cne (Get-Plano $pw2)) { throw 'Las contrasenas no coinciden. No se cambio nada.' }
  New-LocalUser -Name $Usuario -Password $pw -FullName 'qBittorrent' -Description 'Usuario restringido para qBittorrent' -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
  Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $Usuario   # grupo Usuarios (estandar, no administrador)
  Write-Host "Creado '$Usuario' como usuario estandar."
}
$ocultos = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
New-Item -Path $ocultos -Force | Out-Null
New-ItemProperty -Path $ocultos -Name $Usuario -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host 'Oculto de la pantalla de inicio de sesion.'

# La tarea corre sin sesion iniciada: la cuenta necesita "Iniciar sesion como proceso por lotes"
$sid = (Get-LocalUser -Name $Usuario).SID.Value
$tmp = Join-Path $env:TEMP 'qbittorrent-media-sec'
secedit /export /cfg "$tmp.inf" /areas USER_RIGHTS | Out-Null
$linea = (Select-String -LiteralPath "$tmp.inf" -Pattern '^SeBatchLogonRight\s*=' | Select-Object -First 1).Line
if ("$linea" -notmatch [regex]::Escape("*$sid")) {
  $nueva = $(if ($linea) { "$linea,*$sid" } else { "SeBatchLogonRight = *$sid" })
  @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]', $nueva) |
    Set-Content -LiteralPath "$tmp-nuevo.inf" -Encoding Unicode
  secedit /configure /db "$tmp.sdb" /cfg "$tmp-nuevo.inf" /areas USER_RIGHTS | Out-Null
  if ($LASTEXITCODE) { throw 'secedit no pudo otorgar "Iniciar sesion como proceso por lotes".' }
  Write-Host 'Otorgado "Iniciar sesion como proceso por lotes" (necesario para la tarea programada).'
}
else { Write-Host 'Ya tenia "Iniciar sesion como proceso por lotes".' }
Remove-Item -Path "$tmp*" -Force -ErrorAction SilentlyContinue

# --- 2. Permisos ---
Paso '2. Permisos'
New-Item -ItemType Directory -Force -Path $config | Out-Null
# Solo las carpetas de datos: la raiz tiene los scripts que el mantenimiento ejecuta como SYSTEM
$datos = @($cfg.RutaPeliculas, $cfg.RutaSeries, $cfg.RutaDescargas, (Join-Path $Biblioteca '_obsoleto')) | Where-Object { Test-Path -LiteralPath $_ }
foreach ($dir in @($datos) + $Perfil) {
  icacls $dir /grant "${Usuario}:(OI)(CI)M" | Out-Null
  if ($LASTEXITCODE) { throw "icacls fallo sobre $dir" }
  Write-Host "  $Usuario puede modificar $dir"
}

# --- 3. Cerrar qBittorrent ---
Paso '3. Cerrar qBittorrent'
$procs = @(Get-Process qbittorrent -ErrorAction SilentlyContinue)
foreach ($p in $procs) { [void]$p.CloseMainWindow() }
foreach ($p in $procs) { if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force } }
# Esperar a que no quede ningun qbittorrent vivo (al salir reescribe su configuracion)
for ($i = 0; $i -lt 30 -and (Get-Process qbittorrent -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
Write-Host $(if ($procs.Count) { "  Cerrado ($($procs.Count) proceso/s)." } else { '  No estaba abierto.' })

# --- 4. Copiar configuracion ---
Paso '4. Configuracion'
# Si qBittorrent se abrio desde una app empaquetada (ej. la app de Claude), Windows
# redirige su AppData a %LOCALAPPDATA%\Packages\<app>\LocalCache\Roaming
if (-not (Test-Path -LiteralPath (Join-Path $origen 'qBittorrent.ini'))) {
  $virtual = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\qBittorrent' } |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'qBittorrent.ini') } | Select-Object -First 1
  if ($virtual) { $origen = $virtual; Write-Host "  Configuracion encontrada en carpeta virtualizada: $origen" }
}
# Al guardar, qBittorrent borra qBittorrent.ini y lo reemplaza: puede faltar unos instantes
$ini = Join-Path $origen 'qBittorrent.ini'
for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $origen) -and -not (Test-Path -LiteralPath $ini); $i++) { Start-Sleep -Seconds 1 }
if (Test-Path -LiteralPath $ini) {
  foreach ($f in 'qBittorrent.ini', 'qBittorrent-data.ini', 'categories.json', 'watched_folders.json', 'rss') {
    $src = Join-Path $origen $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $config -Recurse -Force }
  }
  $viejo = 'qBittorrent.anterior-nivel2'
  $padre = Split-Path -Parent $origen
  if (Test-Path -LiteralPath (Join-Path $padre $viejo)) { $viejo += '-{0:yyyyMMdd-HHmmss}' -f (Get-Date) }
  Rename-Item -LiteralPath $origen -NewName $viejo
  Write-Host "  Copiada a $config"
  Write-Host "  La anterior quedo como $padre\$viejo"
}
elseif (Test-Path -LiteralPath (Join-Path $config 'qBittorrent.ini')) { Write-Host '  Ya estaba migrada.' }
else { throw "No encontre configuracion de qBittorrent en $origen ni en $config" }

# --- 5. Tarea programada ---
Paso "5. Tarea programada '$tarea'"
$accion = New-ScheduledTaskAction -Execute $Exe -Argument "--profile=$Perfil"
$disparador = New-ScheduledTaskTrigger -AtStartup
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $tarea -Action $accion -Trigger $disparador -Settings $ajustes `
  -User "$env:COMPUTERNAME\$Usuario" -Password (Get-Plano $pw) -RunLevel Limited `
  -Description "qBittorrent como '$Usuario' (solo escribe en $Biblioteca). Web UI: http://127.0.0.1:8080" -Force | Out-Null
Write-Host '  Arranca al iniciar Windows, aunque no hayas iniciado sesion.'

# --- 6. Arrancar y verificar ---
Paso '6. Arrancar y verificar'
Start-ScheduledTask -TaskName $tarea
$version = $null
for ($i = 0; $i -lt 30 -and -not $version; $i++) {
  Start-Sleep -Seconds 2
  try { $version = Invoke-RestMethod "$api/app/version" -TimeoutSec 3 } catch { }
}
if (-not $version) {
  $info = Get-ScheduledTaskInfo -TaskName $tarea
  throw ("qBittorrent no respondio en 127.0.0.1:8080. Resultado de la tarea: 0x{0:X8} (ultima ejecucion {1}). Log: $Perfil\qBittorrent\data\logs" -f $info.LastTaskResult, $info.LastRunTime)
}

$proc = Get-CimInstance Win32_Process -Filter "Name='qbittorrent.exe'" | Select-Object -First 1
$duenio = (Invoke-CimMethod -InputObject $proc -MethodName GetOwner).User
$prefs = Invoke-RestMethod "$api/app/preferences"
$cats = (Invoke-RestMethod "$api/torrents/categories").PSObject.Properties.Name -join ', '

Write-Host "  qBittorrent $version corriendo como: $duenio"
Write-Host "  Ruta por defecto: $($prefs.save_path)"
Write-Host "  Categorias: $cats"
Write-Host "  Archivos excluidos: $($prefs.excluded_file_names_enabled)"
Write-Host "  Web UI: $($prefs.web_ui_address):$($prefs.web_ui_port)"
Write-Host ''
if ($duenio -eq $Usuario) { Write-Host 'Listo. Desde ahora usa qBittorrent desde http://127.0.0.1:8080 (no lo abras desde el menu Inicio).' -ForegroundColor Green }
else { Write-Host "Ojo: qBittorrent esta corriendo como '$duenio', no como '$Usuario'." -ForegroundColor Yellow }
