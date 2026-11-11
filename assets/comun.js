// Funciones compartidas por todas las páginas
const sb = window.supabase.createClient(window.SISOPE_CONFIG.SUPABASE_URL, window.SISOPE_CONFIG.SUPABASE_KEY);
const $ = (s) => document.querySelector(s);
const esc = (t) => String(t ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function toast(msg, err) { const t = $('#toast'); t.textContent = msg; t.classList.toggle('err', !!err); t.classList.add('show'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 2600); }
async function sesionORedirigir() { const { data } = await sb.auth.getSession(); if (!data.session) { location.replace('index.html'); return null; } return data.session; }
async function esDocente() { const { data, error } = await sb.rpc('es_docente'); return !error && data === true; }
async function salir() { await sb.auth.signOut(); location.replace('index.html'); }
