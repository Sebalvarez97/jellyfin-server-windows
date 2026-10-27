# Problemas conocidos y soluciones

Casi todos vienen de detalles de Windows o de versiones nuevas de las apps. Si algo falla, empezá por esta tabla y por el log de `C:\ProgramData\MediaStack\logs`.

| Área | Síntoma | Causa | Solución |
|---|---|---|---|
| Sonarr | Instalado pero sin servicio | El instalador silencioso saltea ese paso | `C:\ProgramData\Sonarr\bin\ServiceInstall.exe` como administrador (el instalador del proyecto lo hace) |
| Bazarr | `winget install` falla | El paquete exige carpeta | `--location C:\Bazarr` |
| Permisos | Radarr/Sonarr no pueden renombrar ni borrar | LocalService sin permiso sobre archivos ajenos | `icacls <Raiz> /grant "*S-1-5-19:(OI)(CI)M"` |
| PowerShell | `Access is denied` | La ventana no es de administrador | Clic derecho → Ejecutar como administrador (el prompt arranca en `C:\WINDOWS\system32`) |
| qBittorrent | La Web UI no levanta ("Credentials are not set") | qBittorrent 5.x exige usuario y contraseña | Configurarlos (el instalador los pide) |
| qBittorrent | La tarea programada nunca arranca (`0x00041303`) | El usuario restringido no tiene "Iniciar sesión como proceso por lotes" | `secedit` (el instalador lo otorga) |
| qBittorrent | No aparece la configuración en `%APPDATA%` | Se abrió desde una app empaquetada (MSIX), que virtualiza `AppData` | Buscar en `%LOCALAPPDATA%\Packages\<app>\LocalCache\Roaming` |
| Jellyfin | La API responde 401 con una key válida | Jellyfin 12 no acepta `X-Emby-Token` | Encabezado `Authorization: MediaBrowser Token="<key>"` |
| Jellyfin | Lo remoto se ve como local (sin límite de bitrate) | Faltan Redes LAN y Proxies conocidos, o no se tocó Guardar | Ver la sección de seguridad de ARQUITECTURA.md y reiniciar Jellyfin |
| Sonarr/Prowlarr | No deja cambiar Bind Address | Con login desactivado para la red local exige Allowed Hosts | `localhost,127.0.0.1,host.docker.internal` |
| Red | Radarr/Sonarr/Prowlarr visibles desde la red | Reglas de firewall "NzbDrone" de sus instaladores | Bind Address `127.0.0.1` (opcional: borrar esas reglas) |
| Red | "Host desconocido" intermitente | DNS del router lento | Agregar un DNS secundario (por ejemplo `1.1.1.1`) |
| Radarr | Elige un 4K que nunca baja | Los seeders que informan los indexadores públicos son viejos o inflados | Mínimo de 5 seeders en Radarr; quitar de la cola con "bloquear" |
| Radarr/Sonarr | Vuelve a bajar lo mismo por un "REPACK" | Por defecto los repacks cuentan como mejora | Media Management → Propers and Repacks: Do not Prefer |
| Radarr/Sonarr | Reemplaza por una versión doblada a otro idioma | Un Custom Format premiaba cualquier DUAL/MULTi | "Multi-audio con español" exige que uno de los idiomas sea español |
| Seerr | Muestra "Disponible" algo sin archivos | Su escaneo de Sonarr marca mal el estado | Confiar en lo que muestra Jellyfin |
| Seerr | No responde después de reiniciar | Docker Desktop no arrancó (desactivado al inicio, o nadie inició sesión) | Configuración → Aplicaciones → Inicio → Docker Desktop |
| Bazarr | No encuentra subtítulos en latino | En 1.6 ya no existen Subdivx ni Podnapisi | Cuenta en OpenSubtitles.com |
| Indexadores | "Blocked by CloudFlare Protection" | Protección anti-bots del sitio | Elegir otro indexador que pase el test |
| Indexadores | En pausa después de un reinicio | Fallaron mientras faltaba algo de lo que dependen | Prowlarr → Indexers → Test |
| Archivos | `algo.txt.txt` | El Explorador esconde extensiones | Mostrar extensiones de archivo en el Explorador |
