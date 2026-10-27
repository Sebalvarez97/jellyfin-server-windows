'use strict';
/* Panel del servidor de medios. Todo el texto con datos de afuera (nombres de torrents,
   mensajes de las apps) se inserta con textContent: nunca como HTML. */

// ---------- utilidades ----------
const $ = (s, r = document) => r.querySelector(s);
function h(tag, props, ...hijos) {
  const el = document.createElement(tag);
  if (props) for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k === 'style') Object.assign(el.style, v);
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of hijos.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : String(c));
  }
  return el;
}
const poner = (el, ...hijos) => { el.replaceChildren(...hijos.flat(Infinity).filter(x => x != null && x !== false)); };

const nf1 = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 1 });
const nf0 = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 0 });
function bytes(n) {
  if (n == null || isNaN(n)) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i >= 2 ? nf1 : nf0).format(n) + ' ' + u[i];
}
const vel = n => (n == null ? '—' : bytes(n) + '/s');
function duracion(seg) {
  if (seg == null || seg < 0 || seg >= 8640000) return '∞';
  const d = Math.floor(seg / 86400), hs = Math.floor(seg % 86400 / 3600), m = Math.floor(seg % 3600 / 60);
  if (d) return `${d} d ${hs} h`;
  if (hs) return `${hs} h ${m} min`;
  return m ? `${m} min` : `${Math.round(seg)} s`;
}
function fecha(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleString('es-AR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
}
function hace(iso) {
  if (!iso) return '';
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 50) return 'recién';
  if (s < 3600) return `hace ${Math.round(s / 60)} min`;
  if (s < 86400) return `hace ${Math.round(s / 3600)} h`;
  return `hace ${Math.round(s / 86400)} días`;
}
const plural = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`;
const cuentaCorta = c => (c || '').replace(/^NT AUTHORITY\\/i, '').replace(/^.*\\/, '');

// ---------- API ----------
let caido = false;
function panelCaido() {
  if (caido) return;
  caido = true;
  $('#caido').hidden = false;
}
async function api(ruta, opciones = {}) {
  let r;
  try {
    r = await fetch(ruta, { credentials: 'same-origin', cache: 'no-store', ...opciones, headers: { 'X-Panel': '1', 'Content-Type': 'application/json' } });
  } catch (e) { panelCaido(); throw new Error('Sin conexión con el panel'); }
  if (r.status === 403) { panelCaido(); throw new Error('La sesión del panel venció'); }
  const txt = await r.text();
  let j = null;
  try { j = JSON.parse(txt); } catch { /* texto plano */ }
  if (!r.ok) throw new Error((j && j.error) || txt || `HTTP ${r.status}`);
  return j;
}
const accion = cuerpo => api('/api/accion', { method: 'POST', body: JSON.stringify(cuerpo) });

// ---------- datos de la instalacion (salen de config.local.json via /api/config) ----------
let cfg = {
  raiz: '', bat: 'Panel-Media.bat', proteger: 'Proteger-Scripts.bat', archivoKeyJellyfin: 'secretos\\jellyfin-api.txt',
  carpetas: { peliculas: 'Movies', series: 'Shows', descargas: 'Descargas' },
  ipServidor: '', redLocal: '', usuarioDescargas: 'media', tareaQbit: 'qBittorrent (media)',
  zrok: false, diasVisto: 60, umbralPct: 80, puertos: {}, web: {}
};
async function cargarConfig() {
  try { cfg = { ...cfg, ...(await api('/api/config')) }; } catch { /* quedan los valores por defecto */ }
  $('#caido-bat').textContent = cfg.bat;
  const q = $('#abrir-qbit');
  if (cfg.web.qbittorrent) { q.href = cfg.web.qbittorrent; q.hidden = false; }
}

// ---------- estado compartido ----------
const datos = { estado: null, salud: null, diag: null, espacio: null };
const ocupados = new Set();          // botones con una accion en curso
const seleccion = new Set();         // claves de candidatos tildados
let verTodo = false;

// ---------- avisos flotantes ----------
function toast(tipo, titulo, detalle, { fijo = false, hijos = [] } = {}) {
  const t = h('div', { class: `toast ${tipo}` },
    h('b', { text: titulo }),
    detalle ? h('div', { class: 'det', text: detalle }) : null,
    hijos.length ? h('div', { class: 'acciones' }, hijos) : null);
  $('#toasts').append(t);
  if (!fijo) setTimeout(() => t.remove(), tipo === 'error' ? 12000 : 6000);
  return t;
}

// ---------- confirmacion ----------
function confirmar({ titulo, cuerpo, boton = 'Confirmar', peligro = false, uac = false, palabra = null }) {
  const dlg = $('#dlg');
  $('#dlg-titulo').textContent = titulo;
  poner($('#dlg-cuerpo'), cuerpo,
    uac ? h('div', { class: 'uac' }, h('span', { text: '🛡' }), h('span', { text: 'Windows te va a pedir permiso de administrador. Si cancelás ahí, no se cambia nada.' })) : null);
  const si = $('#dlg-si'), lbl = $('#dlg-palabra-lbl'), inp = $('#dlg-palabra');
  si.textContent = boton;
  si.className = 'btn ' + (peligro ? 'btn-peligro' : 'btn-primario');
  lbl.hidden = !palabra;
  inp.value = '';
  const normal = s => s.trim().normalize('NFD').replace(/\p{Mn}/gu, '').toUpperCase();
  const validar = () => { si.disabled = !!palabra && normal(inp.value) !== palabra; };
  if (palabra) $('#dlg-palabra-txt').textContent = `Escribí ${palabra} para confirmar`;
  inp.oninput = validar;
  validar();
  dlg.returnValue = '';
  dlg.showModal();
  (palabra ? inp : $('#dlg-no')).focus();
  return new Promise(res => dlg.addEventListener('close', () => res(dlg.returnValue === 'si'), { once: true }));
}
function mostrar(titulo, cuerpo) {
  const dlg = $('#dlg');
  $('#dlg-titulo').textContent = titulo;
  poner($('#dlg-cuerpo'), cuerpo);
  $('#dlg-palabra-lbl').hidden = true;
  $('#dlg-si').textContent = 'Cerrar';
  $('#dlg-si').className = 'btn btn-primario';
  $('#dlg-si').disabled = false;
  $('#dlg-no').hidden = true;
  dlg.showModal();
  dlg.addEventListener('close', () => { $('#dlg-no').hidden = false; }, { once: true });
}

// ---------- ejecutar una accion confirmada ----------
const MENSAJES = {
  'uac-cancelado': 'Cancelaste el permiso de Windows: no se cambió nada.',
  'no-arranco': 'Windows lo intentó, pero no quedó funcionando.',
  'sin-respuesta': 'No hubo respuesta en 5 minutos.',
  'csv-cambio': 'La lista de candidatos cambió desde que la abriste. Ya se recargó: revisala y volvé a confirmar.',
  'ocupado': 'Ya hay un borrado o una regeneración de la lista en curso.',
  'no-aplica': 'Esa acción no corresponde para esto.',
  'cuenta': 'Windows no dejó cambiar la cuenta del servicio.'
};
async function ejecutar(clave, cuerpo, titulo, { alTerminar, mostrarSalida = false } = {}) {
  ocupados.add(clave);
  renderServicios();
  let r;
  try { r = await accion(cuerpo); }
  catch (e) { ocupados.delete(clave); renderServicios(); toast('error', titulo, e.message); return; }
  if (!r.ok) {
    ocupados.delete(clave); renderServicios();
    toast('error', titulo, [MENSAJES[r.codigo], r.mensaje].filter(Boolean).join(' ') || 'No se pudo.');
    if (r.codigo === 'csv-cambio') cargarEspacio();
    return;
  }
  if (!r.trabajo) {
    ocupados.delete(clave);
    toast('ok', titulo, r.mensaje || 'Listo.');
    if (alTerminar) alTerminar(r);
    refrescarPronto();
    return;
  }
  const t = toast('info', titulo, 'En curso…', { fijo: true });
  t.querySelector('b').prepend(h('span', { class: 'girando' }), ' ');
  const seguir = async () => {
    let j;
    try { j = await api('/api/trabajo?id=' + r.trabajo); } catch { if (!caido) setTimeout(seguir, 3000); return; }
    if (j.estado === 'corriendo') { setTimeout(seguir, 2000); return; }
    ocupados.delete(clave);
    t.remove();
    const ok = j.estado === 'ok';
    const det = ok ? 'Listo.' : [MENSAJES[j.codigo] || 'Falló.', j.mensaje].filter(Boolean).join(' ');
    const hijos = j.salida ? [h('button', { class: 'btn btn-chico', text: 'Ver detalle', onclick: () => mostrar(titulo, h('pre', { text: j.salida })) })] : [];
    toast(ok ? 'ok' : 'error', titulo, det, { fijo: mostrarSalida && !!j.salida, hijos });
    if (mostrarSalida && j.salida) mostrar(titulo, h('pre', { text: j.salida }));
    if (alTerminar) alTerminar(j);
    refrescarPronto();
  };
  setTimeout(seguir, 1500);
}
function refrescarPronto() {
  setTimeout(cargarEstado, 500);
  setTimeout(() => cargarSalud(true), 1500);
  setTimeout(() => cargarDiag(true), 4000);
}

// ---------- KPIs ----------
function estadoServicio(s) {
  if (s.tipo === 'contenedor') {
    if (!s.docker) return ['falla', 'Docker Desktop cerrado'];
    if (!s.motor) return ['aviso', 'Docker arrancando…'];
    if (s.contenedor !== 'running') return ['falla', s.contenedor ? `Contenedor ${s.contenedor}` : 'Contenedor detenido'];
  }
  switch (s.estado) {
    case 'Running':
      if (s.responde === false) return ['falla', s.tipo === 'tunel' ? 'No responde desde internet' : 'Corre pero no responde'];
      if (s.responde == null) return ['ok', 'Corriendo'];
      return ['ok', s.tipo === 'tunel' ? 'Responde desde internet' : 'Funcionando'];
    case 'StartPending': return ['aviso', 'Arrancando…'];
    case 'StopPending': return ['aviso', 'Deteniéndose…'];
    case 'NoExiste': return ['falla', 'No está instalado como servicio'];
    default: return ['falla', 'Detenido'];
  }
}
function renderKpis() {
  const e = datos.estado;
  if (!e) return;
  const serv = e.servicios;
  const bien = serv.filter(s => estadoServicio(s)[0] === 'ok' && s.cuentaOk).length;
  const d = e.descargas, g = d.grupos || {};
  const remotos = e.reproducciones.filter(r => r.remoto).length;
  const dsk = e.disco;
  const nivelDisco = dsk.pct >= dsk.umbral ? 'falla' : dsk.pct >= dsk.umbral - 10 ? 'aviso' : '';
  const kpi = (tit, val, sub, extra, nivel) => h('div', { class: 'kpi' },
    h('div', { class: 'k-tit' }, nivel ? h('span', { class: 'punto ' + nivel }) : null, tit),
    h('div', { class: 'k-val' }, val), h('div', { class: 'k-sub', text: sub }), extra);
  const md = h('div', { class: 'mini-barra ' + nivelDisco }, h('div', { style: { width: dsk.pct + '%' } }));
  poner($('#kpis'),
    kpi('Servicios', [`${bien}`, h('small', { text: ` / ${serv.length}` })], bien === serv.length ? 'todo funcionando' : `${serv.length - bien} con problemas`, null, bien === serv.length ? 'ok' : 'falla'),
    kpi('Descargas', [`${g.bajando || 0}`, h('small', { text: ' bajando' })],
      [g.trabadas ? `${g.trabadas} trabada${g.trabadas > 1 ? 's' : ''}` : null, g.enCola ? `${g.enCola} en cola` : null, `${g.compartiendo || 0} compartiendo`].filter(Boolean).join(' · '),
      null, d.ok ? (g.trabadas ? 'aviso' : 'ok') : 'falla'),
    kpi('qBittorrent', ['↓ ', vel(d.bajada)], `↑ ${vel(d.subida)}`, null, d.ok ? 'ok' : 'falla'),
    kpi(e.red ? `Red (${e.red.placa})` : 'Red', e.red ? ['↓ ', vel(e.red.bajada)] : '—',
      e.red ? `↑ ${vel(e.red.subida)} · enlace ${nf0.format((e.red.enlace || 0) / 1e6)} Mbps` : 'sin placa activa'),
    kpi('Reproduciendo', [`${e.reproducciones.length}`, h('small', { text: e.reproducciones.length === 1 ? ' persona' : ' personas' })],
      e.reproducciones.length ? (remotos ? `${remotos} desde afuera${cfg.zrok ? ' (zrok)' : ''}` : 'todos en casa') : 'nadie está mirando'),
    kpi('Disco D:', [`${dsk.pct}%`, h('small', { text: ' usado' })], `${bytes(dsk.libre)} libres de ${bytes(dsk.total)}`, md, nivelDisco || 'ok'));

  const rep = e.reproducciones;
  poner($('#reproducciones'), rep.length ? h('div', { class: 'repro' }, rep.map(r => h('span', { class: 'chip' },
    h('span', { class: 'punto ' + (r.remoto ? 'info' : 'ok') }),
    h('b', { text: r.usuario || '—' }), h('span', { text: r.titulo || '' }),
    h('span', { class: 'tenue', text: [r.cliente, r.metodo === 'Transcode' ? `convirtiendo${r.bitrate ? ' a ' + nf1.format(r.bitrate / 1e6) + ' Mbps' : ''}` : r.metodo === 'DirectPlay' ? 'directo' : r.metodo, r.remoto ? 'desde afuera' : 'en casa', r.pausado ? 'en pausa' : null].filter(Boolean).join(' · ') })))) : null);
}

// ---------- servicios ----------
function botonesServicio(s) {
  const b = [];
  const ocupado = k => ocupados.has(k);
  const btn = (texto, clave, fn, primario) => h('button', { class: 'btn btn-chico' + (primario ? ' btn-primario' : ''), text: ocupado(clave) ? '…' : texto, disabled: ocupado(clave) || null, onclick: fn });
  const enCasa = datos.estado ? datos.estado.reproducciones.length : 0;
  if (s.tipo === 'servicio') {
    const corriendo = s.estado === 'Running';
    const op = corriendo ? 'reiniciar' : 'iniciar';
    b.push(btn(corriendo ? 'Reiniciar' : 'Iniciar', s.id + ':svc', async () => {
      const ok = await confirmar({
        titulo: `${corriendo ? 'Reiniciar' : 'Iniciar'} ${s.nombre}`, uac: true, boton: corriendo ? 'Reiniciar' : 'Iniciar',
        cuerpo: h('div', {},
          h('p', { text: corriendo ? `Se reinicia el servicio de Windows de ${s.nombre}. Durante unos segundos no responde.` : `Se inicia el servicio de Windows de ${s.nombre}.` }),
          s.id === 'jellyfin' && corriendo && enCasa ? h('p', { class: 'cuenta-mal', text: `Ahora hay ${plural(enCasa, 'persona mirando', 'personas mirando')}: se le${enCasa > 1 ? 's' : ''} va a cortar.` }) : null)
      });
      if (ok) ejecutar(s.id + ':svc', { tipo: 'servicio', objetivo: s.id, op }, `${s.nombre}: ${corriendo ? 'reiniciar' : 'iniciar'}`);
    }, !corriendo));
    if (!s.cuentaOk && s.estado !== 'NoExiste') b.push(btn('Corregir cuenta', s.id + ':cuenta', () => corregirCuenta(s.id, s.nombre, s.cuenta, s.cuentaEsperada), true));
  }
  if (s.tipo === 'tarea') {
    const corriendo = s.estado === 'Running';
    b.push(btn(corriendo ? 'Reiniciar' : 'Iniciar', 'qbit', async () => {
      const ok = await confirmar({
        titulo: `${corriendo ? 'Reiniciar' : 'Iniciar'} qBittorrent`, uac: true, boton: corriendo ? 'Reiniciar' : 'Iniciar',
        cuerpo: h('p', { text: corriendo
          ? `Se le pide a qBittorrent que se cierre ordenadamente (guarda el estado de los torrents) y se vuelve a abrir con la tarea "${cfg.tareaQbit}". Las descargas se pausan unos segundos.`
          : `Se inicia la tarea "${cfg.tareaQbit}", que lo abre con el usuario restringido ${cfg.usuarioDescargas}.` })
      });
      if (ok) ejecutar('qbit', { tipo: 'tarea', objetivo: 'qbittorrent', op: corriendo ? 'reiniciar' : 'iniciar' }, `qBittorrent: ${corriendo ? 'reiniciar' : 'iniciar'}`);
    }, !corriendo));
    if (s.propias && s.propias.length) b.push(btn('Cerrar copia personal', 'qbit-copia', cerrarCopiaQbit, true));
  }
  if (s.tipo === 'tunel' && s.estado !== 'Running') b.push(btn('Iniciar', s.id, () => iniciarTunel(s.id, s.nombre), true));
  if (s.tipo === 'contenedor') {
    if (!s.docker) b.push(btn('Abrir Docker Desktop', 'docker', abrirDocker, true));
    else if (s.motor && s.contenedor !== 'running') b.push(btn('Iniciar', s.id, () => contenedor(s.id, 'iniciar'), true));
    else if (s.motor) b.push(btn('Reiniciar', s.id, () => contenedor(s.id, 'reiniciar'), s.responde === false));
  }
  if (s.web) b.push(h('a', { class: 'btn btn-chico btn-link', href: s.web, target: '_blank', rel: 'noopener', text: 'Abrir' }));
  return h('div', { class: 'acciones' }, b);
}
async function corregirCuenta(id, nombre, actual, esperada) {
  const ok = await confirmar({
    titulo: `Corregir la cuenta de ${nombre}`, uac: true, boton: 'Corregir y reiniciar',
    cuerpo: h('div', {},
      h('p', {}, `${nombre} corre como `, h('b', { text: actual || '(desconocida)' }), '. Se cambia a ', h('b', { text: esperada }), ' y se reinicia.'),
      h('p', { class: 'tenue', text: `Es la cuenta con permisos limitados que se eligió al instalar: solo puede tocar ${cfg.raiz || 'la carpeta del servidor'}, no tus documentos. A veces un instalador la vuelve a cambiar al actualizar.` }))
  });
  if (ok) ejecutar(id + ':cuenta', { tipo: 'servicio', objetivo: id, op: 'cuenta' }, `${nombre}: corregir cuenta`);
}
async function cerrarCopiaQbit() {
  const ok = await confirmar({
    titulo: 'Cerrar la copia personal de qBittorrent', boton: 'Cerrarla',
    cuerpo: h('div', {},
      h('p', { text: 'Hay una copia de qBittorrent abierta con tu usuario (probablemente desde el menú Inicio).' }),
      h('p', { class: 'tenue', text: `Esa copia no usa la configuración del servidor y descarga con tus permisos, así que puede tocar tus documentos. La copia buena es la que corre como ${cfg.usuarioDescargas}.` }))
  });
  if (ok) ejecutar('qbit-copia', { tipo: 'qbit-cerrar-copia' }, 'Cerrar la copia personal de qBittorrent');
}
async function iniciarTunel(id, nombre) {
  const ok = await confirmar({
    titulo: `Iniciar ${nombre}`, uac: true, boton: 'Iniciar',
    cuerpo: h('div', {},
      h('p', { text: `Se inicia la tarea programada "${id.replace('zrok-', 'zrok ').replace(/\b\w/g, c => c.toUpperCase()).replace('Zrok', 'zrok')}".` }),
      h('p', { class: 'tenue', text: 'Los túneles no se reinician a la fuerza: si se cortan mal dejan el nombre ocupado y los reintentos rápidos dan error 429. Si el proceso está corriendo pero no responde, conviene esperar unos minutos: se reconecta solo.' }))
  });
  if (ok) ejecutar(id, { tipo: 'tarea', objetivo: id, op: 'iniciar' }, `${nombre}: iniciar`);
}
const CONTENEDORES = {
  seerr: {
    nombre: 'Seerr',
    iniciar: 'Se inicia el contenedor seerr en Docker Desktop.',
    reiniciar: 'Se reinicia el contenedor seerr en Docker Desktop. La página de pedidos no responde durante unos 20 segundos.'
  },
  flaresolverr: {
    nombre: 'FlareSolverr',
    iniciar: 'Se inicia el contenedor flaresolverr en Docker Desktop.',
    reiniciar: 'Se reinicia el contenedor flaresolverr (unos 10 segundos) con su misma configuración: no se cambia nada de cómo está armado. Sirve cuando su Chrome interno se cuelga ("cannot connect to chrome"). Mientras reinicia, fallan las búsquedas en los indexadores que dependen de él.'
  }
};
async function contenedor(id, op) {
  const c = CONTENEDORES[id];
  const usan = id === 'flaresolverr' && datos.diag ? ((datos.diag.chequeos.find(x => x.id === 'flaresolverr') || {}).datos || {}).usan || [] : [];
  const ok = await confirmar({
    titulo: `${op === 'iniciar' ? 'Iniciar' : 'Reiniciar'} ${c.nombre}`, boton: op === 'iniciar' ? 'Iniciar' : 'Reiniciar',
    cuerpo: h('div', {}, h('p', { text: c[op] }), usan.length ? h('p', { class: 'tenue', text: 'Indexadores que lo usan: ' + usan.join(', ') + '.' }) : null)
  });
  if (ok) ejecutar(id, { tipo: 'contenedor', objetivo: id, op }, `${c.nombre}: ${op}`);
}
const seerr = op => contenedor('seerr', op);
async function abrirDocker() {
  const ok = await confirmar({
    titulo: 'Abrir Docker Desktop', boton: 'Abrir',
    cuerpo: h('p', { text: 'Se abre Docker Desktop con tu usuario. Tarda uno o dos minutos en arrancar; después el contenedor de Seerr se levanta solo.' })
  });
  if (ok) ejecutar('docker', { tipo: 'docker-abrir' }, 'Abrir Docker Desktop');
}

function renderServicios() {
  const e = datos.estado;
  if (!e) return;
  const ver = (datos.salud && datos.salud.versiones) || {};
  const verDe = { jellyfin: ver.jellyfin, radarr: ver.radarr, sonarr: ver.sonarr, prowlarr: ver.prowlarr, bazarr: ver.bazarr, qbittorrent: ver.qbittorrent, seerr: ver.seerr };
  const filas = e.servicios.map(s => {
    const [nivel, texto] = estadoServicio(s);
    let cuenta;
    if (s.tipo === 'tarea') cuenta = s.cuentaOk ? h('span', { text: s.cuentaEsperada, title: 'Corre como otro usuario (sin admin no se puede leer cuál, pero no es el tuyo)' }) : h('span', { class: 'cuenta-mal', text: `tu usuario (debería ser ${s.cuentaEsperada})` });
    else if (s.tipo === 'contenedor') cuenta = h('span', { class: 'tenue', text: 'Docker (tu sesión)' });
    else if (s.tipo === 'tunel') cuenta = h('span', { text: 'LocalService' });
    else cuenta = s.cuentaOk ? h('span', { text: cuentaCorta(s.cuenta) }) : h('span', { class: 'cuenta-mal', text: s.estado === 'NoExiste' ? '—' : `${cuentaCorta(s.cuenta)} (debería ser ${cuentaCorta(s.cuentaEsperada)})` });
    const tipo = { servicio: 'servicio', tarea: 'tarea', tunel: 'túnel', contenedor: 'Docker' }[s.tipo];
    return h('tr', {},
      h('td', {}, h('div', { class: 'nombre-app', text: s.nombre.replace(/^Tunel/, 'Túnel') }), h('div', { class: 'tenue chico', text: tipo + (verDe[s.id] ? ' · ' + String(verDe[s.id]).replace(/^v/, '') : '') })),
      h('td', {}, h('span', { class: 'estado-celda' }, h('span', { class: 'punto ' + nivel }), texto),
        s.tipo === 'tunel' && s.ms ? h('div', { class: 'tenue chico', text: `${nf1.format(s.ms / 1000)} s desde internet` }) : null),
      h('td', {}, cuenta),
      h('td', { class: 'acc' }, botonesServicio(s)));
  });
  poner($('#servicios'), h('div', { class: 'tabla-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, h('th', { text: 'App' }), h('th', { text: 'Estado' }), h('th', { text: 'Cuenta' }), h('th', { class: 'n', text: '' }))),
    h('tbody', {}, filas))));
}

// ---------- descargas ----------
const ESTADOS_TORRENT = {
  downloading: 'Bajando', forcedDL: 'Bajando (forzado)', metaDL: 'Buscando datos', forcedMetaDL: 'Buscando datos', stalledDL: 'Trabada', queuedDL: 'En cola',
  pausedDL: 'Pausada', stoppedDL: 'Detenida', checkingDL: 'Verificando', allocating: 'Reservando espacio', moving: 'Moviendo', error: 'Error', missingFiles: 'Faltan archivos'
};
function traducirCola(m) {
  if (/stalled with no connections/i.test(m)) return 'Trabada: nadie la está compartiendo ahora (0 conexiones).';
  if (/Manual Import required/i.test(m)) return 'Hay que importarla a mano: Radarr/Sonarr → Actividad → Cola → icono de importar.';
  if (/No files found are eligible for import/i.test(m)) return 'No hay archivos de video para importar (puede ser un release falso o solo extras).';
  if (/Not an upgrade/i.test(m)) return 'No mejora lo que ya hay: no se importa.';
  if (/sample/i.test(m)) return 'Solo trae una muestra (sample).';
  return m;
}
function renderDescargas() {
  const e = datos.estado;
  if (!e) return;
  const d = e.descargas;
  $('#descargas-nota').textContent = d.ok ? `${plural(d.total, 'torrent', 'torrents')} en qBittorrent · ${d.conexion === 'connected' ? 'conectado' : d.conexion === 'firewalled' ? 'conectado sin puerto abierto (CGNAT)' : 'sin conexión'}` : 'qBittorrent no responde';
  if (!d.ok) { poner($('#descargas'), h('p', { class: 'vacio', text: 'No se pudo leer qBittorrent. Mirá su estado en Servicios.' })); return; }
  if (!d.activas.length) {
    poner($('#descargas'), h('p', { class: 'vacio', text: `No hay nada bajando. qBittorrent está compartiendo ${plural(d.grupos.compartiendo || 0, 'torrent', 'torrents')} (los archivos ya están en la biblioteca).` }));
    return;
  }
  const filas = d.activas.map(t => {
    const trabada = t.estado === 'stalledDL';
    const msgs = (t.cola && t.cola.mensajes) || [];
    return h('tr', {},
      h('td', {}, h('div', { class: 'recorte', text: t.nombre, title: t.nombre }),
        h('div', { class: 'tenue chico' }, [t.categoria === 'radarr' ? 'Película' : t.categoria === 'sonarr' ? 'Serie' : t.categoria || '—', bytes(t.tamano)].join(' · ')),
        msgs.map(m => h('div', { class: 'chico', style: { color: 'var(--aviso)' }, text: traducirCola(m) }))),
      h('td', {}, h('span', { class: 'estado-celda' }, h('span', { class: 'punto ' + (trabada ? 'aviso' : /error|missing/i.test(t.estado) ? 'falla' : 'ok') }), ESTADOS_TORRENT[t.estado] || t.estado)),
      h('td', {}, h('div', { class: 'progreso' + (trabada ? ' trabada' : '') }, h('div', { style: { width: t.progreso + '%' } })), h('div', { class: 'tenue chico', text: nf1.format(t.progreso) + ' %' })),
      h('td', { class: 'n' }, vel(t.bajada)),
      h('td', { class: 'n', title: 'conectadas / en total en la red' }, `${t.semillas} / ${t.semillasTotal}`),
      h('td', { class: 'n' }, duracion(t.eta)));
  });
  poner($('#descargas'), h('div', { class: 'tabla-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['Nombre', 'Estado', 'Progreso'].map(x => h('th', { text: x })), h('th', { class: 'n', text: 'Bajada' }), h('th', { class: 'n', text: 'Semillas' }), h('th', { class: 'n', text: 'Falta' }))),
    h('tbody', {}, filas))));
}

// ---------- avisos de salud ----------
const APPS = { radarr: 'Radarr', sonarr: 'Sonarr', prowlarr: 'Prowlarr', bazarr: 'Bazarr', jellyfin: 'Jellyfin', seerr: 'Seerr', qbittorrent: 'qBittorrent', mantenimiento: 'Mantenimiento' };
const FUENTES = {
  IndexerStatusCheck: 'Indexadores sin funcionar por fallas',
  IndexerLongTermStatusCheck: 'Indexadores sin funcionar hace más de 6 horas',
  IndexerRssCheck: 'Ningún indexador tiene RSS activo',
  IndexerSearchCheck: 'Ningún indexador tiene búsqueda activa',
  DownloadClientCheck: 'No se puede conectar con el cliente de descarga',
  DownloadClientStatusCheck: 'Clientes de descarga sin funcionar por fallas',
  ApplicationStatusCheck: 'Apps sin sincronizar por fallas',
  ApplicationLongTermStatusCheck: 'Apps sin sincronizar hace más de 6 horas',
  RootFolderCheck: 'Falta una carpeta raíz',
  ImportMechanismCheck: 'Problema con el mecanismo de importación',
  UpdateCheck: 'No se puede actualizar sola',
  RemovedSeriesCheck: 'Hay series que se borraron de TheTVDB',
  RemovedMovieCheck: 'Hay películas que se borraron de TMDb',
  ProxyCheck: 'Problema con el proxy',
  SystemTimeCheck: 'La hora del sistema está desfasada'
};
function textoCodigo(it) {
  const d = it.datos || {};
  switch (it.codigo) {
    case 'jf-reinicio': return ['Jellyfin necesita reiniciarse para aplicar cambios', 'Reinicialo desde Servicios cuando nadie esté mirando.'];
    case 'jf-actualizacion': return ['Hay una versión nueva de Jellyfin', 'La instala el mantenimiento de los domingos.'];
    case 'jf-logins': return [`${plural(d.cantidad, 'intento fallido', 'intentos fallidos')} de inicio de sesión en 24 h`,
      (cfg.zrok ? 'Jellyfin y Seerr están en internet por zrok. ' : 'Seerr usa el mismo login que Jellyfin. ') + 'Último: ' + fecha(d.ultimo) + (d.ips && d.ips.length ? ' · IP: ' + d.ips.map(x => `${x.ip} (${x.veces})`).join(', ') : '') + '. Después de 5 intentos, Jellyfin bloquea el usuario.'];
    case 'seerr-reinicio': return ['Seerr necesita reiniciarse', 'Reinicialo desde Servicios.'];
    case 'seerr-actualizacion': return ['Hay una versión nueva de Seerr', 'La instala el mantenimiento de los domingos.'];
    case 'bazarr-proveedor': return [`Proveedor de subtítulos ${d.nombre}: ${d.estado}`, d.reintento && d.reintento !== '-' ? `Bazarr lo reintenta: ${d.reintento}` : ''];
    case 'mant-viejo': return ['El mantenimiento automático no corre hace más de 8 días', `Último: ${fecha(d.fecha)}. Revisá las tareas "Media - Arranque" y "Media - Mantenimiento".`];
    case 'mant-falla': return [`Mantenimiento: falló "${d.que}"`, `${d.detalle || ''} (${fecha(d.fecha)})`];
    case 'mant-nunca': return ['El mantenimiento automático nunca dejó un resumen', 'Ejecutá Instalar-Mantenimiento.bat.'];
  }
  return [it.mensaje, ''];
}
function renderSalud() {
  const s = datos.salud;
  if (!s) return;
  const bloques = [];
  const items = s.items.filter(i => i.nivel !== 'ok');
  const indexados = new Set(['IndexerStatusCheck', 'IndexerLongTermStatusCheck']);
  if (s.caidas.length) bloques.push(h('div', { class: 'aviso-item' }, h('span', { class: 'punto falla' }),
    h('div', {}, h('div', { class: 'titulo', text: 'No responden: ' + s.caidas.map(c => APPS[c] || c).join(', ') }), h('div', { class: 'det', text: 'No se pudieron leer sus avisos. Mirá su estado en Servicios.' })), h('span')));
  for (const it of items) {
    let [titulo, det] = it.codigo ? textoCodigo(it) : [it.mensaje, ''];
    if (!it.codigo && FUENTES[it.fuente]) {
      const resto = it.mensaje.includes(':') ? it.mensaje.slice(it.mensaje.indexOf(':') + 1).trim() : '';
      titulo = FUENTES[it.fuente]; det = resto;
      if (indexados.has(it.fuente)) det += (det ? ' · ' : '') + 'Se pueden reintentar abajo.';
    }
    const nivel = it.nivel === 'error' ? 'falla' : it.nivel === 'warning' ? 'aviso' : 'info';
    bloques.push(h('div', { class: 'aviso-item', title: it.mensaje || '' },
      h('span', { class: 'punto ' + nivel }),
      h('div', {}, h('div', { class: 'titulo' }, h('span', { class: 'etiqueta', text: APPS[it.app] || it.app }), ' ', titulo), det ? h('div', { class: 'det', text: det }) : null),
      it.wiki ? h('a', { class: 'btn btn-chico btn-link', href: it.wiki, target: '_blank', rel: 'noopener', text: 'Ayuda' }) : h('span')));
  }
  const cuerpo = [];
  cuerpo.push(bloques.length ? h('div', { class: 'lista' }, bloques) : h('div', { class: 'todo-ok' }, h('span', { class: 'punto ok' }), 'Ninguna app reporta problemas.'));

  if (s.indexadores.length) {
    // Un mismo sitio aparece en Prowlarr, Radarr y Sonarr: se agrupa por sitio
    const grupos = new Map();
    for (const ix of s.indexadores) {
      const base = ix.nombre.replace(/\s*\(Prowlarr\)$/, '');
      if (!grupos.has(base)) grupos.set(base, []);
      grupos.get(base).push(ix);
    }
    cuerpo.push(h('div', { class: 'subtitulo', text: `Indexadores en pausa (${grupos.size})` }));
    cuerpo.push(h('div', { class: 'lista' }, [...grupos].map(([base, ixs]) => {
      const clave = 'idx:' + base;
      const p = ixs.find(x => x.hasta);
      const det = [ixs.map(x => APPS[x.app]).join(', '), p ? `en pausa hasta ${fecha(p.hasta)} · falla desde ${fecha(p.desde)}` : 'sin funcionar hace más de 6 horas'].join(' · ');
      return h('div', { class: 'aviso-item' }, h('span', { class: 'punto aviso' }),
        h('div', {}, h('div', { class: 'titulo', text: base }), h('div', { class: 'det', text: det })),
        h('button', { class: 'btn btn-chico', text: ocupados.has(clave) ? 'Probando…' : 'Reintentar', disabled: ocupados.has(clave) || null, onclick: () => reintentarIndexador(base, ixs) }));
    })));
    cuerpo.push(h('p', { class: 'tenue chico', style: { marginTop: '6px' }, text: 'Reintentar = probar el indexador ahora. Si responde, sale de la pausa; si no, la pausa se alarga. Un sitio que falla varios días seguidos conviene reemplazarlo en Prowlarr.' }));
  }
  if (s.cola.length) {
    cuerpo.push(h('div', { class: 'subtitulo', text: 'Descargas con problemas' }));
    cuerpo.push(h('div', { class: 'lista' }, s.cola.map(c => h('div', { class: 'aviso-item' },
      h('span', { class: 'punto ' + (c.nivel === 'error' ? 'falla' : 'aviso') }),
      h('div', {}, h('div', { class: 'titulo' }, h('span', { class: 'etiqueta', text: APPS[c.app] }), ' ', h('span', { class: 'recorte', style: { display: 'inline-block', maxWidth: '100%', verticalAlign: 'bottom' }, text: c.titulo, title: c.titulo })),
        c.mensajes.map(m => h('div', { class: 'det', text: traducirCola(m) }))),
      cfg.web[c.app] ? h('a', { class: 'btn btn-chico btn-link', href: cfg.web[c.app] + '/activity/queue', target: '_blank', rel: 'noopener', text: 'Ver cola' }) : h('span')))));
  }
  poner($('#salud'), cuerpo);
  $('#salud-nota').textContent = `Lo que reporta cada app · revisado ${hace(s.generado)}`;
}
async function reintentarIndexador(base, ixs) {
  const apps = ixs.map(x => APPS[x.app]).join(', ');
  const ok = await confirmar({
    titulo: `Reintentar ${base}`, boton: 'Probar ahora',
    cuerpo: h('div', {},
      h('p', { text: `Se prueba ${base} en ${apps}.` }),
      h('p', { class: 'tenue', text: 'Primero en Prowlarr, que es el que llega al sitio. Si responde, sale de la pausa. Si no responde, cuenta como una falla más y la pausa se alarga, así que no conviene reintentar seguido.' }))
  });
  if (!ok) return;
  const clave = 'idx:' + base;
  ocupados.add(clave); renderSalud();
  const orden = [...ixs].sort((a, b) => (a.app === 'prowlarr' ? -1 : 0) - (b.app === 'prowlarr' ? -1 : 0));
  const bien = [];
  for (const ix of orden) {
    let r;
    try { r = await accion({ tipo: 'indexador', app: ix.app, id: ix.id }); } catch (e) { r = { ok: false, mensaje: e.message }; }
    if (!r.ok) { toast('error', `${base}: sigue fallando (${APPS[ix.app]})`, r.mensaje || ''); break; }
    bien.push(APPS[ix.app]);
  }
  if (bien.length === orden.length) toast('ok', `${base}: responde`, `Salió de la pausa en ${bien.join(', ')}.`);
  ocupados.delete(clave);
  cargarSalud(true);
}

// ---------- diagnostico ----------
const lista = arr => h('ul', {}, arr.map(x => h('li', {}, x)));
const DIAG = {
  cuentas: {
    titulo: 'Cuenta de cada servicio',
    detalle: d => (!d.mal.length && !d.faltan.length) ? 'Todos corren con su cuenta limitada (LocalService o NetworkService).'
      : [d.mal.length ? lista(d.mal.map(m => `${m.nombre}: corre como ${cuentaCorta(m.actual)}, debería ser ${cuentaCorta(m.esperada)}`)) : null,
        d.faltan.length ? lista(d.faltan.map(n => `${n}: no está instalado como servicio`)) : null],
    antes: 'Los instaladores de Radarr, Sonarr, Prowlarr y Bazarr pueden volver a poner la cuenta original al actualizar (Bazarr se había instalado como LocalSystem, con control total de la PC). Sonarr una vez quedó instalado sin servicio.',
    hacer: d => d.faltan.includes('Sonarr') ? 'Si falta Sonarr: ejecutar C:\\ProgramData\\Sonarr\\bin\\ServiceInstall.exe como administrador. Para las cuentas, usar el botón.' : 'Corregir la cuenta con el botón: el panel la cambia y reinicia el servicio.',
    acciones: d => d.mal.map(m => ['Corregir cuenta de ' + m.nombre, () => corregirCuenta(m.id, m.nombre, m.actual, m.esperada)])
  },
  puertos: {
    titulo: 'Apps internas cerradas a la red',
    detalle: d => (!d.expuestos.length && !d.sinEscuchar.length) ? 'Radarr, Sonarr, Prowlarr, qBittorrent y Bazarr escuchan solo en 127.0.0.1.'
      : [d.expuestos.length ? lista(d.expuestos.map(x => `${x.app} escucha en ${x.direccion}:${x.puerto}: se puede entrar desde la red`)) : null,
        d.sinEscuchar.length ? h('p', { text: 'No están escuchando (¿detenidas?): ' + d.sinEscuchar.join(', ') }) : null],
    antes: 'Radarr, Sonarr y Prowlarr estaban accesibles desde la red por las reglas "NzbDrone" de sus instaladores. Se cerraron con Bind Address = 127.0.0.1; Sonarr y Prowlarr exigen además completar Allowed Hosts.',
    hacer: () => 'En la app: Settings → General → Bind Address = 127.0.0.1. En Sonarr y Prowlarr, Allowed Hosts = localhost,127.0.0.1,host.docker.internal. Después, reiniciar el servicio.'
  },
  'qbit-copia': {
    get titulo() { return `qBittorrent corre con el usuario ${cfg.usuarioDescargas}`; },
    detalle: d => d.propias.length ? `Hay ${plural(d.propias.length, 'copia', 'copias')} de qBittorrent abiertas con tu usuario.` : 'No hay copias abiertas con tu usuario.',
    antes: 'Si se abre qBittorrent desde el menú Inicio, arranca otra copia con tu usuario y sin la configuración del servidor: descarga con tus permisos y puede tocar tus documentos.',
    hacer: () => `Cerrar esa copia y manejar qBittorrent solo desde ${cfg.web.qbittorrent || 'su Web UI'}.`,
    acciones: d => d.propias.length ? [['Cerrar la copia personal', cerrarCopiaQbit]] : []
  },
  'qbit-conexion': {
    titulo: 'Conexión de qBittorrent',
    detalle: d => d.estado === 'connected' ? `Conectado (${nf0.format(d.dht)} nodos DHT).`
      : d.estado === 'firewalled' ? 'Conectado, pero sin puerto abierto desde internet. Es lo esperable con el CGNAT del proveedor: baja igual, con menos pares.'
        : 'qBittorrent no tiene conexión a internet.',
    antes: 'El proveedor usa CGNAT: no se pueden abrir puertos en el router.',
    hacer: d => d.estado === 'disconnected' ? 'Revisar la conexión de la PC y reiniciar qBittorrent desde Servicios.' : 'Nada.'
  },
  'clientes-descarga': {
    titulo: 'Radarr y Sonarr llegan a qBittorrent',
    detalle: d => d.fallas.length ? lista(d.fallas.map(f => `${APPS[f.app]} → ${f.nombre}: ${f.error}`)) : 'La prueba del cliente de descarga da OK en los dos.',
    antes: 'Radarr mostró "All download clients are unavailable" mientras qBittorrent estuvo apagado: pausa el cliente unos minutos y después se recupera solo.',
    hacer: () => 'Si qBittorrent funciona y esto sigue fallando: en Radarr/Sonarr → Settings → Download Clients, el host tiene que ser 127.0.0.1 (no localhost: Windows a veces lo resuelve como IPv6 y la Web UI solo escucha en IPv4).'
  },
  'prowlarr-apps': {
    titulo: 'Prowlarr sincroniza con Radarr y Sonarr',
    detalle: d => d.fallas.length ? lista(d.fallas.map(f => `${f.nombre}: ${f.error}`)) : `La prueba da OK con ${d.apps.join(' y ')}.`,
    antes: 'Prowlarr es el único lugar donde se cargan indexadores. Si pierde la conexión con Radarr o Sonarr, no les llegan los indexadores nuevos.',
    hacer: () => 'Prowlarr → Settings → Apps: probar cada app y revisar la API key y la dirección (127.0.0.1).'
  },
  'seerr-conexiones': {
    titulo: 'Seerr llega a Radarr, Sonarr y Jellyfin',
    detalle: d => !d.docker ? 'Docker Desktop no está abierto: Seerr no funciona.'
      : !d.motor ? 'Docker Desktop está arrancando (o no responde).'
        : d.contenedor !== 'running' ? `El contenedor seerr está "${d.contenedor}".`
          : d.destinos.every(x => x.ok) ? 'Desde el contenedor responden Radarr, Sonarr y Jellyfin (por host.docker.internal).'
            : lista(d.destinos.map(x => `${x.nombre}: ${x.ok ? 'responde' : 'NO responde'}`)),
    antes: 'Docker Desktop arranca solo cuando alguien inicia sesión en Windows: después de un corte de luz, Seerr queda caído hasta que alguien entra. Seerr llega a las apps por host.docker.internal; si Sonarr o Prowlarr pierden "Allowed Hosts", se corta.',
    hacer: d => (!d.docker || d.contenedor !== 'running') ? 'Abrir Docker Desktop o iniciar el contenedor con el botón.' : 'Revisar que Allowed Hosts incluya host.docker.internal en la app que no responde.',
    acciones: d => !d.docker ? [['Abrir Docker Desktop', abrirDocker]] : (d.motor && d.contenedor !== 'running') ? [['Iniciar Seerr', () => seerr('iniciar')]] : []
  },
  flaresolverr: {
    titulo: 'FlareSolverr (sitios con Cloudflare)',
    detalle: d => !d.existe ? 'No hay contenedor flaresolverr.'
      : !d.corriendo ? `El contenedor flaresolverr no está corriendo${d.contenedor ? ' (' + d.contenedor + ')' : ''}.`
        : [h('p', { text: `${d.responde ? 'Responde' : 'NO responde'} · corriendo desde ${fecha(d.desde)}.` }),
          lista([`Última hora: ${d.h1.ok} pedidos resueltos, ${d.h1.error} fallidos${d.h1.chrome ? `, ${d.h1.chrome} con el Chrome caído` : ''}`,
            `Últimas 24 h: ${d.h24.ok} resueltos, ${d.h24.error} fallidos${d.h24.chrome ? `, ${d.h24.chrome} con el Chrome caído` : ''}`]),
          d.usan.length ? h('p', { class: 'tenue chico', text: 'Lo usan: ' + d.usan.join(', ') }) : null],
    antes: 'Los indexadores con desafío de Cloudflare (dan 403 si se entra directo) solo funcionan a través de FlareSolverr. Su Chrome interno se colgó ("cannot connect to chrome") y esos indexadores quedaron en pausa en Prowlarr, Radarr y Sonarr.',
    hacer: d => !d.existe ? 'Nada.' : 'Reiniciarlo con el botón. Si vuelve a colgarse seguido, conviene actualizar la imagen o desactivar en Prowlarr los indexadores que dependen de él. Después de reiniciarlo, usar "Reintentar" en los indexadores en pausa.',
    acciones: d => !d.existe ? [] : [[d.corriendo ? 'Reiniciar FlareSolverr' : 'Iniciar FlareSolverr', () => contenedor('flaresolverr', d.corriendo ? 'reiniciar' : 'iniciar')]]
  },
  minseeders: {
    titulo: 'Mínimo de seeders en Radarr',
    detalle: d => d.bajos.length ? lista(d.bajos.map(b => `${b.nombre}: ${b.valor}`)) : 'Todos los indexadores de Radarr piden al menos 5 seeders.',
    antes: 'Prowlarr crea los indexadores nuevos en Radarr con 3 seeders mínimos (sincroniza en modo "solo agregar", así que no pisa el cambio). Con pocos seeders las películas se traban.',
    hacer: () => 'Subirlos a 5 con el botón.',
    acciones: d => d.bajos.length ? [['Subir a 5', async () => {
      const ok = await confirmar({ titulo: 'Subir el mínimo de seeders a 5', boton: 'Subir a 5', cuerpo: h('div', {}, h('p', { text: 'Se cambia en Radarr:' }), lista(d.bajos.map(b => `${b.nombre}: de ${b.valor} a 5`))) });
      if (ok) ejecutar('minseeders', { tipo: 'minseeders' }, 'Mínimo de seeders en Radarr', { alTerminar: r => r.cambiados && toast('ok', 'Cambiados', r.cambiados.join(', ')) });
    }]] : []
  },
  'jellyfin-red': {
    titulo: 'Jellyfin distingue la casa de afuera',
    detalle: d => !d.key ? `La API key de Jellyfin no funciona (HTTP ${d.codigo || '?'}).`
      : d.faltan.length ? `Falta en la configuración de red: ${d.faltan.join(', ')}.`
        : !d.bitrate ? `No hay límite de bitrate para afuera: alguien remoto puede agotar la subida de la casa${cfg.zrok ? ' y los 5 GB diarios de zrok' : ''}.`
          : `Redes LAN${cfg.zrok ? ', proxies de zrok' : ''} y límite remoto de ${nf1.format(d.bitrate / 1e6)} Mbps en su lugar.`,
    antes: 'Desde afuera Jellyfin veía las conexiones como locales y no aplicaba el límite: faltaban las redes LAN o los proxies conocidos (10.0.0.0/8, los de zrok), o no se había tocado Guardar.',
    hacer: d => !d.key ? `Crear una key en Jellyfin → Panel de control → Claves de API y guardarla en ${cfg.archivoKeyJellyfin}. Va en el encabezado Authorization (X-Emby-Token ya no anda).`
      : `Jellyfin → Panel de control → Redes: LAN = ${[cfg.redLocal, '127.0.0.0/8'].filter(Boolean).join(', ')}` +
        (cfg.zrok ? ' · Proxies conocidos = 127.0.0.1, 10.0.0.0/8' : '') + ' · Reproducción → límite por internet 4 Mbps. Guardar y reiniciar Jellyfin.'
  },
  'ip-fija': {
    get titulo() { return cfg.ipServidor ? `IP fija ${cfg.ipServidor}` : 'IP fija'; },
    detalle: d => !d.esperada ? ['No hay IP fija en config.local.json (IpServidor). Ahora la PC tiene:', lista(d.actuales.map(a => `${a.ip} (${a.placa}, ${a.origen})`))]
      : d.origen === 'Manual' ? `La PC tiene ${d.esperada} fija.`
        : d.origen ? `Tiene ${d.esperada}, pero por DHCP: puede cambiar.`
          : [`La PC no tiene ${d.esperada}. Ahora tiene:`, lista(d.actuales.map(a => `${a.ip} (${a.placa}, ${a.origen})`))],
    antes: 'La IP se fijó en la PC porque no hay acceso al router del proveedor. Seerr ("Ver en Jellyfin") y las TVs apuntan a esa dirección.',
    hacer: d => !d.esperada ? 'Cargar IpServidor en config.local.json para que el panel la controle.'
      : `Si cambió: volver a fijarla como administrador. Si aparece un conflicto de IP, reservar ${d.esperada} en el DHCP del router cuando haya acceso.`
  },
  dns: {
    titulo: 'DNS',
    detalle: d => !d.resuelve ? `No resuelve ${d.nombre} (servidores: ${d.servidores.join(', ') || 'ninguno'}).`
      : `Resuelve en ${d.ms} ms con ${d.servidores.join(' y ')}${d.servidores.length < 2 ? ' (falta un secundario)' : ''}.`,
    antes: 'El DNS del router a veces tarda 3-7 s, y zrok registró errores "no such host" al reconectarse. Por eso se agregó 1.1.1.1 como secundario.',
    hacer: () => 'Si se repite: poner 1.1.1.1 como DNS primario en la placa Wi-Fi.'
  },
  zrok: {
    titulo: 'Acceso desde afuera (zrok)',
    detalle: d => d.habilitado === false ? 'Deshabilitado en config.local.json: no hay túneles para revisar.' : [
      lista(d.tuneles.map(t => h('span', {}, h('b', { text: t.app }), t.ok ? ` responde (${nf1.format(t.ms / 1000)} s)` : ` NO responde${t.codigo ? ' (HTTP ' + t.codigo + ')' : ''}`,
        h('span', { class: 'tenue', text: ` · en 24 h: ${t.errores} errores${t.dns ? `, ${t.dns} de DNS` : ''}${t.r429 ? `, ${t.r429} por 429` : ''}` })))),
      h('p', { class: 'tenue chico', text: `${plural(d.procesos, 'proceso', 'procesos')} zrok2 corriendo.` })],
    antes: 'Si se mata zrok a la fuerza sin borrar el share, el nombre queda ocupado; y los reintentos rápidos provocan error 429 por varios minutos. Los scripts de los túneles ya borran shares huérfanos y esperan entre intentos. Los errores de DNS vienen del router.',
    hacer: d => d.tuneles.some(t => !t.ok) ? 'Esperar unos minutos: se reconecta solo. Si no hay procesos zrok2, iniciar la tarea. No reiniciarlo en loop.' : 'Nada: los errores sueltos de reconexión son normales.',
    acciones: d => d.procesos < d.tuneles.length ? d.tuneles.filter(t => !t.ok).map(t => ['Iniciar túnel ' + t.app, () => iniciarTunel('zrok-' + t.app.toLowerCase(), 'Túnel ' + t.app)]) : []
  },
  mantenimiento: {
    titulo: 'Mantenimiento automático',
    detalle: d => !d.existe ? 'Nunca dejó un resumen.'
      : d.fallas.length ? ['Último chequeo ' + fecha(d.fecha) + ' con fallas:', lista(d.fallas.map(f => `${f.que}: ${f.detalle}`))]
        : `Último chequeo ${fecha(d.fecha)} (${d.modo === 'Completo' ? 'completo' : 'de salud'}), sin fallas.`,
    antes: 'Las tareas SYSTEM "Media - Arranque" (al iniciar Windows) y "Media - Mantenimiento" (domingos 4:00) revisan, levantan lo caído y actualizan Jellyfin, Bazarr, qBittorrent y Seerr.',
    hacer: () => 'Si no corre: ejecutar Instalar-Mantenimiento.bat. Logs en C:\\ProgramData\\MediaStack\\logs.'
  },
  'bazarr-proveedores': {
    titulo: 'Subtítulos (Bazarr)',
    detalle: d => d.proveedores.length ? lista(d.proveedores.map(p => `${p.nombre}: ${p.estado === 'Good' ? 'OK' : p.estado}${p.reintento && p.reintento !== '-' ? ' (reintenta ' + p.reintento + ')' : ''}`)) : 'No hay proveedores configurados.',
    antes: 'En Bazarr 1.6 ya no existen Subdivx ni Podnapisi: para español latino hace falta la cuenta de OpenSubtitles.com. Si se pasa del límite diario, Bazarr la pausa un rato.',
    hacer: () => 'Bazarr → Settings → Providers: revisar la cuenta de OpenSubtitles.com.'
  },
  disco: {
    titulo: 'Espacio en D:',
    detalle: d => d.pct >= d.umbral ? `${d.pct}% usado: pasó el ${d.umbral}%, conviene borrar candidatos.` : `${d.pct}% usado (${bytes(d.libre)} libres): no hace falta borrar.`,
    antes: 'Las mejoras automáticas pueden volver a bajar temporadas enteras: una de anime se reemplazó por la versión multi-audio (38 GB).',
    hacer: () => 'Usar la sección de candidatos de abajo.'
  },
  'permisos-scripts': {
    titulo: 'Scripts que corren como SYSTEM',
    detalle: d => d.archivos.length ? lista(d.archivos.map(a => `${a.archivo}: lo pueden modificar ${a.cuentas.join(' y ')}`)) : 'Solo los pueden modificar tu usuario y los administradores.',
    get antes() { return `${cfg.raiz || 'La carpeta del servidor'} tenía permiso de Modificar para ${cfg.usuarioDescargas} (qBittorrent) y LocalService, y las tareas de mantenimiento ejecutan scripts de esa carpeta como SYSTEM. Si una descarga maliciosa comprometiera qBittorrent, podría reescribirlos y tomar control de la PC. El panel ya está en una carpeta protegida.`; },
    hacer: () => `Ejecutar ${cfg.proteger} (pide permiso de administrador y guarda un respaldo de los permisos). Las carpetas ${cfg.carpetas.peliculas}, ${cfg.carpetas.series} y ${cfg.carpetas.descargas} no cambian. Para volver atrás: Proteger-Scripts.bat deshacer.`
  },
  firewall: {
    titulo: 'Reglas de firewall viejas',
    detalle: d => d.reglas.length ? `Siguen activas: ${d.reglas.join(', ')}. No abren nada, porque esas apps escuchan solo en 127.0.0.1.` : 'No quedan reglas viejas.',
    antes: 'Los instaladores crean reglas "NzbDrone" (7878, 8989 y 9696) y "Bazarr".',
    hacer: () => 'Opcional: borrarlas desde Firewall de Windows como administrador. La de qBittorrent no se toca: deja entrar a los otros participantes de las descargas.'
  }
};
const ORDEN = { falla: 0, error: 0, aviso: 1, info: 2, ok: 3 };
function renderDiag() {
  const dg = datos.diag;
  if (!dg) return;
  const problemas = dg.chequeos.filter(c => c.estado !== 'ok').sort((a, b) => ORDEN[a.estado] - ORDEN[b.estado]);
  const oks = dg.chequeos.filter(c => c.estado === 'ok');
  const tarjeta = c => {
    const def = DIAG[c.id] || { titulo: c.id, detalle: () => JSON.stringify(c.datos) };
    const nivel = c.estado === 'error' ? 'falla' : c.estado;
    let det;
    try { det = c.estado === 'error' ? `No se pudo revisar: ${c.datos.error}` : def.detalle(c.datos); } catch (e) { det = String(e); }
    const acc = (c.estado !== 'ok' && c.estado !== 'error' && def.acciones) ? def.acciones(c.datos) : [];
    const etiqueta = { falla: 'Falla', error: 'Error', aviso: 'Aviso', info: 'Info', ok: 'OK' }[c.estado];
    return h('div', { class: 'chequeo ' + c.estado },
      h('div', { class: 'cab' }, h('b', { text: def.titulo }), h('span', { class: 'pill pill-' + (nivel === 'falla' ? 'falla' : nivel), text: etiqueta })),
      h('div', { class: 'detalle' }, det),
      def.antes ? h('details', { open: c.estado === 'falla' || null },
        h('summary', { text: 'Qué pasó antes y qué hacer' }),
        h('div', { class: 'bloque' }, h('b', { text: 'Ya pasó: ' }), def.antes),
        def.hacer ? h('div', { class: 'bloque' }, h('b', { text: 'Qué hacer: ' }), def.hacer(c.datos)) : null) : null,
      acc.length ? h('div', { class: 'acciones' }, acc.map(([t, fn]) => h('button', { class: 'btn btn-chico btn-primario', text: t, onclick: fn }))) : null);
  };
  poner($('#diag'),
    problemas.length ? h('div', { class: 'diag' }, problemas.map(tarjeta)) : h('div', { class: 'todo-ok' }, h('span', { class: 'punto ok' }), 'No aparece ninguno de los problemas conocidos.'),
    oks.length ? h('details', { class: 'oks-det' },
      h('summary', { class: 'tenue', style: { cursor: 'pointer', marginTop: '12px' }, text: `${oks.length} chequeos en orden: ${oks.map(c => (DIAG[c.id] || { titulo: c.id }).titulo).join(' · ')}` }),
      h('div', { class: 'diag', style: { marginTop: '10px' } }, oks.map(tarjeta))) : null);
  $('#diag-nota').textContent = `Revisado ${hace(dg.generado)}.`;
}

// ---------- espacio y candidatos ----------
function estadoFila(f) {
  if (f.candidato) return ['falla', 'Candidato'];
  if (/ de \d+/.test(f.vistoPor)) return ['info', 'A medias'];
  if (f.ultimoVisto) return ['ok', 'Visto hace poco'];
  return ['', 'Sin ver'];
}
function renderEspacio() {
  const e = datos.espacio;
  if (!e) return;
  const nivel = e.pct >= e.umbral ? 'falla' : e.pct >= e.umbral - 10 ? 'aviso' : '';
  const c = e.carpetas;
  const filasVisibles = verTodo ? e.filas : e.filas.filter(f => f.candidato);
  const candidatos = e.filas.filter(f => f.candidato);
  for (const k of [...seleccion]) if (!e.filas.some(f => f.clave === k)) seleccion.delete(k);
  const selFilas = e.filas.filter(f => seleccion.has(f.clave));
  const selGb = selFilas.reduce((a, f) => a + f.gb, 0);

  const cab = h('div', { class: 'disco' },
    h('div', { class: 'barra-disco ' + nivel },
      h('div', { class: 'lleno', style: { width: e.pct + '%' } }),
      h('i', { class: 'umbral', style: { left: e.umbral + '%' }, title: `Umbral ${e.umbral}%` }),
      h('span', { class: 'txt', text: `${e.pct}% usado · ${bytes(e.total - e.libre)} de ${bytes(e.total)}` })),
    h('div', { class: 'partes' },
      [['Películas', c.peliculas], ['Series', c.series], ['Descargas (compartiendo)', c.descargas], ['Libre', e.libre]].map(([t, v]) => h('div', { class: 'parte' }, h('b', { text: bytes(v) }), h('span', { text: t })))));
  const nota = h('div', { class: 'nota' + (e.pct >= e.umbral ? ' aviso' : '') },
    e.pct >= e.umbral ? `El disco pasó el ${e.umbral}%: conviene borrar algunos candidatos.` : `El disco está por debajo del ${e.umbral}%: no hace falta borrar nada.`,
    ' Lo que está en Descargas y en la biblioteca es el mismo archivo (hardlink): ocupa una sola vez y se libera al borrar las dos copias, que es lo que hace el borrado.');

  const tabla = filasVisibles.length ? h('div', { class: 'tabla-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, h('th', { text: '' }), h('th', { text: 'Título' }), h('th', { class: 'n', text: 'Tamaño' }), h('th', { text: 'Agregado' }), h('th', { text: 'Visto por' }), h('th', { text: 'Última vez' }), h('th', { text: 'Estado' }))),
    h('tbody', {}, filasVisibles.map(f => {
      const [niv, txt] = estadoFila(f);
      const marcado = seleccion.has(f.clave);
      return h('tr', { class: marcado ? 'marcada' : null },
        h('td', {}, h('input', { type: 'checkbox', checked: marcado || null, 'aria-label': 'Seleccionar ' + f.titulo, onchange: ev => { ev.target.checked ? seleccion.add(f.clave) : seleccion.delete(f.clave); renderEspacio(); } })),
        h('td', {}, h('div', { text: f.titulo }), h('div', { class: 'tenue chico', text: f.tipo === 'Serie' ? `Serie · temporada ${f.temporada}` : 'Película' })),
        h('td', { class: 'n', text: nf1.format(f.gb) + ' GB' }),
        h('td', { text: f.agregado }),
        h('td', { text: f.vistoPor || '—' }),
        h('td', { text: f.ultimoVisto || '—' }),
        h('td', {}, h('span', { class: 'estado-celda' }, h('span', { class: 'punto ' + niv }), txt)));
    })))) : h('p', { class: 'vacio', text: verTodo ? 'La lista está vacía.' : `No hay candidatos: nada se vio completo hace más de ${cfg.diasVisto} días.` });

  poner($('#espacio'), cab, nota,
    h('div', { class: 'filtros' },
      h('div', {}, h('b', { text: verTodo ? 'Todo lo que hay en la biblioteca' : `Candidatos (${candidatos.length})` }),
        h('span', { class: 'tenue chico', text: ` · candidato = visto completo hace más de ${cfg.diasVisto} días y que nadie tiene a medias` })),
      h('button', { class: 'btn btn-chico', text: verTodo ? 'Ver solo candidatos' : `Ver todo (${e.filas.length})`, onclick: () => { verTodo = !verTodo; renderEspacio(); } })),
    tabla,
    h('div', { class: 'seleccion' },
      h('span', { text: selFilas.length ? `${plural(selFilas.length, 'seleccionado', 'seleccionados')} · ${nf1.format(selGb)} GB` : 'Tildá lo que quieras borrar.' }),
      h('div', { class: 'acciones' },
        selFilas.length ? h('button', { class: 'btn btn-chico', text: 'Destildar', onclick: () => { seleccion.clear(); renderEspacio(); } }) : null,
        h('button', { class: 'btn btn-chico btn-peligro', text: ocupados.has('borrar') ? 'Borrando…' : 'Borrar seleccionados', disabled: (!selFilas.length || ocupados.has('borrar')) || null, onclick: () => borrar(selFilas) }))),
    e.borrados.length ? h('div', { class: 'borrados' }, h('b', { text: 'Últimos borrados: ' }), e.borrados.slice().reverse().map(b => `${b.titulo}${b.temporada ? ' T' + b.temporada : ''} (${b.gb} GB, ${fecha(b.fecha)})`).join(' · ')) : null);
  $('#espacio-nota').textContent = e.csvFecha ? `Lista generada ${hace(e.csvFecha)} (${fecha(e.csvFecha)}) · se regenera sola los domingos` : 'Todavía no hay lista: tocá Regenerar lista.';
}
async function borrar(filas) {
  const total = filas.reduce((a, f) => a + f.gb, 0);
  const noCand = filas.filter(f => !f.candidato);
  const ok = await confirmar({
    titulo: `Borrar ${plural(filas.length, 'elemento', 'elementos')} (${nf1.format(total)} GB)`, boton: 'Borrar', peligro: true, palabra: 'SI',
    cuerpo: h('div', {},
      lista(filas.map(f => `${f.titulo}${f.tipo === 'Serie' ? ' · temporada ' + f.temporada : ''} (${nf1.format(f.gb)} GB)`)),
      h('p', { text: 'Películas: Radarr la quita de la biblioteca y borra el archivo. Temporadas: Sonarr borra los episodios y deja de monitorearla, para que no se vuelva a bajar. También se borra el torrent y su copia en Descargas (hardlink).' }),
      noCand.length ? h('p', { class: 'cuenta-mal', text: `Ojo: ${plural(noCand.length, 'no es candidato', 'no son candidatos')} (${noCand.map(f => f.titulo).join(', ')}): nadie lo terminó de ver hace más de ${cfg.diasVisto} días.` }) : null,
      h('p', { class: 'tenue', text: 'No se puede deshacer (se podría volver a pedir por Seerr). Al terminar se regenera la lista.' }))
  });
  if (!ok) return;
  ejecutar('borrar', { tipo: 'borrar', claves: filas.map(f => f.clave), csvFecha: datos.espacio.csvFecha }, 'Borrar candidatos', {
    mostrarSalida: true,
    alTerminar: () => { seleccion.clear(); cargarEspacio(true); }
  });
  renderEspacio();
}
async function regenerar() {
  const ok = await confirmar({
    titulo: 'Regenerar la lista de candidatos', boton: 'Regenerar',
    cuerpo: h('p', { text: 'Se vuelve a leer qué se vio en Jellyfin y qué hay en Radarr y Sonarr, y se rearma candidatos-borrar.csv y Reporte-espacio.html. Tarda uno o dos minutos. No borra nada.' })
  });
  if (ok) ejecutar('reporte', { tipo: 'reporte' }, 'Regenerar la lista de candidatos', { alTerminar: () => cargarEspacio(true) });
}

// ---------- resumen general ----------
function renderResumen() {
  const e = datos.estado, s = datos.salud, dg = datos.diag;
  if (!e) return;
  let fallas = e.servicios.filter(x => estadoServicio(x)[0] === 'falla' || !x.cuentaOk).length;
  let avisos = 0;
  if (s) { avisos += s.items.filter(i => i.nivel === 'warning' || i.nivel === 'error').length + s.cola.length + s.caidas.length; }
  if (dg) { fallas += dg.chequeos.filter(c => c.estado === 'falla' || c.estado === 'error').length; avisos += dg.chequeos.filter(c => c.estado === 'aviso').length; }
  const p = $('#resumen');
  if (fallas) { p.className = 'pill pill-falla'; p.textContent = `${plural(fallas, 'problema', 'problemas')}${avisos ? ' · ' + plural(avisos, 'aviso', 'avisos') : ''}`; }
  else if (avisos) { p.className = 'pill pill-aviso'; p.textContent = `Funciona · ${plural(avisos, 'aviso', 'avisos')}`; }
  else { p.className = 'pill pill-ok'; p.textContent = 'Todo en orden'; }
  $('#actualizado').textContent = 'Actualizado ' + new Date(e.generado).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

// ---------- carga ----------
async function cargarEstado() {
  try { datos.estado = await api('/api/estado'); } catch { return; }
  renderKpis(); renderServicios(); renderDescargas(); renderResumen();
}
async function cargarSalud(forzar) {
  try { datos.salud = await api('/api/salud' + (forzar ? '?forzar=1' : '')); } catch (e) { if (!caido) poner($('#salud'), h('p', { class: 'vacio', text: 'No se pudo leer: ' + e.message })); return; }
  renderSalud(); renderServicios(); renderResumen();
}
async function cargarDiag(forzar) {
  if (forzar) $('#diag-nota').textContent = 'Revisando…';
  try { datos.diag = await api('/api/diagnostico' + (forzar ? '?forzar=1' : '')); } catch (e) { if (!caido) poner($('#diag'), h('p', { class: 'vacio', text: 'No se pudo revisar: ' + e.message })); return; }
  renderDiag(); renderResumen();
}
async function cargarEspacio(forzar) {
  try { datos.espacio = await api('/api/espacio' + (forzar ? '?forzar=1' : '')); } catch (e) { if (!caido) poner($('#espacio'), h('p', { class: 'vacio', text: 'No se pudo leer: ' + e.message })); return; }
  renderEspacio();
}

document.addEventListener('DOMContentLoaded', async () => {
  $('#btn-actualizar').addEventListener('click', async () => { await cargarEstado(); cargarSalud(true); cargarEspacio(); });
  $('#btn-salud').addEventListener('click', () => cargarSalud(true));
  $('#btn-diag').addEventListener('click', () => cargarDiag(true));
  $('#btn-reporte').addEventListener('click', regenerar);
  await cargarConfig();
  await cargarEstado();
  await cargarSalud();
  await cargarEspacio();
  await cargarDiag();
  setInterval(() => { if (!document.hidden && !caido) cargarEstado(); }, 10000);
  setInterval(() => { if (!document.hidden && !caido) cargarSalud(); }, 60000);
  setInterval(() => { if (!document.hidden && !caido && datos.diag) renderDiag(); }, 60000);
  // Con la ventana minimizada no se refresca, pero se avisa que sigue abierta para que el servidor no se apague
  setInterval(() => { if (document.hidden && !caido) fetch('/ping', { cache: 'no-store' }).catch(panelCaido); }, 30000);
});
