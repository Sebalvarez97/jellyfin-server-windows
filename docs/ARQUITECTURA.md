# Cómo funciona

Una PC con Windows funciona como servidor de películas y series para la casa. Alguien pide un título en **Seerr**. El sistema lo busca, lo descarga, lo guarda con el nombre correcto, le agrega subtítulos en español latino si hace falta, y aparece solo en **Jellyfin**.

```
 Persona ──pide──► Seerr :5055 ──► Radarr (películas) / Sonarr (series) ◄── Prowlarr :9696 (indexadores)
 (casa o                                  │ envía el torrent con su categoría
  remoto)                                 ▼
                                   qBittorrent :8080 (usuario restringido)
                                          │ baja a <Raiz>\Descargas\{radarr,sonarr}
                                          ▼
                       Radarr/Sonarr: hardlink + renombrado → <Raiz>\Movies | <Raiz>\Shows
                                          │                          ▲
                                          │              Bazarr :6767 (subtítulos .es-MX.srt)
                                          ▼
                                   Jellyfin :8096 ──► TV, celular, navegador
```

## Componentes

| App | Para qué | Puerto | Escucha en | Corre como |
|---|---|---|---|---|
| Jellyfin | Biblioteca y reproducción | 8096 | Red de la casa | Servicio, NetworkService |
| Seerr | Pedidos | 5055 | Red de la casa | Contenedor de Docker Desktop |
| Radarr | Películas | 7878 | `127.0.0.1` | Servicio, LocalService |
| Sonarr | Series | 8989 | `127.0.0.1` | Servicio, LocalService |
| Prowlarr | Indexadores | 9696 | `127.0.0.1` | Servicio, LocalService |
| qBittorrent | Descargas | 8080 | `127.0.0.1` | Usuario restringido (`media`), tarea programada |
| Bazarr | Subtítulos | 6767 | `127.0.0.1` | Servicio, LocalService |
| zrok (opcional) | Acceso desde fuera de casa | — | Túnel saliente | Tareas programadas, LocalService |

## Carpetas

Biblioteca y descargas están **en el mismo disco a propósito**. Radarr y Sonarr usan *hardlinks*: el mismo archivo con dos nombres, que pasa a la biblioteca al instante sin ocupar el doble y deja a qBittorrent seguir compartiendo. Por eso, para liberar espacio, hay que borrar **las dos** copias: `Borrar-Candidatos` lo hace.

```
<Raiz>                     (por ejemplo D:\JellyFin, la elige el instalador)
├── Movies\Título (Año)\Título (Año).mkv  (+ .es-MX.srt)
├── Shows\Título (Año)\Season 01\Título - S01E01 - Episodio.mkv
├── Descargas\radarr\  y  Descargas\sonarr\
├── secretos\              API keys y tokens (permisos solo para el dueño)
├── panel\                 Panel de control (Panel-Media.bat)
├── config.local.json      Configuración de esta instalación (no se sube al repo)
└── *.bat / *.ps1          Scripts del servidor
```

## Idioma antes que resolución

Radarr y Sonarr deciden el idioma por el **nombre del release**, con *Custom Formats*. Como la prioridad es el idioma y no la resolución, en el perfil **"Mejor disponible"** 1080p y 4K son el mismo grupo de calidad, y el 4K suma pocos puntos.

| Custom Format | Detecta | Puntos |
|---|---|---|
| Multi-audio con español | `MULTi`/`DUAL` en el nombre y uno de los idiomas es español o latino | +150 |
| Original + español | Incluye el idioma original de la película y dice español/latino | +150 |
| Latino | Idioma "Spanish (Latino)" o `LATINO`/`LATAM` en el nombre | +100 |
| 4K | 2160p (solo en "Mejor disponible") | +50 |
| Doblada sin original | Español sin el idioma original y sin `MULTi`/`DUAL` | −300 |

Resultado: original o dual con español > 4K > doblada sin original. Las dobladas quedan como último recurso. Si después aparece una versión mejor por **100 puntos o más**, la reemplaza sola.

Otros ajustes de los perfiles:
- **Sin Remux:** pesan de 30 a 60 GB por película.
- **Repacks:** no se consideran mejora.
- **Seeders:** Radarr pide 5 como mínimo, para no elegir un 4K que figura con seeders pero está muerto.

Si el audio no está en español, Bazarr baja subtítulos en latino: perfil `ea` y proveedor OpenSubtitles.com, con la cuenta del dueño.

## Seguridad

- Si algo malicioso entra por una descarga, solo puede tocar `<Raiz>`: ningún servicio tiene acceso a los documentos del usuario.
- qBittorrent, que es lo más expuesto, corre con un usuario estándar propio, oculto del inicio de sesión, y no descarga ejecutables (`*.exe`, `*.lnk`, `*.scr` y otros).
- Desde la red de la casa solo se ven Jellyfin y Seerr.
- Radarr, Sonarr y Prowlarr escuchan en `127.0.0.1` y exigen **Allowed Hosts**: `localhost,127.0.0.1,host.docker.internal`. Seerr los alcanza igual, porque Docker Desktop reenvía por localhost.
- Para el acceso remoto se usa zrok, un túnel saliente que no abre puertos en el router. En Jellyfin:
  - Redes LAN: solo la red de la casa.
  - Proxies conocidos: `127.0.0.1, 10.0.0.0/8`.
  - Límite de bitrate remoto: 4 Mbps.
  - Bloqueo tras 5 intentos fallidos.

## Mantenimiento automático

| Tarea | Cuándo | Qué hace |
|---|---|---|
| Media - Arranque | 5 min después de iniciar Windows | Revisa servicios, tareas y contenedores, y levanta lo caído |
| Media - Mantenimiento | Domingos 4:00 | Actualiza Jellyfin, Bazarr, qBittorrent (winget) y Seerr (imagen nueva), revisa todo y genera el reporte de espacio |

Radarr, Sonarr y Prowlarr se actualizan solos. Los logs quedan en `C:\ProgramData\MediaStack\logs`.

El reporte de espacio (`Reporte-espacio.html`) marca como candidato a borrar lo visto completo hace más de 60 días, y sugiere borrar solo si el disco pasa el 80%. No borra nada sin un `SI` explícito en `candidatos-borrar.csv`.

## Por qué no todo en Docker

Se probó, y funciona: los hardlinks andan desde los contenedores y el disco rinde al 80%. Pero Docker Desktop solo arranca cuando alguien inicia sesión en Windows, mientras que los servicios nativos arrancan solos después de un corte de luz. Además, la aceleración de video de Jellyfin con NVIDIA es frágil dentro de Docker en Windows. Seerr es lo único en Docker, porque no tiene versión nativa para Windows.
