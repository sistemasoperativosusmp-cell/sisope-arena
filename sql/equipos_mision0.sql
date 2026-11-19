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
