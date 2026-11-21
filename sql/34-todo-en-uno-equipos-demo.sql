-- =====================================================================
-- SISOPE Arena · TODO EN UNO: Equipos + Misión 0 + demo con 2 equipos
-- Pega TODO en Supabase → SQL Editor y pulsa Run. Se puede volver a ejecutar sin perder datos reales:
-- solo reinicia los datos del aula "DEMO Equipos" (cuentas demo01…demo10@demo.sisope.pe, clave Moto123$).
-- Requiere que ya estén aplicados los scripts 01 al 27.
-- Para borrar lo demo: delete from public.jugadores where correo like 'demo__@demo.sisope.pe'; delete from auth.users where email like 'demo__@demo.sisope.pe'; delete from public.secciones where nombre = 'DEMO Equipos';
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1/7 · Sección Equipos y Misión 0 (script 28)
-- ---------------------------------------------------------------------
-- =====================================================================
-- SISOPE Arena · Sección EQUIPOS (Misión 0: Reclutamiento + strikes)
-- Ejecutar completo en Supabase → SQL Editor. Se puede volver a ejecutar
-- sin perder datos (solo crea lo que falta y reemplaza funciones).
--   · eq_preguntas     preguntas de la evaluación (técnicas y de perfil)
--   · eq_perfil        resultado de cada alumno (nivel técnico, comunicación, afinidad por rol)
--   · eq_reportes      reportes entre compañeros (strikes) que valida la docente
--   · eq_penalidades   penalidad asignada al llegar a 3 strikes
--   · eq_cambios_rol   historial de cambios de rol / equipo
-- Además: los alumnos YA NO pueden elegir su propio rol (cambiar_mi_rol queda bloqueado).
-- =====================================================================

-- 1) Tablas (el tipo de jugador_id se copia de jugadores.id, sea uuid o número)
do $$
declare tj text; ts text;
begin
  select format_type(a.atttypid, a.atttypmod) into tj from pg_attribute a
   where a.attrelid = 'public.jugadores'::regclass and a.attname = 'id';
  select format_type(a.atttypid, a.atttypmod) into ts from pg_attribute a
   where a.attrelid = 'public.secciones'::regclass and a.attname = 'id';

  create table if not exists public.eq_preguntas (
    id       int generated always as identity primary key,
    parte    text not null check (parte in ('tecnica', 'perfil')),
    orden    int  not null default 0,
    texto    text not null,
    opciones jsonb,            -- técnica: lista de alternativas
    correcta int,              -- técnica: índice (0..n-1) de la alternativa correcta
    pesos    jsonb,            -- perfil: {"Arquitecto":1, "com":1} ; com negativo = pregunta inversa
    activa   boolean not null default true
  );

  execute format($f$create table if not exists public.eq_perfil (
    jugador_id      %1$s primary key references public.jugadores(id) on delete cascade,
    tecnico         numeric not null default 0,      -- 0..100
    comunicacion    numeric not null default 50,     -- 0..100 (alto = le gusta exponer)
    afinidad        jsonb   not null default '{}',   -- {"Arquitecto": 80, ...} 0..100
    respuestas      jsonb   not null default '{}',
    modo_elegido    text    not null default 'reto',
    intentos_escape int     not null default 0,
    enviado         timestamptz not null default now())$f$, tj);

  execute format($f$create table if not exists public.eq_reportes (
    id            bigint generated always as identity primary key,
    seccion_id    %2$s,
    semana        int,
    reportante_id %1$s references public.jugadores(id) on delete cascade,
    reportado_id  %1$s references public.jugadores(id) on delete cascade,
    motivo        text not null,
    evidencia     text,
    estado        text not null default 'Pendiente' check (estado in ('Pendiente', 'Validado', 'Rechazado')),
    nota_docente  text,
    creado        timestamptz not null default now(),
    resuelto      timestamptz)$f$, tj, ts);

  execute format($f$create table if not exists public.eq_penalidades (
    jugador_id %1$s primary key references public.jugadores(id) on delete cascade,
    penalidad  text not null,
    nota       text,
    estado     text not null default 'Pendiente' check (estado in ('Pendiente', 'Cumplida')),
    creado     timestamptz not null default now())$f$, tj);

  execute format($f$create table if not exists public.eq_cambios_rol (
    id               bigint generated always as identity primary key,
    jugador_id       %1$s references public.jugadores(id) on delete cascade,
    consultora_antes text, consultora_nueva text,
    rol_antes        text, rol_nuevo text,
    origen           text,               -- 'automatico' | 'manual'
    por              text default (auth.jwt() ->> 'email'),
    creado           timestamptz not null default now())$f$, tj);
