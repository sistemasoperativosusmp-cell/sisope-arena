// Insignias de SISOPE Arena: una sola definición para el portal del alumno y las vistas de la docente.
// Cada insignia: [archivo de imagen, nombre, rareza, cómo se gana, ¿ganada?]
const RAREZA = { comun: 'Común', rara: 'Rara', epica: 'Épica', legendaria: 'Legendaria', secreta: 'Secreta' };
function calcInsignias({ D = [], nt = {}, yo = null, YO = null, CONS = [], CFG = {} }) {
  const n = v => Number(v || 0), voz = d => n(d.jm_aciertos) + n(d.part_vol) + ({ 'Lideró': 3, 'Apoyó': 2, 'Habló': 1, 'Intentando': 0.5 }[d.participacion_grupal] || 0);
  D = D.slice().sort((a, b) => a.semana - b.semana);
  let racha = 0, mejor = 0; D.forEach(d => { racha = voz(d) > 0 ? racha + 1 : 0; mejor = Math.max(mejor, racha); });
  const seguidas = ok => { let r = 0, m = 0, prev = null; D.slice().sort((a, b) => a.semana - b.semana).forEach(d => { r = ok(d) ? (prev !== null && d.semana === prev + 1 && r > 0 ? r + 1 : 1) : 0; prev = d.semana; m = Math.max(m, r); }); return m; };
  return [
    ['primer-comando', 'Primer Comando', 'comun', 'Entrega tu primer laboratorio', D.some(d => d.lab !== null && n(d.lab) >= 0)],
    ['automatizador', 'Automatizador', 'comun', 'Participa en clase 3 semanas seguidas', mejor >= 3],
    ['gestor-procesos', 'Gestor de Procesos', 'rara', '3 aciertos en un mismo Juego del Miedo', D.some(d => n(d.jm_aciertos) >= 3)],
    ['control-accesos', 'Control de Accesos', 'rara', 'Saca 14 o más en la Práctica 2 (Identidad y accesos)', n(nt.p2) >= 14],
    ['maestro-memoria', 'Maestro de Memoria', 'epica', 'Saca 3 en dos laboratorios', D.filter(d => n(d.lab) >= 3).length >= 2],
    ['sincronizacion', 'Sincronización', 'epica', 'Lidera dos trabajos grupales', D.filter(d => d.participacion_grupal === 'Lideró').length >= 2],
    ['dominio-sistema', 'Dominio del Sistema', 'legendaria', 'Llega al Top 3 del ranking de tu aula', !!yo && yo.posicion <= 3],
    ['red-accion', 'Red en Acción', 'legendaria', 'Saca 16 o más en la Práctica 3 (Servicios de red)', n(nt.p3) >= 16],
    ['virtualizacion-total', 'Virtualización Total', 'secreta', 'Saca 18 o más en la Práctica 1 (Virtualización)', n(nt.p1) >= 18],
    ['nucleo-supremo', 'Núcleo Supremo', 'secreta', 'Alcanza el nivel 10', !!yo && yo.nivel >= 10],
    ['arranque-sistema', 'Arranque del Sistema', 'comun', 'Sube tu foto de perfil', !!YO?.avatar_url],
    ['daemon-puntual', 'Daemon Puntual', 'comun', 'Asiste 4 semanas seguidas sin tardanza', seguidas(d => d.asistencia === 'Presente') >= 4],
    ['kernel-panic', 'Kernel Panic Superado', 'rara', 'En una misma clase falla en el Juego del Miedo y luego acierta', D.some(d => n(d.jm_fallos) >= 1 && n(d.jm_aciertos) >= 1)],
    ['escritor-logs', 'Escritor de Logs', 'rara', 'Nota completa en el foro 3 veces', D.filter(d => n(d.foro_tecnico) + n(d.foro_analisis) >= 2).length >= 3],
    ['velocista-kahoot', 'Velocista Kahoot', 'rara', 'Gana el 1.er puesto en 2 Kahoots', D.filter(d => n(d.kahoot_pos) === 1).length >= 2],
    ['investigador-root', 'Investigador Root', 'epica', 'Gana bonificación en 3 laboratorios por investigar algo adicional', D.filter(d => n(d.lab_bonus) > 0).length >= 3],
    ['cluster-imparable', 'Clúster Imparable', 'epica', 'Tu consultora llega al 1.er puesto del ranking de consultoras', !!YO?.consultora && CONS.some(c => c.consultora === YO.consultora && c.posicion === 1)],
    ['certificado-azure', 'Certificado Azure', 'legendaria', `Aprueba la certificación de Azure (quiz de la semana ${Number(CFG.SemanaCertAzure || 12)})`, D.some(d => d.semana === Number(CFG.SemanaCertAzure || 12) && n(d.quiz) >= 4)],
    ['arquitecto-cloud', 'Arquitecto Cloud', 'legendaria', 'Saca 16 o más en la Práctica 4 (Plataformas empresariales)', n(nt.p4) >= 16],
    ['uptime', 'Uptime 99.9%', 'legendaria', 'Asistencia completa en todo el ciclo (mínimo 12 semanas)', D.length >= 12 && D.every(d => d.asistencia !== 'Ausente')],
    ['modo-dios', 'Modo Dios', 'secreta', 'Saca 20 en las 4 prácticas', [1, 2, 3, 4].every(i => n(nt['p' + i]) >= 20)]
  ];
}
