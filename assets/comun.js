// Funciones compartidas por todas las páginas
const sb = window.supabase.createClient(window.SISOPE_CONFIG.SUPABASE_URL, window.SISOPE_CONFIG.SUPABASE_KEY);
// ---------- Guardia de páginas docentes ----------
// La seguridad real está en la base de datos (RLS): un alumno no puede leer ni modificar datos ajenos aunque abra estas páginas.
// Esta guardia además oculta la página hasta confirmar el rol y registra el intento si un alumno entra cambiando la dirección.
const PAGINAS_DOCENTE = ['docente.html', 'juego.html', 'grupal.html', 'lab.html', 'foro.html', 'quiz.html', 'kahoot.html', 'examenes.html', 'progreso.html', 'buzon.html', 'ajustes.html'];
(function guardia() {
  const pag = location.pathname.split('/').pop() || 'index.html';
  if (!PAGINAS_DOCENTE.includes(pag)) return;
  document.documentElement.style.visibility = 'hidden';
  (async () => {
    const { data } = await sb.auth.getSession();
    if (!data.session) { location.replace('index.html'); return; }
    const { data: ok, error } = await sb.rpc('es_docente');
    if (error || ok !== true) { try { await sb.rpc('registrar_intento', { p_pagina: pag }); } catch (e) {} location.replace('alumno.html?bloqueado=1'); return; }
    document.documentElement.style.visibility = '';
  })();
})();

