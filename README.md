# jellyfin-server-windows

Servidor de películas y series para la casa, en una PC con Windows. Alguien pide un título desde el celular o la TV, y el servidor lo busca, lo descarga, lo ordena con el nombre correcto, le agrega subtítulos en español si hace falta, y aparece listo para ver en Jellyfin. Todo arranca solo con Windows, se mantiene solo y se controla desde un panel.

```
 Seerr (pedir) ──► Radarr / Sonarr ◄── Prowlarr (indexadores)
                        │
                   qBittorrent (usuario restringido)
                        │  hardlink + nombre correcto
                        ▼
              Biblioteca ◄── Bazarr (subtítulos)
                        │
                   Jellyfin (ver: TV, celular, navegador)
```

| Pieza | Para qué |
|---|---|
| [Jellyfin](https://jellyfin.org) | Biblioteca y reproducción, con aceleración por GPU |
| [Seerr](https://github.com/seerr-team/seerr) | Página de pedidos, con el mismo login de Jellyfin |
| [Radarr](https://radarr.video) / [Sonarr](https://sonarr.tv) | Buscan, descargan y ordenan películas y series |
| [Prowlarr](https://prowlarr.com) | Administra los indexadores y los comparte |
| [qBittorrent](https://www.qbittorrent.org) | Cliente de descarga |
| [Bazarr](https://www.bazarr.media) | Subtítulos en español latino |
| [zrok](https://zrok.io) (opcional) | Acceso desde fuera de casa sin abrir puertos |

## Lo que hace distinto a este proyecto

- **Nativo en Windows**, como servicios que arrancan solos aunque nadie inicie sesión. Solo Seerr usa Docker Desktop.
- **Seguridad por capas:**
  - Cada servicio solo puede escribir en las carpetas de datos.
  - qBittorrent corre con un usuario propio y no descarga ejecutables.
  - Desde la red solo se ven Jellyfin y Seerr.
- **Primero el idioma:**
  - Prefiere audio original o dual con español por sobre el 4K.
  - Si solo hay audio original, baja subtítulos en latino.
  - Las versiones dobladas sin el audio original quedan como último recurso.
- **Mantenimiento automático:** chequeo de salud al arrancar, actualizaciones semanales y reporte de espacio con candidatos a borrar (vos aprobás).
- **Panel de control** de doble clic, con el estado de todo, avisos y acciones.

## Requisitos

- Windows 10 u 11, con permisos de administrador y [winget](https://learn.microsoft.com/windows/package-manager/winget/).
- Un disco NTFS con espacio para la biblioteca. Descargas y biblioteca van en el **mismo disco**, por los hardlinks.
- Para Seerr: Docker Desktop, con WSL2. El instalador lo instala si falta.
- Opcional: una placa NVIDIA, Intel o AMD para que Jellyfin convierta video por hardware.

## Instalación

```powershell
git clone https://github.com/<usuario>/jellyfin-server-windows.git
```

Después, doble clic en **`Instalar.bat`** y aceptá el UAC. El instalador:

1. **Pregunta** la carpeta del servidor, las subcarpetas, la IP de la PC, la red de la casa, la zona horaria y si querés acceso remoto. Guarda las respuestas en `<carpeta>\config.local.json`.
2. **Instala** Jellyfin, Radarr, Sonarr, Prowlarr, qBittorrent y Bazarr con winget, y verifica que queden como servicios.
3. **Configura todo por API:**
   - carpetas, nombres de archivo y hardlinks;
   - cliente de descarga, Custom Formats de idioma y perfiles;
   - conexión entre las apps;
   - bloqueo de red: las apps de administración quedan solo en `127.0.0.1`.
4. **qBittorrent:** crea su usuario restringido y lo deja como tarea programada.
5. **Jellyfin y Seerr:** abre sus asistentes, espera a que los completes y termina de configurarlos.
6. **Red:** IP fija opcional, DNS de respaldo y reglas de firewall.
7. **Tareas de mantenimiento y túneles de zrok** (si los elegiste).
8. **Pasos adicionales** de `extras\` y chequeo de salud final.

Al terminar te muestra la lista de lo que queda de tu lado.

Se puede **volver a ejecutar** cuando quieras: cada paso revisa lo que ya está hecho y solo completa lo que falta. Con `Instalar.bat -SoloRevisar` muestra qué haría, sin cambiar nada.

### Lo que hacés vos (el instalador te lo pide y espera)

| Paso | Por qué no es automático |
|---|---|
| Contraseñas: usuario de qBittorrent, su Web UI y login de Radarr/Sonarr/Prowlarr | Son tuyas: el instalador no guarda ninguna |
| Aceptar el aviso legal de qBittorrent y el acuerdo de Docker Desktop | Son acuerdos que acepta una persona |
| Asistentes de Jellyfin y Seerr, y la clave de API de Jellyfin | Crean tu usuario administrador |
| **Indexadores** en Prowlarr | Qué sitios usar es decisión y responsabilidad tuya |
| Cuenta de OpenSubtitles.com en Bazarr | Es tu cuenta |
| Usuarios de Jellyfin para cada persona de la casa | — |

## Uso diario

| Quiero… | Dónde |
|---|---|
| Pedir algo | Seerr: `http://<IP>:5055` |
| Ver | Jellyfin: `http://<IP>:8096`, o sus apps para TV y celular |
| Ver el estado de todo | `Panel-Media.bat` en la carpeta del servidor |
| Liberar espacio | `Reporte-Espacio.bat`, después `Borrar-Candidatos.bat` |
| Ordenar una biblioteca que ya tenías | `Reorganizar.bat` |
| Actualizar los scripts después de un `git pull` | `Desplegar.bat` |

## Estructura del repositorio

```
├── Instalar.bat / instalador\     Instalador (fases idempotentes, modo -SoloRevisar)
├── Desplegar.bat / .ps1           Copia servidor\ a la carpeta del servidor
├── servidor\                      Lo que vive en la carpeta del servidor: mantenimiento, reportes,
│                                  reorganizar, qBittorrent restringido, túneles zrok, panel
├── extras\                        Tus pasos adicionales (ver extras\README.md)
├── docs\ARQUITECTURA.md           Cómo funciona y por qué
├── docs\PROBLEMAS.md              Problemas conocidos y soluciones
└── config.ejemplo.json            Ejemplo de la configuración local
```

## Seguridad y privacidad

- `config.local.json`, `secretos\`, los logs y lo que generan los scripts **no se suben** (ver `.gitignore`). Las API keys se leen de la configuración de cada app al ejecutar; no hay ninguna en el código.
- El proyecto no incluye indexadores ni componentes para saltear protecciones de sitios.
- Descargar contenido con copyright sin permiso es ilegal en muchos países. Usalo con contenido que tengas derecho a descargar.

## Ports a otras plataformas

Este repositorio es la versión para Windows. Las versiones para Linux y Docker van a vivir en sus propios forks.
