// Funciones compartidas por todas las páginas
const sb = window.supabase.createClient(window.SISOPE_CONFIG.SUPABASE_URL, window.SISOPE_CONFIG.SUPABASE_KEY);
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
  ['NOTAS', [['examenes.html', 'Exámenes y bonus', 'orange'], ['progreso.html', 'Progreso', 'teal'], ['ajustes.html', 'Ajustes', 'navy']]]
];
function pintarNav() {
  const actual = location.pathname.split('/').pop() || 'docente.html';
  const n = document.getElementById('nav'); if (!n) return;
  n.className = 'tabs menu';
  n.innerHTML = MENU.map(([g, items]) => `<div class="mg"><span class="mgt">${g}</span>${items.map(([href, txt, color]) =>
    href ? `<a href="${href}" class="${href === actual ? 'on c-' + color : ''}">${txt}</a>` : `<a class="off" title="Próximamente">${txt}</a>`).join('')}</div>`).join('');
  if (typeof pintarSelector === 'function') pintarSelector();
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', pintarNav); else pintarNav();
