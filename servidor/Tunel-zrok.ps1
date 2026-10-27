<#
  Tunel-zrok.ps1 - Publica un servicio local por zrok y lo deja corriendo solo, desde que arranca
  Windows (aunque nadie inicie sesion), con la cuenta restringida "Servicio local" (LocalService).
  Hay que ejecutarlo como administrador: Tunel-zrok.bat (Jellyfin) y Tunel-zrok-Seerr.bat lo piden solos.

  Que hace:
   1. Frena la tarea y el zrok2 de ESTE servicio (los tuneles de otros servicios no se tocan).
   2. Copia zrok2.exe y tu entorno de zrok (%USERPROFILE%\.zrok2) a C:\ProgramData\zrok.
      Esa carpeta solo la pueden leer SYSTEM, Administradores, LocalService y tu usuario (solo lectura).
   3. Crea C:\ProgramData\zrok\tunel-<nombre>.ps1: comparte el servicio en https://<nombre>.shares.zrok.io,
      borra shares que hayan quedado colgados y si el tunel se cae lo relanza (esperando cada vez mas).
      Log: C:\ProgramData\zrok\home\zrok-<nombre>.log
   4. Crea la tarea programada "zrok <Servicio>" (al iniciar Windows, como LocalService).
   5. La arranca y verifica que el servicio responda desde internet.
  Se puede volver a ejecutar sin problema (por ejemplo despues de actualizar zrok2).
  El nombre reservado, zrok2.exe y el entorno salen de config.local.json (seccion Zrok).
