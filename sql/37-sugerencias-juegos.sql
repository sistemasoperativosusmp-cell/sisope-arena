-- =====================================================================
-- SISOPE Arena · Script 37 · Sugerencias anónimas por juego (Entrenamiento)
-- Se puede volver a ejecutar sin borrar sugerencias.
--   · El alumno publica una sugerencia SIN su nombre para su aula y apoya otras con 👍.
--   · La docente responde u oculta (por ejemplo, si es ofensiva).
--   · Ni los compañeros ni la docente ven quién escribió cada sugerencia: las funciones nunca lo devuelven.
--     El autor solo se usa para el límite de 5 por día y para el 👍 propio.
-- =====================================================================
create table if not exists public.sugerencias (
  id          bigint generated always as identity primary key,
  juego       text not null default 'memoria',
  seccion_id  int references public.secciones(id) on delete cascade,
  jugador_id  uuid references public.jugadores(id) on delete set null,
  texto       text not null check (length(btrim(texto)) between 5 and 300),
  respuesta   text,
  respondido  timestamptz,
  oculta      boolean not null default false,
  creado      timestamptz not null default now()
);
create index if not exists sugerencias_juego_idx on public.sugerencias (juego, seccion_id, creado desc);
create table if not exists public.sugerencia_votos (
  sugerencia_id bigint not null references public.sugerencias(id) on delete cascade,
  jugador_id    uuid not null references public.jugadores(id) on delete cascade,
  primary key (sugerencia_id, jugador_id)
);
-- Nadie lee ni escribe las tablas directo (así el autor nunca se expone); todo pasa por las funciones de abajo
alter table public.sugerencias enable row level security;
alter table public.sugerencia_votos enable row level security;
revoke all on public.sugerencias, public.sugerencia_votos from anon, authenticated;

-- Publicar (alumno)
create or replace function public.sugerir(p_juego text, p_texto text) returns bigint language plpgsql security definer set search_path = public as $$
declare v_id uuid := public.mi_jugador_id(); v_sec int; v_t text := btrim(coalesce(p_texto, '')); v_new bigint;
begin
  if v_id is null then raise exception 'Solo los alumnos pueden enviar sugerencias'; end if;
  if length(v_t) < 5 then raise exception 'Escribe tu sugerencia (mínimo 5 caracteres)'; end if;
  if length(v_t) > 300 then raise exception 'Máximo 300 caracteres'; end if;
  if (select count(*) from public.sugerencias where jugador_id = v_id and creado > now() - interval '1 day') >= 5 then raise exception 'Ya enviaste 5 sugerencias hoy. ¡Gracias! Vuelve mañana.'; end if;
  select seccion_id into v_sec from public.jugadores where id = v_id;
  insert into public.sugerencias (juego, seccion_id, jugador_id, texto) values (coalesce(nullif(btrim(p_juego), ''), 'memoria'), v_sec, v_id, v_t) returning id into v_new;
  return v_new;
end $$;

-- Listar (alumno: las visibles de su aula · docente: todas, con aula y estado)
create or replace function public.sugerencias_juego(p_juego text) returns table (id bigint, texto text, respuesta text, creado timestamptz, votos bigint, mi_voto boolean, mia boolean, oculta boolean, aula text)
language sql stable security definer set search_path = public as $$
  select s.id, s.texto, s.respuesta, s.creado,
         (select count(*) from public.sugerencia_votos v where v.sugerencia_id = s.id),
         exists (select 1 from public.sugerencia_votos v where v.sugerencia_id = s.id and v.jugador_id = public.mi_jugador_id()),
         s.jugador_id = public.mi_jugador_id(), s.oculta, (select nombre from public.secciones where id = s.seccion_id)
  from public.sugerencias s
  where s.juego = p_juego and (public.es_docente() or (not s.oculta and s.seccion_id = (select seccion_id from public.jugadores where id = public.mi_jugador_id())))
  order by (select count(*) from public.sugerencia_votos v where v.sugerencia_id = s.id) desc, s.creado desc
  limit 100
$$;

-- 👍 Me sumo (alterna)
create or replace function public.votar_sugerencia(p_id bigint) returns boolean language plpgsql security definer set search_path = public as $$
declare v_id uuid := public.mi_jugador_id();
begin
  if v_id is null then raise exception 'Solo los alumnos pueden votar'; end if;
  if not exists (select 1 from public.sugerencias s where s.id = p_id and not s.oculta and s.seccion_id = (select seccion_id from public.jugadores where id = v_id)) then raise exception 'Sugerencia no encontrada'; end if;
  if exists (select 1 from public.sugerencia_votos where sugerencia_id = p_id and jugador_id = v_id) then
    delete from public.sugerencia_votos where sugerencia_id = p_id and jugador_id = v_id; return false;
  end if;
  insert into public.sugerencia_votos (sugerencia_id, jugador_id) values (p_id, v_id); return true;
end $$;

-- Docente: responder, ocultar/mostrar y borrar
create or replace function public.moderar_sugerencia(p_id bigint, p_accion text, p_respuesta text default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.es_docente() then raise exception 'Solo docentes'; end if;
  if p_accion = 'responder' then update public.sugerencias set respuesta = nullif(btrim(coalesce(p_respuesta, '')), ''), respondido = now() where id = p_id;
  elsif p_accion = 'ocultar' then update public.sugerencias set oculta = true where id = p_id;
  elsif p_accion = 'mostrar' then update public.sugerencias set oculta = false where id = p_id;
  elsif p_accion = 'borrar' then delete from public.sugerencias where id = p_id;
  else raise exception 'Acción no válida'; end if;
end $$;

revoke execute on function public.sugerir(text, text), public.sugerencias_juego(text), public.votar_sugerencia(bigint), public.moderar_sugerencia(bigint, text, text) from anon, public;
grant execute on function public.sugerir(text, text), public.sugerencias_juego(text), public.votar_sugerencia(bigint), public.moderar_sugerencia(bigint, text, text) to authenticated;
notify pgrst, 'reload schema';