end $$;

create index if not exists eq_reportes_sec on public.eq_reportes (seccion_id, estado);
create index if not exists eq_reportes_rep on public.eq_reportes (reportado_id, estado);

-- 2) Seguridad: solo la docente lee/escribe estas tablas directamente.
--    Los alumnos usan únicamente las funciones de abajo.
do $$
declare t text;
begin
  foreach t in array array['eq_preguntas', 'eq_perfil', 'eq_reportes', 'eq_penalidades', 'eq_cambios_rol'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists eq_docente on public.%I', t);
    execute format('create policy eq_docente on public.%I for all to authenticated using (public.es_docente()) with check (public.es_docente())', t);
  end loop;
end $$;

-- 3) Preguntas para el alumno (sin la respuesta correcta ni los pesos)
create or replace function public.eq_preguntas_alumno()
returns table (id int, parte text, orden int, texto text, opciones jsonb)
language sql stable security definer set search_path = public as $$
  select id, parte, orden, texto, opciones from public.eq_preguntas
   where activa order by case parte when 'tecnica' then 0 else 1 end, orden, id
$$;

-- 4) Enviar la evaluación: califica, calcula la afinidad por rol y entrega la medalla
--    p_resp = {"<id pregunta>": valor}  (técnica: índice de alternativa · perfil: 1..5)
create or replace function public.eq_enviar(p_resp jsonb, p_modo text default 'reto', p_intentos int default 0)
returns text language plpgsql security definer set search_path = public as $$
declare
  yo record; q record; v numeric; k text; w numeric;
  tot int := 0; ok int := 0; cn numeric := 0; cd numeric := 0;
  num jsonb := '{}'; den jsonb := '{}'; afin jsonb := '{}';
  sem int; tipo text;
begin
  select j.id, j.seccion_id into yo from public.jugadores j
   where lower(j.correo) = lower(auth.jwt() ->> 'email') and coalesce(j.activo, true) limit 1;
  if not found then raise exception 'No encontramos tu registro de alumno'; end if;
  if exists (select 1 from public.eq_perfil where jugador_id = yo.id) then
    raise exception 'Ya completaste la Misión 0. Si necesitas repetirla, habla con tu docente.';
  end if;

  for q in select * from public.eq_preguntas where activa loop
    if q.parte = 'tecnica' then
      tot := tot + 1;
      if p_resp ? q.id::text and (p_resp ->> q.id::text)::int = q.correcta then ok := ok + 1; end if;
      continue;
    end if;
    if not (p_resp ? q.id::text) then continue; end if;
    v := (p_resp ->> q.id::text)::numeric;
    if v < 1 or v > 5 then raise exception 'Respuesta fuera de rango'; end if;
    for k, w in select e.key, e.value::numeric from jsonb_each_text(coalesce(q.pesos, '{}')) e loop
      if k = 'com' then
        cn := cn + abs(w) * (case when w < 0 then 6 - v else v end);
        cd := cd + abs(w) * 5;
      elsif w > 0 then
        num := jsonb_set(num, array[k], to_jsonb(coalesce((num ->> k)::numeric, 0) + w * v));
        den := jsonb_set(den, array[k], to_jsonb(coalesce((den ->> k)::numeric, 0) + w * 5));
      end if;
    end loop;
  end loop;

  for k in select jsonb_object_keys(den) loop
    afin := jsonb_set(afin, array[k], to_jsonb(round(100 * (num ->> k)::numeric / nullif((den ->> k)::numeric, 0), 1)));
  end loop;

  insert into public.eq_perfil (jugador_id, tecnico, comunicacion, afinidad, respuestas, modo_elegido, intentos_escape)
  values (yo.id,
          case when tot > 0 then round(100.0 * ok / tot, 1) else 0 end,
          case when cd > 0 then round(100 * cn / cd, 1) else 50 end,
          afin, p_resp, coalesce(nullif(p_modo, ''), 'reto'), greatest(coalesce(p_intentos, 0), 0));

  tipo := case when coalesce(p_intentos, 0) = 0 then 'sin_miedo' else 'lo_intentaste' end;
  select semana_actual into sem from public.secciones where id = yo.seccion_id;
  begin
    insert into public.medallas (jugador_id, semana, tipo, nota) values (yo.id, coalesce(sem, 1), tipo, 'Misión 0: Reclutamiento');
  exception when others then null;  -- si la tabla de medallas no acepta el tipo, la evaluación igual se guarda
  end;
  return tipo;
