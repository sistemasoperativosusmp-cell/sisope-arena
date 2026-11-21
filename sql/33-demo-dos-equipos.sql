-- =====================================================================
-- SISOPE Arena · 2 EQUIPOS DEMO con datos realistas
-- Requiere: 28 (equipos), 29 (alumnos demo) y, si quieres los temas con nombre, 31.
-- Ejecútalo en Supabase → SQL Editor. Se puede volver a ejecutar: reescribe solo los datos demo.
--   · Consultora "Los Kernel"  (demo01–demo05): equipo fuerte, con un tímido y un flojo que mejora.
--   · Consultora "Byte Force"  (demo06–demo10): equipo irregular que se recupera; demo10 aún no hace la Misión 0.
--   · Misión 0 con respuestas pregunta por pregunta (Domina / Debilidades / No lo sé).
--   · Roles, temas de grupo, medallas, feedback, un reporte pendiente y un strike validado.
-- Para borrar todo lo demo: 29b-borrar-demo.sql
-- =====================================================================
do $$
declare
  v_sec int; a record; q record; v_jid uuid; r jsonb; ok int; tot int; i int; ch text;
begin
  select id into v_sec from public.secciones where nombre = 'DEMO Equipos';
  if v_sec is null then raise exception 'Primero ejecuta 29-demo-equipos.sql'; end if;

  -- 1) Los dos equipos
  insert into public.equipos (seccion_id, nombre, lema, color) values
    (v_sec, 'Los Kernel', 'Root o nada', '#2463d6'),
    (v_sec, 'Byte Force', 'Del bit a la nube', '#be185d')
  on conflict (seccion_id, nombre) do update set lema = excluded.lema, color = excluded.color;
  delete from public.equipos where seccion_id = v_sec and nombre not in ('Los Kernel', 'Byte Force');

  -- 2) Integrantes, rol y Misión 0 pregunta por pregunta
  --    patrón por pregunta técnica (orden 1..10): O = correcta · X = incorrecta · N = "No lo sé" · - = sin Misión 0
  for a in select * from (values
    ('demo01@demo.sisope.pe', 'Los Kernel', 'Arquitecto',                      'OOOOOOOOXO'),
    ('demo02@demo.sisope.pe', 'Los Kernel', 'Sales Specialist',                'OOXOOONOXO'),
    ('demo03@demo.sisope.pe', 'Los Kernel', 'Implementador / Project Manager', 'OOXOONOOXO'),
    ('demo04@demo.sisope.pe', 'Los Kernel', 'Preventa',                        'XONXOXNXNO'),
    ('demo05@demo.sisope.pe', 'Los Kernel', 'Arquitecto',                      'OXOOXNOXOO'),
    ('demo06@demo.sisope.pe', 'Byte Force', 'Arquitecto',                      'OOOOOOOXOO'),
    ('demo07@demo.sisope.pe', 'Byte Force', 'Implementador / Project Manager', 'OOXONOXOOX'),
    ('demo08@demo.sisope.pe', 'Byte Force', 'Preventa',                        'OXNXOXOXNO'),
    ('demo09@demo.sisope.pe', 'Byte Force', 'Sales Specialist',                'OOOXOONOOX'),
    ('demo10@demo.sisope.pe', 'Byte Force', 'Implementador / Project Manager', '----------')
  ) as t(correo, equipo, rol, patron) loop
    update public.jugadores set consultora = a.equipo, rol_consultora = a.rol where correo = a.correo returning id into v_jid;
    if v_jid is null then raise exception 'No existe %: ejecuta primero 29-demo-equipos.sql', a.correo; end if;
    if a.patron like '-%' then delete from public.eq_perfil where jugador_id = v_jid; continue; end if;
    r := '{}'; ok := 0; tot := 0; i := 0;
    for q in select id, correcta, coalesce(jsonb_array_length(opciones), 4) as nop from public.eq_preguntas where parte = 'tecnica' and activa order by orden, id loop
      i := i + 1; ch := substr(a.patron, ((i - 1) % 10) + 1, 1); tot := tot + 1;
      if ch = 'O' then r := r || jsonb_build_object(q.id::text, q.correcta); ok := ok + 1;
      elsif ch = 'N' then r := r || jsonb_build_object(q.id::text, -1);
      else r := r || jsonb_build_object(q.id::text, (q.correcta + 1) % q.nop); end if;
    end loop;
    insert into public.eq_perfil (jugador_id, tecnico, comunicacion, afinidad, respuestas, modo_elegido, intentos_escape, enviado)
    values (v_jid, case when tot > 0 then round(100.0 * ok / tot, 1) else 0 end, 50, '{"Sales Specialist":55,"Preventa":55,"Arquitecto":55,"Implementador / Project Manager":55}', r, 'reto', 0, now() - interval '35 days')
    on conflict (jugador_id) do update set tecnico = excluded.tecnico, respuestas = excluded.respuestas;
  end loop;

  -- Perfil de comunicación y afinidad por rol según cada alumno (demo09 no venía con Misión 0 en el script 29)
  update public.eq_perfil p set comunicacion = v.com, afinidad = v.af::jsonb, intentos_escape = v.esc
  from (values
    ('demo09@demo.sisope.pe', 70, '{"Sales Specialist":85,"Preventa":70,"Arquitecto":45,"Implementador / Project Manager":60}', 0)
  ) as v(correo, com, af, esc), public.jugadores j
  where j.correo = v.correo and p.jugador_id = j.id;

  -- 3) Semanas con trabajo grupal y tema por equipo (para que el trabajo grupal y el progreso se vean reales)
  update public.detalle d set tipo_grupal = (array['Taller grupal', 'Debate', 'Exposición', 'Taller grupal', 'Juego de roles', 'Exposición'])[d.semana],
         tema_grupal = case j.consultora when 'Los Kernel' then (array['Hyper-V en el aula', 'Linux vs Windows Server', 'RAID 1 y 5', 'Dominio USMP.local', 'DNS interno', 'GPO de seguridad'])[d.semana]
                                         else (array['VirtualBox y redes', 'Licenciamiento', 'Backup 3-2-1', 'Usuarios y grupos', 'Registros DNS', 'OUs por área'])[d.semana] end
  from public.jugadores j where j.id = d.jugador_id and j.seccion_id = v_sec and d.semana between 1 and 6;

  -- Byte Force arranca flojo en el grupal y repunta desde la semana 4
  update public.detalle d set gr_tecnico = case when d.semana <= 3 then 0 else 1 end, gr_analisis = case when d.semana <= 3 then 0.5 else 1 end,
         gr_comunicacion = case when d.semana <= 3 then 0.5 else 1 end
  from public.jugadores j where j.id = d.jugador_id and j.seccion_id = v_sec and j.consultora = 'Byte Force' and j.correo <> 'demo08@demo.sisope.pe';
  -- Iris y Jorge (demo09, demo10): laboratorios variados
  update public.detalle d set lab = (array[2.5, 3, 1, 2, 3, 3])[d.semana], participacion_grupal = (array['Habló', 'Apoyó', 'Apoyó', 'Lideró', 'Apoyó', 'Lideró'])[d.semana]
  from public.jugadores j where j.id = d.jugador_id and j.correo = 'demo09@demo.sisope.pe';
  update public.detalle d set lab = (array[2, -2, 1.5, 2.5, 2, 2.5])[d.semana], participacion_grupal = (array['Habló', 'No participó', 'Habló', 'Apoyó', 'Habló', 'Apoyó'])[d.semana]
  from public.jugadores j where j.id = d.jugador_id and j.correo = 'demo10@demo.sisope.pe';

  -- 4) Medallas y feedback
  delete from public.medallas m using public.jugadores j where m.jugador_id = j.id and j.seccion_id = v_sec and m.tipo in ('estrella', 'mentor', 'valiente', 'remontada');
  insert into public.medallas (jugador_id, semana, tipo, nota)
  select j.id, v.sem, v.tipo, v.nota from (values
    ('demo02@demo.sisope.pe', 3, 'estrella', 'Lideró la exposición de RAID'),
    ('demo01@demo.sisope.pe', 4, 'mentor', 'Ayudó a su equipo con el dominio'),
    ('demo03@demo.sisope.pe', 6, 'valiente', 'Expuso por primera vez'),
    ('demo04@demo.sisope.pe', 6, 'remontada', 'Pasó de no entregar a lab completo')
  ) as v(correo, sem, tipo, nota) join public.jugadores j on j.correo = v.correo;

  delete from public.feedback f using public.jugadores j where f.jugador_id = j.id and j.seccion_id = v_sec;
  insert into public.feedback (jugador_id, semana, texto, visible_alumno, creado)
  select j.id, v.sem, v.txt, v.vis, now() - (v.dias || ' days')::interval from (values
    ('demo03@demo.sisope.pe', 4, 'Carla, se nota tu avance: ya respondes en el Juego del Miedo. Anímate a exponer una parte del próximo trabajo grupal.', true, 14),
    ('demo04@demo.sisope.pe', 3, 'Diego, llevas 2 laboratorios sin entregar. Conversemos al final de la clase.', false, 21),
    ('demo08@demo.sisope.pe', 5, 'Hugo, tus laboratorios van bien. Intenta dar al menos una idea en el grupo.', true, 7)
  ) as v(correo, sem, txt, vis, dias) join public.jugadores j on j.correo = v.correo;

  -- 5) Reportes: el strike de Diego (script 29) + uno pendiente en Byte Force
  delete from public.eq_reportes where seccion_id = v_sec and estado = 'Pendiente';
  insert into public.eq_reportes (seccion_id, semana, reportante_id, reportado_id, motivo, evidencia, estado, creado)
  select v_sec, 5, (select id from public.jugadores where correo = 'demo07@demo.sisope.pe'), (select id from public.jugadores where correo = 'demo10@demo.sisope.pe'),
         'No subió su parte de los registros DNS y no respondió en el grupo de WhatsApp', 'https://trello.com/b/demo-byteforce', 'Pendiente', now() - interval '6 days';
end $$;

notify pgrst, 'reload schema';

-- Resumen
select j.consultora, j.alias, j.rol_consultora, p.tecnico as mision0, (select count(*) from public.detalle d where d.jugador_id = j.id) as semanas
from public.jugadores j left join public.eq_perfil p on p.jugador_id = j.id
where j.correo like 'demo%@demo.sisope.pe' order by j.consultora, j.correo;
