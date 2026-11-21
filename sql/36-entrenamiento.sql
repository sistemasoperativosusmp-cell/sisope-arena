-- =====================================================================
-- SISOPE Arena · Script 36 · Puntos y Top de los juegos de Entrenamiento (Memoria Técnica y Pupiletras)
-- Reemplaza al antiguo "24_entrenamiento.sql". Se puede volver a ejecutar: no borra partidas.
--   · tabla entrenamiento (cada partida)
--   · registrar_entrenamiento(...)  → valida la partida y calcula los puntos EN EL SERVIDOR
--   · top_entrenamiento(juego, días) → top del aula del alumno (o de todas, si lo llama la docente)
-- Puntos = 10 × pares + precisión (hasta 20) + 2 × mejor racha + rapidez (hasta 20)
-- =====================================================================
create table if not exists public.entrenamiento (
  id         bigint generated always as identity primary key,
  jugador_id uuid not null references public.jugadores(id) on delete cascade,
  juego      text not null default 'memoria',
  mazo       text,
  pares      int  not null,
  intentos   int  not null,
  segundos   int  not null,
  racha      int  not null default 0,
  puntos     int  not null,
  creado     timestamptz not null default now()
);
create index if not exists entrenamiento_jug_idx on public.entrenamiento (jugador_id, juego, creado desc);

alter table public.entrenamiento enable row level security;
drop policy if exists entr_sel_propio on public.entrenamiento;
create policy entr_sel_propio on public.entrenamiento for select to authenticated using (jugador_id = public.mi_jugador_id() or public.es_docente());
drop policy if exists entr_docente_borra on public.entrenamiento;
create policy entr_docente_borra on public.entrenamiento for delete to authenticated using (public.es_docente());
revoke insert, update on public.entrenamiento from anon, authenticated;
grant select, delete on public.entrenamiento to authenticated;

drop function if exists public.registrar_entrenamiento(text, text, int, int, int, int);
create function public.registrar_entrenamiento(p_juego text, p_mazo text, p_pares int, p_intentos int, p_segundos int, p_racha int)
returns int language plpgsql security definer set search_path = public as $$
declare v_id uuid := public.mi_jugador_id(); v_pts int; v_prec numeric; v_vel numeric;
begin
  if v_id is null then raise exception 'Solo las cuentas de alumno suman puntos'; end if;
  if coalesce(p_juego, '') not in ('memoria', 'pupiletras') then raise exception 'Juego no válido'; end if;
  if p_pares is null or p_pares < 3 or p_pares > 12 then raise exception 'Número de pares no válido'; end if;
  if p_intentos is null or p_intentos < p_pares or p_intentos > p_pares * 20 then raise exception 'Intentos no válidos'; end if;
  if p_segundos is null or p_segundos < p_pares * 2 or p_segundos > 7200 then raise exception 'Tiempo no válido'; end if;
  if p_racha is null or p_racha < 0 or p_racha > p_pares then raise exception 'Racha no válida'; end if;
  if (select count(*) from public.entrenamiento where jugador_id = v_id and creado > now() - interval '1 day') >= 40 then
    raise exception 'Llegaste al máximo de 40 partidas por día. ¡Vuelve mañana!';
  end if;
  v_prec := p_pares::numeric / p_intentos;                              -- 1 = sin errores
  v_vel  := greatest(0, 1 - (p_segundos::numeric / p_pares - 3) / 12);  -- ≤3 s por par = máximo; ≥15 s por par = 0
  v_pts  := 10 * p_pares + round(20 * v_prec) + 2 * p_racha + round(20 * v_vel);
  insert into public.entrenamiento (jugador_id, juego, mazo, pares, intentos, segundos, racha, puntos)
  values (v_id, p_juego, left(p_mazo, 120), p_pares, p_intentos, p_segundos, p_racha, v_pts);
  return v_pts;
end $$;

drop function if exists public.top_entrenamiento(text, int);
create function public.top_entrenamiento(p_juego text, p_dias int default null)
returns table (alias text, avatar_url text, total bigint, partidas bigint, mejor int, posicion bigint, es_yo boolean)
language sql stable security definer set search_path = public as $$
  with yo as (select id, seccion_id from public.jugadores where id = public.mi_jugador_id()),
  t as (
    select j.id, j.alias, j.avatar_url, sum(e.puntos) as total, count(*) as partidas, max(e.puntos) as mejor
    from public.entrenamiento e join public.jugadores j on j.id = e.jugador_id and j.activo
    where e.juego = p_juego and (p_dias is null or e.creado > now() - make_interval(days => p_dias))
      and (j.seccion_id = (select seccion_id from yo) or public.es_docente())
    group by j.id, j.alias, j.avatar_url)
  select t.alias, t.avatar_url, t.total, t.partidas, t.mejor, rank() over (order by t.total desc), t.id = (select id from yo)
  from t order by t.total desc, t.alias
$$;

revoke execute on function public.registrar_entrenamiento(text, text, int, int, int, int), public.top_entrenamiento(text, int) from anon, public;
grant execute on function public.registrar_entrenamiento(text, text, int, int, int, int), public.top_entrenamiento(text, int) to authenticated;
notify pgrst, 'reload schema';
