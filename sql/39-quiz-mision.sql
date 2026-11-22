-- =====================================================================
-- SISOPE Arena · Script 39 · Quiz de misión (sin nota) por práctica
-- Se puede volver a ejecutar: no borra preguntas ni respuestas.
--   · mq_preguntas  : banco de preguntas por práctica (lo edita la docente en Ajustes → Quiz de misión)
--                     cada pregunta va ligada a una SEMANA (tema) y, opcionalmente, a un ROL del equipo
--   · mq_respuestas : una respuesta por alumno y práctica (un solo intento)
--   · Se abre solo en la ÚLTIMA semana de cada práctica (según Semanas y temas) y sigue abierto después.
--     Quien no lo respondió cuando su aula ya pasó a la práctica siguiente queda como "deudor":
--     el Juego del Miedo lo elige primero.
--   · Las respuestas correctas nunca llegan al navegador del alumno: se califica en el servidor.
-- =====================================================================
create table if not exists public.mq_preguntas (
  id        bigint generated always as identity primary key,
  practica  int not null check (practica between 1 and 4),
  semana    int,
  rol       text,
  texto     text not null check (length(btrim(texto)) between 5 and 400),
  opciones  jsonb not null,
  correcta  int not null check (correcta between 0 and 3),
  activa    boolean not null default true,
  orden     int not null default 0,
  creado    timestamptz not null default now()
);
create table if not exists public.mq_respuestas (
  id          bigint generated always as identity primary key,
  jugador_id  uuid not null references public.jugadores(id) on delete cascade,
  practica    int not null check (practica between 1 and 4),
  respuestas  jsonb not null,          -- [{"id":12,"op":2,"ok":true,"semana":3,"rol":"Arquitecto"}, ...]
  aciertos    int not null,
  total       int not null,
  tarde       boolean not null default false,
  creado      timestamptz not null default now(),
  unique (jugador_id, practica)
);

alter table public.mq_preguntas enable row level security;
alter table public.mq_respuestas enable row level security;
drop policy if exists mqp_doc on public.mq_preguntas;
create policy mqp_doc on public.mq_preguntas for all to authenticated using (public.es_docente()) with check (public.es_docente());
drop policy if exists mqr_leer on public.mq_respuestas;
create policy mqr_leer on public.mq_respuestas for select to authenticated using (public.es_docente() or jugador_id = public.mi_jugador_id());
drop policy if exists mqr_doc_borra on public.mq_respuestas;
create policy mqr_doc_borra on public.mq_respuestas for delete to authenticated using (public.es_docente());
grant select, insert, update, delete on public.mq_preguntas to authenticated;
grant select, delete on public.mq_respuestas to authenticated;
revoke all on public.mq_preguntas, public.mq_respuestas from anon;

-- Última semana de cada práctica según el plan (Semanas y temas)
create or replace function public.mq_ultima_semana(p int) returns int language sql stable security definer set search_path = public as $$
  select max(semana) from public.semanas where nullif(regexp_replace(coalesce(practica, ''), '\D', '', 'g'), '')::int = p
$$;

-- Estado de los 4 quizzes para el alumno que llama
drop function if exists public.mi_quiz_mision();
create function public.mi_quiz_mision()
returns table (practica int, abre_semana int, estado text, preguntas int, respondido timestamptz)
language sql stable security definer set search_path = public as $$
  with yo as (select j.id, s.semana_actual from public.jugadores j left join public.secciones s on s.id = j.seccion_id where j.id = public.mi_jugador_id())
  select p, u,
    case when r.id is not null then 'respondido'
         when u is null or (select coalesce(semana_actual, 1) from yo) < u then 'proximo'
         when (select coalesce(semana_actual, 1) from yo) > u then 'atrasado'
         else 'abierto' end,
    (select count(*)::int from public.mq_preguntas q where q.practica = p and q.activa),
    r.creado
  from generate_series(1, 4) p
  cross join lateral (select public.mq_ultima_semana(p) as u) x
  left join public.mq_respuestas r on r.practica = p and r.jugador_id = (select id from yo)
  where exists (select 1 from yo)
  order by p
$$;

-- Preguntas para rendir (sin la respuesta correcta). Hasta 10 al azar.
drop function if exists public.quiz_mision_preguntas(int);
create function public.quiz_mision_preguntas(p_practica int)
returns table (id bigint, texto text, opciones jsonb)
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid := public.mi_jugador_id(); v_sem int; v_u int;
begin
  if v_id is null then raise exception 'Solo para alumnos'; end if;
  select s.semana_actual into v_sem from public.jugadores j left join public.secciones s on s.id = j.seccion_id where j.id = v_id;
  v_u := public.mq_ultima_semana(p_practica);
  if v_u is null or coalesce(v_sem, 1) < v_u then raise exception 'Este quiz todavía no está abierto'; end if;
  if exists (select 1 from public.mq_respuestas r where r.jugador_id = v_id and r.practica = p_practica) then raise exception 'Ya respondiste este quiz'; end if;
  return query select q.id, q.texto, q.opciones from public.mq_preguntas q where q.practica = p_practica and q.activa order by random() limit 10;
end $$;

-- Enviar respuestas: p_resp = [{"id": 12, "op": 2}, ...]  (op = índice de la alternativa original, -1 = en blanco)
drop function if exists public.responder_quiz_mision(int, jsonb);
create function public.responder_quiz_mision(p_practica int, p_resp jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare v_id uuid := public.mi_jugador_id(); v_sem int; v_u int; v_det jsonb; v_ok int; v_tot int;
begin
  if v_id is null then raise exception 'Solo para alumnos'; end if;
  select s.semana_actual into v_sem from public.jugadores j left join public.secciones s on s.id = j.seccion_id where j.id = v_id;
  v_u := public.mq_ultima_semana(p_practica);
  if v_u is null or coalesce(v_sem, 1) < v_u then raise exception 'Este quiz todavía no está abierto'; end if;
  if jsonb_typeof(p_resp) <> 'array' or jsonb_array_length(p_resp) = 0 or jsonb_array_length(p_resp) > 10 then raise exception 'Respuestas no válidas'; end if;
  select jsonb_agg(jsonb_build_object('id', q.id, 'op', (e->>'op')::int, 'ok', (e->>'op')::int = q.correcta, 'semana', q.semana, 'rol', q.rol)),
         count(*) filter (where (e->>'op')::int = q.correcta), count(*)
    into v_det, v_ok, v_tot
  from (select distinct on ((x->>'id')::bigint) x as e from jsonb_array_elements(p_resp) x) r
  join public.mq_preguntas q on q.id = (r.e->>'id')::bigint and q.practica = p_practica;
  if coalesce(v_tot, 0) = 0 then raise exception 'Respuestas no válidas'; end if;
  insert into public.mq_respuestas (jugador_id, practica, respuestas, aciertos, total, tarde)
  values (v_id, p_practica, v_det, v_ok, v_tot, coalesce(v_sem, 1) > v_u)
  on conflict (jugador_id, practica) do nothing;
  if not found then raise exception 'Ya respondiste este quiz'; end if;
  return v_tot;
end $$;

revoke execute on function public.mq_ultima_semana(int), public.mi_quiz_mision(), public.quiz_mision_preguntas(int), public.responder_quiz_mision(int, jsonb) from anon, public;
grant execute on function public.mq_ultima_semana(int), public.mi_quiz_mision(), public.quiz_mision_preguntas(int), public.responder_quiz_mision(int, jsonb) to authenticated;
notify pgrst, 'reload schema';
