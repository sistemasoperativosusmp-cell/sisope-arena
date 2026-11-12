// Funciones compartidas por todas las páginas
const sb = window.supabase.createClient(window.SISOPE_CONFIG.SUPABASE_URL, window.SISOPE_CONFIG.SUPABASE_KEY);
const $ = (s) => document.querySelector(s);
const esc = (t) => String(t ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function toast(msg, err) { const t = $('#toast'); t.textContent = msg; t.classList.toggle('err', !!err); t.classList.add('show'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 2600); }
async function sesionORedirigir() { const { data } = await sb.auth.getSession(); if (!data.session) { location.replace('index.html'); return null; } return data.session; }
async function esDocente() { const { data, error } = await sb.rpc('es_docente'); return !error && data === true; }
async function salir() { await sb.auth.signOut(); location.replace('index.html'); }

// Menú docente agrupado (se pinta en <nav id="nav">)
const MENU = [
  ['EN CLASE', [['docente.html', 'Inicio', 'navy'], ['juego.html', 'Juego del Miedo', 'red'], ['grupal.html', 'Trabajo grupal', 'purple']]],
  ['EN CASA', [['lab.html', 'Laboratorio', 'teal'], ['foro.html', 'Foro', 'blue'], [null, 'Quiz y Kahoot']]],
  ['NOTAS', [['examenes.html', 'Exámenes y bonus', 'orange'], [null, 'Radar de silencio'], [null, 'Ajustes']]]
];
function pintarNav() {
  const actual = location.pathname.split('/').pop() || 'docente.html';
  const n = document.getElementById('nav'); if (!n) return;
  n.className = 'tabs menu';
  n.innerHTML = MENU.map(([g, items]) => `<div class="mg"><span class="mgt">${g}</span>${items.map(([href, txt, color]) =>
    href ? `<a href="${href}" class="${href === actual ? 'on c-' + color : ''}">${txt}</a>` : `<a class="off" title="Próximamente">${txt}</a>`).join('')}</div>`).join('');
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', pintarNav); else pintarNav();