end $$;

-- 5) Estado del alumno: si ya hizo la evaluación, sus strikes y su penalidad (nunca quién lo reportó).
--    Si la docente escribe una nota al validar, el alumno ve esa nota en lugar del texto del compañero.
create or replace function public.eq_mi_estado()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare yo record;
begin
  select j.id into yo from public.jugadores j where lower(j.correo) = lower(auth.jwt() ->> 'email') limit 1;
  if not found then return jsonb_build_object('evaluado', false, 'strikes', 0); end if;
  return jsonb_build_object(
    'evaluado', exists (select 1 from public.eq_perfil where jugador_id = yo.id),
    'strikes', (select count(*) from public.eq_reportes where reportado_id = yo.id and estado = 'Validado'),
    'motivos', coalesce((select jsonb_agg(jsonb_build_object('semana', semana, 'motivo', coalesce(nullif(nota_docente, ''), motivo)) order by creado)
                           from public.eq_reportes where reportado_id = yo.id and estado = 'Validado'), '[]'),
    'penalidad', (select jsonb_build_object('penalidad', penalidad, 'nota', nota, 'estado', estado)
                    from public.eq_penalidades where jugador_id = yo.id),
    'reportes_semana', (select count(*) from public.eq_reportes where reportante_id = yo.id and creado > now() - interval '7 days'));
end $$;

-- 6) Reportar a un compañero de la MISMA consultora (lo valida la docente)
create or replace function public.eq_reportar(p_alias text, p_motivo text, p_evidencia text default null)
returns text language plpgsql security definer set search_path = public as $$
declare yo record; el record; sem int;
begin
  select j.id, j.seccion_id, j.consultora into yo from public.jugadores j
   where lower(j.correo) = lower(auth.jwt() ->> 'email') and coalesce(j.activo, true) limit 1;
  if not found then raise exception 'No encontramos tu registro de alumno'; end if;
  if yo.consultora is null then raise exception 'Aún no tienes equipo'; end if;
  select j.id, j.alias into el from public.jugadores j
   where j.alias = p_alias and j.seccion_id = yo.seccion_id and j.consultora = yo.consultora and coalesce(j.activo, true) limit 1;
  if not found then raise exception 'Solo puedes reportar a un integrante de tu consultora'; end if;
  if el.id = yo.id then raise exception 'No puedes reportarte a ti mismo'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 15 then raise exception 'Describe el motivo con más detalle (mínimo 15 caracteres)'; end if;
  select semana_actual into sem from public.secciones where id = yo.seccion_id;
  if exists (select 1 from public.eq_reportes where reportante_id = yo.id and reportado_id = el.id
               and coalesce(semana, -1) = coalesce(sem, -1) and estado <> 'Rechazado') then
    raise exception 'Ya reportaste a % esta semana', el.alias;
  end if;
  if (select count(*) from public.eq_reportes where reportante_id = yo.id and creado > now() - interval '7 days') >= 3 then
    raise exception 'Llegaste al máximo de 3 reportes por semana';
  end if;
  insert into public.eq_reportes (seccion_id, semana, reportante_id, reportado_id, motivo, evidencia)
  values (yo.seccion_id, sem, yo.id, el.id, trim(p_motivo), nullif(trim(coalesce(p_evidencia, '')), ''));
  return el.alias;
end $$;

-- 7) Los roles ahora los asigna SOLO la docente: el alumno ya no puede cambiar el suyo
drop function if exists public.cambiar_mi_rol(text);
create function public.cambiar_mi_rol(p_rol text)
returns text language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Los roles los asigna tu docente según la Misión 0.';
end $$;

-- 8) Permisos de ejecución: solo usuarios con sesión iniciada
revoke all on function public.eq_preguntas_alumno() from public, anon;
revoke all on function public.eq_enviar(jsonb, text, int) from public, anon;
revoke all on function public.eq_mi_estado() from public, anon;
revoke all on function public.eq_reportar(text, text, text) from public, anon;
grant execute on function public.eq_preguntas_alumno() to authenticated;
grant execute on function public.eq_enviar(jsonb, text, int) to authenticated;
grant execute on function public.eq_mi_estado() to authenticated;
grant execute on function public.eq_reportar(text, text, text) to authenticated;
grant execute on function public.cambiar_mi_rol(text) to authenticated;