const $ = (s) => document.querySelector(s);
const esc = (t) => String(t ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function toast(msg, err) { const t = $('#toast'); t.textContent = msg; t.classList.toggle('err', !!err); t.classList.add('show'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 2600); }
async function sesionORedirigir() { const { data } = await sb.auth.getSession(); if (!data.session) { location.replace('index.html'); return null; } return data.session; }
async function esDocente() { const { data, error } = await sb.rpc('es_docente'); return !error && data === true; }
// Medallas: las 'auto' las calcula la base cada semana; las demás las otorga la docente
const MEDALLAS = {
  on_fire: ['🔥', '¡Estás on fire!', 'Superó la meta de XP de la semana', 'auto'],
  cima: ['🏔️', '¡En la cima!', 'Mejor puntaje de la semana en su aula', 'auto'],
  francotirador: ['🎯', 'Francotirador', '3 o más aciertos sin fallar en el Juego del Miedo', 'auto'],
  kahoot: ['🏆', 'Campeón Kahoot', '1er puesto en el Kahoot de la semana', 'auto'],
  estrella: ['⭐', 'Estrella de la clase', 'Destacó en la sesión de hoy'],
  mentor: ['🤝', 'Mentor', 'Ayudó a sus compañeros'],
  idea: ['💡', 'Idea brillante', 'Propuso una solución creativa'],
  investigador: ['🔬', 'Investigador', 'Fue más allá investigando por su cuenta'],
  remontada: ['🚀', 'Remontada', 'Mejoró muchísimo respecto a semanas anteriores'],
  relampago: ['⚡', 'Respuesta relámpago', 'Respondió primero y bien'],
  valiente: ['🦁', 'Valiente', 'Se animó a participar aunque le cuesta'],
  companero: ['💖', 'Buen compañero', 'Actitud solidaria con su equipo'],
  especial: ['🏅', 'Medalla especial', 'Motivo escrito por la docente']
};
const medalla = t => MEDALLAS[t] || ['🏅', t, ''];

// Avatar: guarda la ruta 'avatares/archivo.webp?v=…' y arma la URL pública de Supabase Storage
function nombreAzar(usados = []) { const A = ['Neo', 'Shadow', 'Pixel', 'Root', 'Byte', 'Zero', 'Kernel', 'Code', 'Null', 'Bit', 'Sudo', 'Cyber', 'Quantum', 'Hyper', 'Cloud', 'Packet', 'Docker', 'Nano', 'Turbo', 'Vector'], B = ['Kernel', 'Root', 'Ghost', 'Kitty', 'Runner', 'Day', 'Panic', 'Ninja', 'Pointer', 'Witch', 'Sam', 'Byte', 'Wolf', 'Falcon', 'Shell', 'Daemon', 'Phoenix', 'Raptor', 'Spark', 'Titan'], u = new Set(usados.map(x => String(x).toLowerCase())); for (let i = 0; i < 60; i++) { const a = A[Math.floor(Math.random() * A.length)], b = B[Math.floor(Math.random() * B.length)]; if (a !== b && !u.has((a + b).toLowerCase())) return a + b; } return 'Jugador' + Math.floor(100 + Math.random() * 900); }
function avatarSrc(u) { return !u ? '' : /^https?:/.test(u) ? u : `${window.SISOPE_CONFIG.SUPABASE_URL}/storage/v1/object/public/${u}`; }
// ---------- Secciones (aulas): la elegida se recuerda en este navegador ----------
let SECC = null, SECCIONES = [];
async function cargarSeccion() {
  const { data } = await sb.from('secciones').select('*').order('id');
  SECCIONES = (data || []).filter(s => s.activa);
  let id = null; try { id = Number(localStorage.getItem('sisope_seccion')); } catch (e) {}
  SECC = SECCIONES.find(s => s.id === id) || SECCIONES[0] || null;
  try { if (SECC) localStorage.setItem('sisope_seccion', SECC.id); } catch (e) {}
  pintarSelector();
  return SECC;
}
function pintarSelector() {
  const n = document.getElementById('nav'); if (!n || !SECCIONES.length || document.getElementById('secSel')) return;
  const d = document.createElement('div'); d.className = 'mg secc';
  d.innerHTML = `<span class="mgt">AULA</span><select id="secSel" title="Sección con la que trabajas">${SECCIONES.map(s => `<option value="${s.id}" ${s.id === SECC?.id ? 'selected' : ''}>${esc(s.nombre)}</option>`).join('')}</select>`;
  n.prepend(d);
  d.querySelector('select').onchange = e => { try { localStorage.setItem('sisope_seccion', e.target.value); } catch (x) {} location.reload(); };
}
// Podio del Kahoot por semana de la sección elegida
async function podiosSeccion(secId) {
  const { data } = await sb.from('sesiones').select('semana, kahoot_podio, fecha').eq('seccion_id', secId);
  return Object.fromEntries((data || []).map(x => [x.semana, x]));
}
async function salir() { await sb.auth.signOut(); location.replace('index.html'); }

// Menú docente agrupado (se pinta en <nav id="nav">)
const MENU = [
  ['EN CLASE', [['docente.html', 'Inicio', 'navy'], ['juego.html', 'Juego del Miedo', 'red'], ['grupal.html', 'Trabajo grupal', 'purple']]],
  ['EN CASA', [['lab.html', 'Laboratorio', 'teal'], ['foro.html', 'Foro', 'blue'], ['quiz.html', 'Quiz', 'gold'], ['kahoot.html', 'Kahoot', 'pink']]],
  ['NOTAS', [['examenes.html', 'Exámenes y bonus', 'orange'], ['progreso.html', 'Progreso', 'teal'], ['buzon.html', 'Buzón', 'purple'], ['ajustes.html', 'Ajustes', 'navy']]]
];
function pintarNav() {
  const actual = location.pathname.split('/').pop() || 'docente.html';
  const n = document.getElementById('nav'); if (!n) return;
  n.className = 'tabs menu';
  n.innerHTML = MENU.map(([g, items]) => `<div class="mg"><span class="mgt">${g}</span>${items.map(([href, txt, color]) =>
    href ? `<a href="${href}" class="${href === actual ? 'on c-' + color : ''}">${txt}</a>` : `<a class="off" title="Próximamente">${txt}</a>`).join('')}</div>`).join('');
  if (typeof pintarSelector === 'function') pintarSelector();
  contarBuzon();
}
// Globo con los mensajes sin leer de los alumnos (solo lo ve la docente: la tabla está protegida por RLS)
async function contarBuzon() {
  const a = document.querySelector('#nav a[href="buzon.html"]'); if (!a || typeof sb === 'undefined') return;
  const { count, error } = await sb.from('mensajes').select('id', { count: 'exact', head: true }).eq('leido', false);
  a.querySelector('.nb')?.remove(); if (!error && count) a.insertAdjacentHTML('beforeend', ` <span class="nb">${count}</span>`);
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', pintarNav); else pintarNav();
