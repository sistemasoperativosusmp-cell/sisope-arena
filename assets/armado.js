// Armado automático de consultoras a partir de la Misión 0.
// 1) Reparto en "serpiente" por nivel técnico → cada equipo tiene alumnos fuertes, intermedios y en desarrollo.
// 2) Intercambios dentro del mismo nivel para que cada equipo tenga al menos una "voz" y un "reservado".
// 3) Roles: se prueban todas las combinaciones dentro del equipo. Modo reto = rol de MENOR afinidad; afinidad = el de mayor.
(function (global) {
  const ROLES = () => global.ROLES_EQUIPO || ['Sales Specialist', 'Preventa', 'Arquitecto', 'Implementador / Project Manager'];
  // Si un equipo tiene más integrantes que roles, estos roles se repiten (en este orden)
  const EXTRA = ['Arquitecto', 'Implementador / Project Manager', 'Preventa', 'Sales Specialist'];

  function perfil(p) {
    return p ? { tec: Number(p.tecnico) || 0, com: Number(p.comunicacion) || 0, af: p.afinidad || {}, ok: true } : { tec: 50, com: 50, af: {}, ok: false };
  }
  const media = a => a.length ? a.reduce((s, x) => s + x, 0) / a.length : 0;

  function costo(eq, tecGlobal) {
    let c = 0;
    eq.forEach(t => {
      if (!t.some(a => a.voz === 'voz')) c += 1;
      if (!t.some(a => a.voz === 'reservado')) c += 1;
      if (t.filter(a => a.voz === 'voz').length > 2) c += 0.5;
      c += Math.abs(media(t.map(a => a.p.tec)) - tecGlobal) / 100;
    });
    return c;
  }

  function* perms(n, k, usados = [], acc = []) {   // permutaciones de índices 0..n-1 de largo k
    if (acc.length === k) { yield acc.slice(); return; }
    for (let i = 0; i < n; i++) if (!usados[i]) { usados[i] = true; acc.push(i); yield* perms(n, k, usados, acc); acc.pop(); usados[i] = false; }
  }

  function asignarRoles(equipo, modo, azar = Math.random) {
    const R = ROLES(), m = equipo.length; if (!m) return equipo;
    const S = m <= R.length ? R.slice() : R.concat(Array.from({ length: m - R.length }, (_, i) => EXTRA[i % EXTRA.length]));
    const jit = equipo.map(() => S.map(() => azar() * 2));
    let mejor = null, mejorV = -Infinity;
    for (const pm of perms(S.length, m)) {
      let v = 0;
      pm.forEach((si, i) => { const af = equipo[i].p.af[S[si]]; const a = af === undefined || af === null ? 50 : Number(af); v += (modo === 'afinidad' ? a : 100 - a) + jit[i][si]; });
      if (v > mejorV) { mejorV = v; mejor = pm; }
    }
    equipo.forEach((a, i) => { a.rol = S[mejor[i]]; });
    return equipo;
  }

  // alumnos: [{id, ...}] · perfiles: {id: fila eq_perfil} · tam: tamaño objetivo · modo: 'reto' | 'afinidad'
  function armarEquipos(alumnos, perfiles, tam = 5, modo = 'reto', azar = Math.random) {
    const n = alumnos.length; if (!n) return [];
    const k = Math.max(1, Math.ceil(n / Math.max(2, tam)));
    const L = alumnos.map(a => ({ ...a, p: perfil(perfiles[a.id]), r: azar() }));
    // Voz: tercio superior en comunicación · reservado: tercio inferior
    L.slice().sort((x, y) => x.p.com - y.p.com || x.r - y.r).forEach((a, i) => { a.voz = i < Math.floor(n / 3) ? 'reservado' : i >= n - Math.floor(n / 3) ? 'voz' : 'medio'; });
    // Serpiente por nivel técnico
    const ord = L.sort((x, y) => y.p.tec - x.p.tec || x.r - y.r);
    const eq = Array.from({ length: k }, () => []);
    ord.forEach((a, i) => { const ronda = Math.floor(i / k), pos = i % k; a.ronda = ronda; eq[ronda % 2 ? k - 1 - pos : pos].push(a); });
    // Mejora local: intercambiar alumnos del mismo nivel (misma ronda) entre equipos
    const tg = media(ord.map(a => a.p.tec));
    let c0 = costo(eq, tg);
    for (let pasada = 0; pasada < 40; pasada++) {
      let mejoro = false;
      for (let t1 = 0; t1 < k; t1++) for (let t2 = t1 + 1; t2 < k; t2++) {
        for (let i = 0; i < eq[t1].length; i++) for (let j = 0; j < eq[t2].length; j++) {
          const a = eq[t1][i], b = eq[t2][j];
          if (Math.abs(a.ronda - b.ronda) > 0 || a.voz === b.voz) continue;
          eq[t1][i] = b; eq[t2][j] = a;
          const c1 = costo(eq, tg);
          if (c1 < c0 - 1e-9) { c0 = c1; mejoro = true; } else { eq[t1][i] = a; eq[t2][j] = b; }
        }
      }
      if (!mejoro) break;
    }
    return eq.map(t => asignarRoles(t, modo, azar));
  }

  global.ARMADO = { armarEquipos, asignarRoles, perfil, costo };
  if (typeof module !== 'undefined') module.exports = global.ARMADO;
})(typeof window !== 'undefined' ? window : globalThis);