-- 9) Preguntas iniciales (solo si la tabla está vacía). Edítalas luego en Table Editor → eq_preguntas.
--    Los nombres de los roles deben coincidir EXACTO con los de la app.
insert into public.eq_preguntas (parte, orden, texto, opciones, correcta, pesos)
select * from (values
  ('tecnica', 1, '¿Qué tipo de hipervisor se instala directamente sobre el hardware, sin un sistema operativo anfitrión?', '["Tipo 1 (bare-metal)","Tipo 2 (hosted)","Un contenedor Docker","Un emulador de consola"]'::jsonb, 0, null::jsonb),
  ('tecnica', 2, 'En una red /24, ¿cuántas direcciones IP quedan disponibles para equipos?', '["256","255","254","24"]', 2, null),
  ('tecnica', 3, '¿Qué servicio traduce un nombre como www.usmp.edu.pe a una dirección IP?', '["DHCP","DNS","ARP","SMTP"]', 1, null),
  ('tecnica', 4, '¿Qué servicio entrega automáticamente una dirección IP a los equipos de una red?', '["DNS","NAT","DHCP","FTP"]', 2, null),
  ('tecnica', 5, '¿Cuál es la principal diferencia entre un contenedor y una máquina virtual?', '["El contenedor comparte el kernel del sistema anfitrión","El contenedor trae su propio kernel completo","La máquina virtual no necesita hipervisor","No hay diferencia, son lo mismo"]', 0, null),
  ('tecnica', 6, 'Un snapshot de una máquina virtual…', '["Es un respaldo completo y suficiente ante cualquier desastre","Guarda el estado de la VM para volver a ese punto, pero no reemplaza un respaldo","Es una copia de la ISO de instalación","Es un tipo de antivirus"]', 1, null),
  ('tecnica', 7, '¿Qué nivel de RAID mantiene una copia idéntica (espejo) en dos discos?', '["RAID 0","RAID 1","RAID 5","JBOD"]', 1, null),
  ('tecnica', 8, 'El principio de mínimo privilegio consiste en…', '["Dar permisos de administrador a todos para evitar tickets","Dar a cada usuario solo los permisos que necesita para su trabajo","Usar contraseñas cortas y fáciles","Desactivar el firewall en la red interna"]', 1, null),
  ('tecnica', 9, '¿Qué puerto usa por defecto el Escritorio Remoto (RDP)?', '["22","443","3389","53"]', 2, null),
  ('tecnica', 10, 'En la nube, IaaS significa que…', '["Usas una aplicación lista, como el correo web","Alquilas infraestructura (VMs, red, almacenamiento) y tú administras el sistema operativo","Solo subes código sin preocuparte del servidor","Compras los servidores físicos"]', 1, null),
  ('perfil', 1, 'Me siento cómodo explicando una solución técnica a alguien que no es técnico.', null, null, '{"Sales Specialist":1,"com":0.5}'),
  ('perfil', 2, 'Me gusta convencer a otros de que una idea es la mejor opción.', null, null, '{"Sales Specialist":1}'),
  ('perfil', 3, 'Disfruto investigar casos de éxito y comparar empresas o productos del mercado.', null, null, '{"Sales Specialist":1,"Preventa":0.5}'),
  ('perfil', 4, 'Me gusta calcular costos, licencias o presupuestos.', null, null, '{"Preventa":1}'),
  ('perfil', 5, 'Disfruto comparar tecnologías para decidir cuál le conviene más al cliente.', null, null, '{"Preventa":1,"Arquitecto":0.5}'),
  ('perfil', 6, 'Leo la letra pequeña: requisitos, condiciones y licenciamiento.', null, null, '{"Preventa":1}'),
  ('perfil', 7, 'Me gusta dibujar diagramas de cómo se conectan servidores y redes.', null, null, '{"Arquitecto":1}'),
  ('perfil', 8, 'Disfruto dimensionar recursos: CPU, RAM, disco y direcciones IP.', null, null, '{"Arquitecto":1}'),
  ('perfil', 9, 'Cuando algo técnico falla, quiero entender por qué antes de seguir.', null, null, '{"Arquitecto":1,"Implementador / Project Manager":0.5}'),
  ('perfil', 10, 'Me gusta organizar tareas, fechas y responsables.', null, null, '{"Implementador / Project Manager":1}'),
  ('perfil', 11, 'Prefiero configurar y ejecutar antes que planificar en papel.', null, null, '{"Implementador / Project Manager":1}'),
  ('perfil', 12, 'Suelo anticipar qué puede salir mal y cómo evitarlo.', null, null, '{"Implementador / Project Manager":1,"Arquitecto":0.5}'),
  ('perfil', 13, 'Me siento cómodo exponiendo frente a la clase.', null, null, '{"com":1,"Sales Specialist":0.5}'),
  ('perfil', 14, 'En un grupo, suelo ser quien toma la palabra primero.', null, null, '{"com":1}'),
  ('perfil', 15, 'Prefiero trabajar en segundo plano y que otro presente.', null, null, '{"com":-1}')
) as v(parte, orden, texto, opciones, correcta, pesos)
where not exists (select 1 from public.eq_preguntas);

