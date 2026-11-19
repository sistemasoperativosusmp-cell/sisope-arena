-- =====================================================================
-- SISOPE Arena · 10 alumnos DEMO para probar Equipos y la Misión 0
-- Ejecutar en Supabase → SQL Editor DESPUÉS de 28-equipos-mision0.sql.
-- Crea el aula "DEMO Equipos" (no toca tus aulas reales) con 10 cuentas:
--   demo01@demo.sisope.pe … demo10@demo.sisope.pe   ·   contraseña: Moto123$
-- demo01–demo08 ya tienen la Misión 0 respondida (perfiles distintos) y 6 semanas
-- de clase simuladas. demo09 y demo10 NO la tienen: entra con ellos para probarla.
-- Se puede volver a ejecutar: reinicia los datos demo.
-- Para borrar todo lo demo, ejecuta 29b-borrar-demo.sql.
-- =====================================================================
do $$
declare
  v_sec int; v_uid uuid; v_jid uuid; a record; s int; v_prac text;
  v_correo text;
begin
  insert into public.secciones (nombre, descripcion, semana_actual)
  values ('DEMO Equipos', 'Aula de prueba con alumnos demo', 6)
  on conflict (nombre) do update set semana_actual = 6, activa = true
  returning id into v_sec;
  begin execute 'update public.secciones set dias = ''{6}'' where id = $1' using v_sec; exception when others then null; end;

  for a in select * from (values
    -- n, nombre, alias, tipo, técnico, comunicación, afinidad (Sales, Preventa, Arquitecto, PM), intentos de escape
    (1,  'DEMO TORRES, Ana',      'DemoAna',    'experta',   90, 40, 40, 60, 95, 70, 0),
    (2,  'DEMO QUISPE, Bruno',    'DemoBruno',  'lider',     70, 92, 90, 65, 50, 85, 0),
    (3,  'DEMO RAMOS, Carla',     'DemoCarla',  'timida',    80, 10, 20, 55, 90, 60, 2),
    (4,  'DEMO FLORES, Diego',    'DemoDiego',  'vago',      30, 60, 60, 40, 30, 35, 3),
    (5,  'DEMO CHÁVEZ, Elena',    'DemoElena',  'promedio',  50, 50, 55, 70, 50, 50, 1),
    (6,  'DEMO MENDOZA, Fabio',   'DemoFabio',  'arquitecto',85, 45, 30, 50, 92, 55, 0),
    (7,  'DEMO VARGAS, Gabriela', 'DemoGaby',   'pm',        60, 55, 45, 60, 55, 90, 1),
    (8,  'DEMO ROJAS, Hugo',      'DemoHugo',   'timido2',   40, 15, 50, 75, 40, 45, 3),
    (9,  'DEMO SALAS, Iris',      'DemoIris',   'sin',     null, null, null, null, null, null, null),
    (10, 'DEMO PAREDES, Jorge',   'DemoJorge',  'sin',     null, null, null, null, null, null, null)
  ) as t(n, nombre, alias, tipo, tec, com, a_sales, a_pre, a_arq, a_pm, esc) loop
    v_correo := 'demo' || lpad(a.n::text, 2, '0') || '@demo.sisope.pe';

    -- Cuenta de acceso (sin obligar a cambiar la contraseña)
    select id into v_uid from auth.users where lower(email) = v_correo;
    if v_uid is null then
      v_uid := gen_random_uuid();
      insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
      values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_correo, extensions.crypt('Moto123$', extensions.gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '', '', '', '', '');
      insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), v_uid::text, v_uid, jsonb_build_object('sub', v_uid::text, 'email', v_correo, 'email_verified', true), 'email', now(), now(), now());
    else
      update auth.users set encrypted_password = extensions.crypt('Moto123$', extensions.gen_salt('bf')), raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) - 'debe_cambiar', updated_at = now() where id = v_uid;
    end if;

    -- Alumno en el aula DEMO, sin equipo (para que lo armes desde Equipos)
    insert into public.jugadores (correo, nombre, alias, seccion_id, user_id, activo, consultora, rol_consultora)
    values (v_correo, a.nombre, a.alias, v_sec, v_uid, true, null, null)
    on conflict (correo) do update set nombre = excluded.nombre, alias = excluded.alias, seccion_id = v_sec, user_id = v_uid, activo = true, consultora = null, rol_consultora = null
    returning id into v_jid;

    -- Reinicia los datos demo de este alumno
    delete from public.eq_perfil where jugador_id = v_jid;
    delete from public.eq_reportes where reportado_id = v_jid or reportante_id = v_jid;
    delete from public.eq_penalidades where jugador_id = v_jid;
    delete from public.detalle where jugador_id = v_jid;
    delete from public.observaciones where jugador_id = v_jid;
    delete from public.medallas where jugador_id = v_jid and tipo in ('sin_miedo', 'lo_intentaste');

    -- Misión 0 ya respondida (excepto demo09 y demo10)
    if a.tec is not null then
      insert into public.eq_perfil (jugador_id, tecnico, comunicacion, afinidad, respuestas, modo_elegido, intentos_escape, enviado)
      values (v_jid, a.tec, a.com, jsonb_build_object('Sales Specialist', a.a_sales, 'Preventa', a.a_pre, 'Arquitecto', a.a_arq, 'Implementador / Project Manager', a.a_pm), '{}', 'reto', a.esc, now() - interval '35 days');
      insert into public.medallas (jugador_id, semana, tipo, nota) values (v_jid, 1, case when a.esc = 0 then 'sin_miedo' else 'lo_intentaste' end, 'Misión 0: Reclutamiento');
    end if;

    -- 6 semanas de clase simuladas: la tímida empieza callada y va hablando; el vago empieza sin entregar y mejora
    for s in 1..6 loop
      select coalesce(practica, 'Practica 1') into v_prac from public.semanas where semana = s;
      insert into public.detalle (jugador_id, semana, practica, asistencia, hora_llegada, lab, quiz, foro_tecnico, foro_analisis, jm_aciertos, jm_fallos, part_vol, participacion_grupal, gr_comunicacion, gr_tecnico, gr_analisis, falta)
      values (v_jid, s, v_prac,
        case when a.tipo = 'vago' and s in (1, 2) then 'Tarde' when a.tipo = 'vago' and s = 3 then 'Ausente' else 'Presente' end,
        case when a.tipo = 'vago' and s in (1, 2) then '19:25'::time end,
        case a.tipo when 'vago' then (array[-2, -2, 0, 2, 2.5, 3])[s] when 'timido2' then (array[2, 2, 2.5, 2, 2.5, 2])[s] when 'experta' then 3 when 'arquitecto' then 3 when 'timida' then (array[3, 3, 2.5, 3, 3, 3])[s] when 'sin' then 2 else 2.5 end,
        case when s in (2, 4) then case a.tipo when 'experta' then 3 when 'vago' then (case when s = 2 then 0.5 else 2 end) when 'timida' then 3 else 2 end end,
        case a.tipo when 'vago' then (case when s <= 3 then 0 else 0.5 end) when 'experta' then 1 when 'timida' then 1 else 0.5 end,
        case a.tipo when 'vago' then (case when s <= 3 then 0 else 0.5 end) when 'lider' then 1 else 0.5 end,
        case a.tipo when 'timida' then (array[0, 0, 0, 1, 2, 2])[s] when 'timido2' then 0 when 'lider' then 2 when 'experta' then 1 when 'vago' then (array[0, 0, 0, 1, 1, 1])[s] else 1 end,
        case a.tipo when 'vago' then (case when s <= 2 then 1 else 0 end) when 'timido2' then 1 else 0 end,
        case a.tipo when 'timida' then (array[0, 0, 0, 1, 1, 2])[s] when 'lider' then 2 when 'timido2' then 0 else 1 end,
        case a.tipo when 'timida' then (array['No participó', 'No participó', 'Intentando', 'Habló', 'Habló', 'Apoyó'])[s] when 'timido2' then 'No participó' when 'lider' then 'Lideró' when 'vago' then (array['No participó', 'No participó', null, 'Habló', 'Apoyó', 'Apoyó'])[s] when 'pm' then 'Lideró' else 'Apoyó' end,
        case a.tipo when 'timida' then (case when s <= 3 then 0 else 0.5 end) when 'timido2' then 0 when 'lider' then 1 else 0.5 end,
        case a.tipo when 'vago' then (case when s <= 3 then 0 else 0.5 end) when 'experta' then 1 when 'arquitecto' then 1 when 'timida' then 1 else 0.5 end,
        case a.tipo when 'vago' then (case when s <= 3 then 0 else 0.5 end) when 'experta' then 1 else 0.5 end,
        case when a.tipo = 'vago' and s = 2 then 0.5 else 0 end);
    end loop;

    -- Etiquetas de la docente
    if a.tipo in ('timida', 'timido2') then insert into public.observaciones (jugador_id, semana, etiquetas) values (v_jid, 1, array['Tímido']); end if;
    if a.tipo = 'vago' then insert into public.observaciones (jugador_id, semana, etiquetas) values (v_jid, 2, array['Flojo']); end if;
  end loop;

  -- Un strike validado para el vago en la semana 2 (lo reportó Elena)
  insert into public.eq_reportes (seccion_id, semana, reportante_id, reportado_id, motivo, evidencia, estado, nota_docente, creado, resuelto)
  select v_sec, 2, (select id from public.jugadores where correo = 'demo05@demo.sisope.pe'), (select id from public.jugadores where correo = 'demo04@demo.sisope.pe'),
         'No entregó su parte del diagrama de red y no respondió en el grupo', null, 'Validado', 'No entregó su parte del trabajo de la semana 2', now() - interval '28 days', now() - interval '27 days';
end $$;

notify pgrst, 'reload schema';

-- Resumen: debe mostrar 10 alumnos demo (8 con Misión 0)
select j.alias, j.correo, p.tecnico, p.comunicacion, (select count(*) from public.detalle d where d.jugador_id = j.id) as semanas
from public.jugadores j left join public.eq_perfil p on p.jugador_id = j.id
where j.correo like 'demo%@demo.sisope.pe' order by j.correo;
