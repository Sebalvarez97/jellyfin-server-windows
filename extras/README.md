# Pasos adicionales

El instalador ejecuta al final, en orden alfabético, todos los `.ps1` de esta carpeta.
Sirve para sumar componentes propios sin tocar el instalador.

Reglas para cada script:

- Se ejecuta como administrador, con la carpeta del servidor como directorio actual.
- Recibe `-Config <ruta a config.local.json>`. Puede leerla con `Config-Media.ps1`, que queda en la carpeta del servidor.
- Tiene que poder ejecutarse más de una vez sin romper nada (idempotente).
- Si falla, el instalador lo informa y sigue con el resto.
- Nada de credenciales escritas en el script: pedirlas con `Read-Host -AsSecureString` o leerlas de `<Raiz>\secretos\`.

Ejemplo mínimo (`extras\50-ejemplo.ps1`):

```powershell
param([string]$Config)
. (Join-Path (Split-Path $Config) 'Config-Media.ps1')
$cfg = Get-ConfigMedia $Config
Write-Host "Servidor en $($cfg.Raiz)"
```

Los scripts de esta carpeta son responsabilidad de quien los agrega: el proyecto no incluye ninguno.