-- 10) Acceso de la app a las tablas (la seguridad real la ponen las políticas RLS de arriba: solo la docente)
grant select, insert, update, delete on public.eq_preguntas, public.eq_perfil, public.eq_reportes, public.eq_penalidades, public.eq_cambios_rol to authenticated;
grant usage, select on all sequences in schema public to authenticated;
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 2/7 · Permisos de la app sobre las tablas de Equipos
-- ---------------------------------------------------------------------
grant select, insert, update, delete on public.eq_preguntas, public.eq_perfil, public.eq_reportes, public.eq_penalidades, public.eq_cambios_rol to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- ---------------------------------------------------------------------
-- 3/7 · Asistencia: se escapó de clase (script 30)
-- ---------------------------------------------------------------------
alter table public.detalle add column if not exists se_escapo boolean not null default false, add column if not exists hora_salida time; notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 4/7 · Nombres de los temas de la Misión 0 (script 31)
-- ---------------------------------------------------------------------
alter table public.eq_preguntas add column if not exists tema text; update public.eq_preguntas set tema = case orden when 1 then 'Hipervisores (tipo 1 y tipo 2)' when 2 then 'Direccionamiento IP y subredes' when 3 then 'DNS' when 4 then 'DHCP' when 5 then 'Contenedores vs. máquinas virtuales' when 6 then 'Snapshots y respaldos' when 7 then 'RAID y almacenamiento' when 8 then 'Mínimo privilegio y permisos' when 9 then 'Puertos y acceso remoto (RDP)' when 10 then 'Modelos de nube (IaaS, PaaS, SaaS)' end where parte = 'tecnica' and tema is null; notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 5/7 · Progreso semanal del equipo para el alumno (script 32)
-- ---------------------------------------------------------------------
create or replace function public.mi_equipo_semanas() returns table (semana int, tema text, equipo numeric, clase numeric, grupal_equipo numeric, grupal_clase numeric) language sql stable security definer set search_path = public as $$ with yo as (select seccion_id, consultora from public.jugadores where id = public.mi_jugador_id()), d as (select d.semana, j.consultora, public.puntos(d) as p, coalesce(d.gr_comunicacion, 0) + coalesce(d.gr_tecnico, 0) + coalesce(d.gr_analisis, 0) + d.extra - d.falta as g, (d.gr_comunicacion is not null or d.gr_tecnico is not null or d.gr_analisis is not null) as gok from public.detalle d join public.jugadores j on j.id = d.jugador_id and j.activo join yo on j.seccion_id = yo.seccion_id) select d.semana, max(s.tema), round(avg(d.p) filter (where d.consultora = (select consultora from yo)), 2), round(avg(d.p), 2), round(avg(d.g) filter (where d.gok and d.consultora = (select consultora from yo)), 2), round(avg(d.g) filter (where d.gok), 2) from d left join public.semanas s on s.semana = d.semana where (select consultora from yo) is not null group by d.semana order by d.semana $$; revoke execute on function public.mi_equipo_semanas() from anon, public; grant execute on function public.mi_equipo_semanas() to authenticated; notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 6/7 · 10 alumnos demo en el aula DEMO Equipos (script 29)
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- 7/7 · 2 equipos demo con datos realistas (script 33)
-- ---------------------------------------------------------------------
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
