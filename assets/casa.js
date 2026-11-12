// Calificación en casa (Laboratorio, Foro…): elige semana, califica por alumno o por consultora.
// Cada página define window.CASA = { campos: 'lab, lab_modo', cols: [...], total: f => n, max: 3 }
const nv = v => v === null || v === undefined ? null : Number(v);
const f1 = x => String(Math.round(x * 10) / 10);
let SEM = 1, FILAS = [], SEMANAS = [], FILTRO = '';

async function iniciarCasa() {
  const ses = await sesionORedirigir(); if (!ses) return;
  if (!(await esDocente())) { location.replace('alumno.html'); return; }
  $('#quien').textContent = ses.user.email;
  const [{ data: sem }, { data: c }, { data: hechas }] = await Promise.all([
    sb.from('semanas').select('*').order('semana'),
    sb.from('config').select('valor').eq('clave', 'SemanaActual').maybeSingle(),
    sb.from('detalle').select('semana')
  ]);
  const conFilas = new Set((hechas || []).map(x => x.semana));
  SEMANAS = (sem || []).filter(s => !['Examen', '—'].includes(s.tipo_grupal));
  $('#semana').innerHTML = SEMANAS.map(s => `<option value="${s.semana}" ${conFilas.has(s.semana) ? '' : 'disabled'}>Semana ${s.semana} · ${esc(s.practica || '')} · ${esc(s.tema || '')}${conFilas.has(s.semana) ? '' : ' (sin iniciar)'}</option>`).join('');
  const actual = parseInt(c?.valor, 10) || 1;
  SEM = conFilas.has(actual) ? actual : ([...conFilas].sort((a, b) => b - a)[0] || actual);
  $('#semana').value = String(SEM);
  $('#semana').onchange = () => { SEM = Number($('#semana').value); cargarCasa(); };
  $('#buscar').oninput = () => { FILTRO = $('#buscar').value.trim().toLowerCase(); pintarCasa(); };
  await cargarCasa();
}

async function cargarCasa() {
  const { data, error } = await sb.from('detalle').select(`id, asistencia, ${CASA.campos}, jugadores(nombre, alias, consultora)`).eq('semana', SEM);
  if (error) { toast('Error al cargar: ' + error.message, true); return; }
  FILAS = (data || []).sort((a, b) => (a.jugadores?.nombre || '').localeCompare(b.jugadores?.nombre || ''));
  pintarCasa();
}

function celda(f, col) {
  if (col.tipo === 'bono') {
    const v = nv(f[col.campo]) || 0;
    return `<div class="jmc"><button class="menos" ${v ? '' : 'disabled'} onclick="contar(${f.id}, '${col.campo}', -0.5)">−0.5</button><span class="neto ${v ? 'pos' : ''}">${v ? '+' + f1(v) : '0'}</span><button class="mas" onclick="contar(${f.id}, '${col.campo}', 0.5)">+0.5</button></div>`;
  }
  if (col.tipo === 'cnt') {
    const v = nv(f[col.campo]) || 0;
    return `<span class="cnt mini3"><button ${v ? '' : 'disabled'} onclick="contar(${f.id}, '${col.campo}', -1)">−</button><button onclick="contar(${f.id}, '${col.campo}', 1)">${esc(col.ico || '')} ${v}</button></span>`;
  }
  return `<span class="seg ${col.cls || ''}">${col.opciones.map(o => {
    const [val, txt] = Array.isArray(o) ? o : [o, String(o)];
    const on = typeof val === 'number' ? nv(f[col.campo]) === val : f[col.campo] === val;
 return `<button class="${on ? 'on' : ''} ${col.cls === 'txt' ? 'p' : ''} ${typeof val === 'number' && val < 0 ? 'neg' : ''}" onclick='poner(${f.id}, "${col.campo}", ${JSON.stringify(val)})'>${esc(txt)}</button>`;
  }).join('')}</span>`;
}

