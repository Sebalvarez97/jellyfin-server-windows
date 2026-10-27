# Comun.ps1 - Funciones compartidas por el instalador (se carga con dot-source).
# Todas las acciones que cambian algo pasan por Invoke-Cambio, que respeta -SoloRevisar.

$script:SoloRevisar = $false
$script:LogInstalacion = $null
$script:Pendientes = New-Object System.Collections.Generic.List[string]

function Initialize-Log([string]$ruta) {
  New-Item -ItemType Directory -Force -Path (Split-Path $ruta) | Out-Null
  $script:LogInstalacion = $ruta
}

function Write-Log([string]$t) {
  if ($script:LogInstalacion) { Add-Content -LiteralPath $script:LogInstalacion -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $t) -Encoding UTF8 }
}

function Paso([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan; Write-Log "== $t" }
function Info([string]$t) { Write-Host "  $t"; Write-Log "   $t" }
function Ok([string]$t) { Write-Host "  [OK] $t" -ForegroundColor Green; Write-Log "OK $t" }
function Aviso([string]$t) { Write-Host "  [!] $t" -ForegroundColor Yellow; Write-Log "AVISO $t" }
function Falla([string]$t) { Write-Host "  [X] $t" -ForegroundColor Red; Write-Log "FALLA $t" }

# Algo que el usuario tiene que hacer a mano: se muestra al final
function Add-Pendiente([string]$t) { $script:Pendientes.Add($t); Write-Log "PENDIENTE $t" }

# Ejecuta un cambio, o solo lo informa en modo revision
function Invoke-Cambio([string]$descripcion, [scriptblock]$accion) {
  if ($script:SoloRevisar) { Write-Host "  (revision) haria: $descripcion" -ForegroundColor DarkGray; Write-Log "REVISION $descripcion"; return $null }
  Write-Log "CAMBIO $descripcion"
  & $accion
}

function Test-Si([string]$r) { ("$r".Trim().Normalize('FormD') -replace '\p{Mn}', '').ToUpper() -in 'SI', 'S' }

function Preguntar([string]$texto, [string]$predeterminado) {
  $r = Read-Host $(if ($predeterminado) { "$texto [$predeterminado]" } else { $texto })
  if ("$r".Trim()) { "$r".Trim() } else { $predeterminado }
}

function Preguntar-SiNo([string]$texto, [bool]$predeterminado = $true) {
  $r = Read-Host ("$texto " + $(if ($predeterminado) { '[SI/no]' } else { '[si/NO]' }))
  if (-not "$r".Trim()) { return $predeterminado }
  Test-Si $r
}

function Esperar-Enter([string]$texto) { Read-Host "  $texto (Enter para seguir)" | Out-Null }

function Get-Plano([Security.SecureString]$s) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Preguntar-Clave([string]$texto, [int]$minimo = 6) {
  while ($true) {
    $a = Read-Host $texto -AsSecureString
    $b = Read-Host 'Repetila' -AsSecureString
    $pa = Get-Plano $a
    if ($pa.Length -lt $minimo) { Aviso "Tiene que tener al menos $minimo caracteres."; continue }
    if ($pa -cne (Get-Plano $b)) { Aviso 'No coinciden, de nuevo.'; continue }
    return $a
  }
}

# Espera a que una URL responda (cualquier respuesta HTTP cuenta como viva)
function Wait-Url([string]$url, [int]$segundos = 120) {
  $limite = (Get-Date).AddSeconds($segundos)
  while ((Get-Date) -lt $limite) {
    try { $null = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5; return $true }
    catch { if ($_.Exception.Response) { return $true } }
    Start-Sleep -Seconds 3
  }
  $false
}

# --- APIs ---
function Get-ArrKey([string]$app) {
  $f = "C:\ProgramData\$app\config.xml"
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  ([xml](Get-Content -LiteralPath $f -Raw)).Config.ApiKey
}

# Llamada REST. PowerShell 5.1 devuelve los arrays JSON como un solo objeto: el ForEach los desarma.
function Invoke-Api([string]$url, [string]$metodo = 'GET', $cuerpo, [hashtable]$headers = @{}, [string]$contentType = 'application/json; charset=utf-8') {
  $p = @{ Uri = $url; Method = $metodo; Headers = $headers; ContentType = $contentType; TimeoutSec = 120 }
  if ($null -ne $cuerpo) {
    $p.Body = $(if ($cuerpo -is [string]) { $cuerpo } else { [Text.Encoding]::UTF8.GetBytes(($cuerpo | ConvertTo-Json -Depth 30)) })
  }
  try { Invoke-RestMethod @p | ForEach-Object { $_ } }
  catch {
    $det = $_.ErrorDetails.Message
    if (-not $det -and $_.Exception.Response) { try { $det = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { } }
    throw "$metodo $url -> $($_.Exception.Message) $det"
  }
}

# Cliente para Radarr/Sonarr/Prowlarr: Arr radarr GET 'rootfolder'
$script:Apps = @{}
function Register-Arr([string]$nombre, [int]$puerto, [string]$version, [string]$carpeta) {
  $script:Apps[$nombre] = @{ Base = "http://127.0.0.1:$puerto/api/$version"; Carpeta = $carpeta; Puerto = $puerto }
}
function Arr([string]$app, [string]$metodo, [string]$ruta, $cuerpo) {
  $a = $script:Apps[$app]
  Invoke-Api "$($a.Base)/$ruta" $metodo $cuerpo @{ 'X-Api-Key' = (Get-ArrKey $a.Carpeta) }
}

function Set-Props($obj, [hashtable]$valores) {
  foreach ($k in $valores.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $valores[$k] -Force }
  $obj
}
function Set-Fields($obj, [hashtable]$valores) {
  foreach ($f in $obj.fields) { if ($valores.ContainsKey($f.name)) { $f | Add-Member -NotePropertyName value -NotePropertyValue $valores[$f.name] -Force } }
  $obj
}
function Copy-Objeto($o) { $o | ConvertTo-Json -Depth 30 | ConvertFrom-Json }

# Servicio de Windows con una cuenta dada (LocalService, NetworkService)
function Set-CuentaServicio([string]$servicio, [string]$cuenta) {
  $svc = Get-CimInstance Win32_Service -Filter "Name='$servicio'" -ErrorAction SilentlyContinue
  if (-not $svc) { Falla "No existe el servicio $servicio"; return }
  if ($svc.StartName -eq $cuenta) { Ok "$servicio ya corre como $cuenta"; return }
  Invoke-Cambio "$servicio pasa a correr como $cuenta" {
    $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{ StartName = $cuenta; StartPassword = '' }
    if ($r.ReturnValue -ne 0) { Falla "No se pudo cambiar la cuenta de $servicio (codigo $($r.ReturnValue))" }
    else { Restart-Service -Name $servicio -Force; Ok "$servicio corre como $cuenta" }
  }
}

function Grant-Modificar([string]$ruta, [string]$cuenta) {
  # icacls muestra el nombre localizado ("NT AUTHORITY\SERVICIO LOCAL"), no el SID
  $nombre = $cuenta
  if ($cuenta -like '`*S-*') { try { $nombre = (New-Object Security.Principal.SecurityIdentifier $cuenta.Substring(1)).Translate([Security.Principal.NTAccount]).Value } catch { } }
  elseif ($cuenta -notmatch '\\') { $nombre = "$env:COMPUTERNAME\$cuenta" }
  $acl = (icacls $ruta 2>$null) -join "`n"
  if ($acl -match ([regex]::Escape($nombre) + ':(\([A-Z]+\))*\((M|F)\)')) { return }
  Invoke-Cambio "permiso Modificar para $cuenta sobre $ruta" {
    icacls $ruta /grant "${cuenta}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE) { Falla "icacls fallo sobre $ruta" } else { Ok "$cuenta puede modificar $ruta" }
  }
}

# Hash de contrasena de la Web UI de qBittorrent (PBKDF2-SHA512, 100000 iteraciones)
function Get-HashQbittorrent([Security.SecureString]$clave) {
  $sal = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($sal)
  $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes((Get-Plano $clave), $sal, 100000, [Security.Cryptography.HashAlgorithmName]::SHA512)
  '@ByteArray({0}:{1})' -f [Convert]::ToBase64String($sal), [Convert]::ToBase64String($kdf.GetBytes(64))
}