#>
param(
  [ValidateSet('Jellyfin', 'Seerr')][string]$Servicio = 'Jellyfin',
  [string]$Nombre,
  [string]$Destino,
  [string]$RutaPrueba,
  [string]$Esperado,
  [string]$Base = 'C:\ProgramData\zrok',
  [string]$Exe,
  [string]$Entorno
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Config-Media.ps1'); $cfg = Get-ConfigMedia
$porServicio = @{
  Jellyfin = @{ Nombre = $cfg.Zrok.NombreJellyfin; Puerto = $cfg.Puertos.Jellyfin; Prueba = '/System/Info/Public'; Esperado = '"ServerName"' }
  Seerr    = @{ Nombre = $cfg.Zrok.NombreSeerr;    Puerto = $cfg.Puertos.Seerr;    Prueba = '/api/v1/status';      Esperado = 'version' }
}
$d = $porServicio[$Servicio]
if (-not $Nombre) { $Nombre = $d.Nombre }
if (-not $Destino) { $Destino = "http://127.0.0.1:$($d.Puerto)" }
if (-not $RutaPrueba) { $RutaPrueba = $d.Prueba }
if (-not $Esperado) { $Esperado = $d.Esperado }
if (-not $Exe) { $Exe = $cfg.Zrok.Exe }
if (-not $Entorno) { $Entorno = $cfg.Zrok.Entorno }
if (-not $Nombre) { throw "Falta el nombre reservado de zrok para $Servicio (Zrok.Nombre$Servicio en config.local.json)" }
$tarea = "zrok $Servicio"
$home2 = Join-Path $Base 'home'
$script = Join-Path $Base "tunel-$Nombre.ps1"
$url = "https://$Nombre.shares.zrok.io"

function Paso([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }

# "SI", "si", "SI" con tilde... (sin tildes para comparar)
function Test-Si([string]$r) { ($r.Trim().Normalize('FormD') -replace '\p{Mn}', '').ToUpper() -eq 'SI' }

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Hay que ejecutarlo como administrador (usa el .bat).'
}
if (-not (Test-Path -LiteralPath $Exe)) { throw "No encontre zrok2 en $Exe" }
if (-not (Test-Path -LiteralPath (Join-Path $Entorno 'environment.json'))) { throw "No encontre el entorno de zrok en $Entorno (falta 'zrok2 enable')" }

Write-Host "Esto va a publicar $Servicio ($Destino) en $url mediante zrok,"
Write-Host "como tarea programada '$tarea' que arranca con Windows usando la cuenta LocalService."
if (-not (Test-Si (Read-Host 'Escribi SI para continuar'))) { Write-Host 'Cancelado. No se cambio nada.'; return }

# --- 1. Frenar solo el tunel de este servicio ---
Paso "1. Frenar el tunel anterior de $Servicio"
if (Get-ScheduledTask -TaskName $tarea -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $tarea }
# Solo el tunel de este servicio: su script (tunel-<nombre>.ps1) y su zrok2 (public:<nombre>).
# Ojo: esta misma ventana tambien tiene el nombre en su linea de comandos (-Nombre ...), no hay que cerrarla
$patron = [regex]::Escape("tunel-$Nombre.ps1") + '|' + [regex]::Escape("public:$Nombre")
$procs = @(Get-CimInstance Win32_Process -Filter "Name='zrok2.exe' OR Name='powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $patron })
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host $(if ($procs.Count) { "  Cerrado ($($procs.Count) proceso/s). El share que quede colgado lo borra el tunel nuevo." } else { '  No habia ninguno.' })

# --- 2. Copiar binario y entorno ---
Paso "2. Copiar zrok2 y el entorno a $Base"
New-Item -ItemType Directory -Force -Path $home2 | Out-Null
$exeDestino = Join-Path $Base 'zrok2.exe'
# Si otro tunel lo esta usando no se puede reemplazar: solo se copia si cambio
if (-not (Test-Path -LiteralPath $exeDestino) -or (Get-FileHash -LiteralPath $exeDestino).Hash -ne (Get-FileHash -LiteralPath $Exe).Hash) {
  Copy-Item -LiteralPath $Exe -Destination $exeDestino -Force
}
Copy-Item -LiteralPath $Entorno -Destination $home2 -Recurse -Force
# Sin herencia: solo SYSTEM y Administradores (total), LocalService (modificar) y tu usuario (leer logs)
$localService = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-19').Translate([Security.Principal.NTAccount]).Value
icacls $Base /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)M' "${env:USERNAME}:(OI)(CI)RX" | Out-Null
if ($LASTEXITCODE) { throw "icacls fallo sobre $Base" }
icacls "$Base\*" /reset /T /C /Q | Out-Null   # que todo lo copiado herede esos permisos (la carpeta base no se toca)
Write-Host "  Copiados. Permisos: SYSTEM, Administradores, $localService y $env:USERNAME (lectura)."

# --- 3. Script del tunel ---
Paso '3. Script del tunel'
$tunel = @"
# Generado por Tunel-zrok.ps1 - comparte $Servicio por zrok y lo relanza si se cae
`$env:USERPROFILE = '$home2'
`$zrok = '$exeDestino'
`$log = '$home2\zrok-$Nombre.log'
function Log([string]`$m) { "`$(Get-Date -Format s) `$m" | Out-File `$log -Append -Encoding utf8 }
`$espera = 30
while (`$true) {
  if ((Test-Path `$log) -and (Get-Item `$log).Length -gt 10MB) { Move-Item `$log "`$log.1" -Force }
  # Un corte brusco (apagon, reinicio, proceso cerrado a la fuerza) deja el share anterior registrado
  # en zrok ocupando el nombre: se borra antes de crear el nuevo
  `$json = (& `$zrok list shares --json --target '$Destino' 2>&1) -join "``n"
  foreach (`$m in [regex]::Matches(`$json, '"(?:shareToken|token)"\s*:\s*"([^"]+)"')) {
    Log "borrando share anterior `$(`$m.Groups[1].Value)"
    & `$zrok delete share `$m.Groups[1].Value 2>&1 | ForEach-Object { "`$_" } | Out-File `$log -Append -Encoding utf8
  }
  Log "iniciando tunel $url -> $Destino"
  `$inicio = Get-Date
  & `$zrok share public '$Destino' -n 'public:$Nombre' --headless 2>&1 | ForEach-Object { "`$_" } | Out-File `$log -Append -Encoding utf8
  `$codigo = `$LASTEXITCODE
  # Si anduvo un buen rato se reintenta enseguida; si falla al toque, cada vez se espera mas (zrok pide backoff)
  if (((Get-Date) - `$inicio).TotalMinutes -ge 10) { `$espera = 30 } else { `$espera = [Math]::Min(`$espera * 2, 900) }
  Log "el tunel termino (codigo `$codigo), reintento en `$espera s"
  Start-Sleep -Seconds `$espera
}
"@
Set-Content -LiteralPath $script -Value $tunel -Encoding ASCII
Write-Host "  $script"

# --- 4. Tarea programada ---
Paso "4. Tarea programada '$tarea'"
$accion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$disparador = New-ScheduledTaskTrigger -AtStartup
$cuenta = New-ScheduledTaskPrincipal -UserId $localService -LogonType ServiceAccount -RunLevel Limited
$ajustes = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $tarea -Action $accion -Trigger $disparador -Principal $cuenta -Settings $ajustes `
  -Description "Publica $Servicio en $url con zrok (cuenta $localService)" -Force | Out-Null
Write-Host '  Arranca al iniciar Windows, aunque nadie inicie sesion.'

# --- 5. Arrancar y verificar ---
Paso '5. Arrancar y verificar'
Start-ScheduledTask -TaskName $tarea
$ok = $false
for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
  Start-Sleep -Seconds 3
  try {
    $r = Invoke-WebRequest "$url$RutaPrueba" -UseBasicParsing -TimeoutSec 10 -UserAgent 'curl/8'
    $ok = $r.Content -match $Esperado
  } catch { }
}
Write-Host ''
if ($ok) { Write-Host "Listo. $Servicio responde en $url" -ForegroundColor Green }
else { Write-Host "$Servicio todavia no responde en $url (si zrok esta ocupado, el tunel reintenta solo). Log: $home2\zrok-$Nombre.log" -ForegroundColor Yellow }