function pintarCasa() {
  const grid = `grid-template-columns:${CASA.grid}`;
  $('#cab').style.cssText = grid;
  $('#cab').innerHTML = `<div>Alumno</div>${CASA.cols.map(c => `<div><b>${c.titulo}</b>${c.sub ? '<br>' + c.sub : ''}</div>`).join('')}<div style="text-align:right"><b>Puntos / ${CASA.max}</b></div>`;
  if (!FILAS.length) { $('#lista').innerHTML = `<div class="empty">No hay filas para la semana ${SEM}.</div>`; return; }
  const vis = FILAS.filter(f => !FILTRO || (f.jugadores?.nombre + ' ' + f.jugadores?.alias).toLowerCase().includes(FILTRO));
  const grupos = {}; vis.forEach(f => { const g = f.jugadores?.consultora || 'SIN CONSULTORA'; (grupos[g] = grupos[g] || []).push(f); });
  const calif = FILAS.filter(f => CASA.calificado(f)).length;
  $('#avance').textContent = `${calif} de ${FILAS.length} calificados`;
  $('#lista').innerHTML = Object.keys(grupos).sort().map(g => {
    const fs = grupos[g], prom = fs.reduce((s, f) => s + CASA.total(f), 0) / fs.length;
    return `<div class="grupo">
      <div class="grrow grcab" style="${grid}"><div class="pix" style="font-size:11px">${esc(g.toUpperCase())}<small>Promedio ${f1(prom)} / ${CASA.max}</small></div>
        ${CASA.cols.map(c => c.masivo ? `<span class="seg bulk"><i>Todos</i>${c.masivo.map(v => `<button onclick='masivo(${JSON.stringify(g)}, "${c.campo}", ${JSON.stringify(v)})'>${esc(v < 0 ? 'No cumplió' : (c.campo === 'kahoot_pos' && v === 4) ? 'Participó' : String(v))}</button>`).join('')}</span>` : '<div></div>').join('')}<div></div></div>
      ${fs.map(f => `<div class="grrow ${CASA.calificado(f) ? '' : 'pend'}" style="${grid}">
        <div><b>${esc(f.jugadores?.nombre)}</b><small>${esc(f.jugadores?.alias)}${f.asistencia === 'Ausente' ? ' · faltó a clase' : ''}${CASA.calificado(f) ? '' : ' · <span class="pendt">pendiente</span>'}</small></div>
        ${CASA.cols.map(c => celda(f, c)).join('')}
        <div class="tot">${f1(CASA.total(f))}</div>
      </div>`).join('')}
    </div>`;
  }).join('');
}

async function poner(id, campo, valor) {
  const f = FILAS.find(x => x.id === id), antes = f[campo];
  const actual = typeof valor === 'number' ? nv(f[campo]) : f[campo];
  const nuevo = actual === valor ? null : valor;
  f[campo] = nuevo; pintarCasa();
  const { error } = await sb.from('detalle').update({ [campo]: nuevo }).eq('id', id);
  if (error) { f[campo] = antes; pintarCasa(); toast('No se guardó: ' + error.message, true); return; }
  if (campo === 'kahoot_pos' && nuevo >= 1 && nuevo <= 3) {
    const otros = FILAS.filter(x => x.id !== id && nv(x.kahoot_pos) === nuevo);
    if (otros.length) toast(`Ojo: ${otros.map(x => x.jugadores?.alias).join(', ')} también tiene el puesto ${nuevo}°`, true);
  }
}
async function contar(id, campo, delta) {
  const f = FILAS.find(x => x.id === id), antes = nv(f[campo]) || 0; if (antes + delta < 0) return;
  f[campo] = antes + delta; pintarCasa();
  const { error } = await sb.from('detalle').update({ [campo]: antes + delta }).eq('id', id);
  if (error) { f[campo] = antes; pintarCasa(); toast('No se guardó: ' + error.message, true); }
}
async function masivo(g, campo, valor) {
  const fs = FILAS.filter(f => (f.jugadores?.consultora || 'SIN CONSULTORA') === g); if (!fs.length) return;
  const antes = fs.map(f => f[campo]); fs.forEach(f => f[campo] = valor); pintarCasa();
  const { error } = await sb.from('detalle').update({ [campo]: valor }).in('id', fs.map(f => f.id));
  if (error) { fs.forEach((f, i) => f[campo] = antes[i]); pintarCasa(); toast('No se guardó: ' + error.message, true); return; }
  toast(`${g}: ${valor} para ${fs.length} alumnos`);
}
