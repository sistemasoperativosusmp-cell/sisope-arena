-- Parche 36b: el top siempre muestra tus propias partidas (aunque tu cuenta no tenga sección o esté inactiva)
drop function if exists public.top_entrenamiento(text, int, bigint);   -- versión antigua del otro chat (24)
drop function if exists public.top_entrenamiento(text, int);
create function public.top_entrenamiento(p_juego text, p_dias int default null)
returns table (alias text, avatar_url text, total bigint, partidas bigint, mejor int, posicion bigint, es_yo boolean)
language sql stable security definer set search_path = public as $$
  with yo as (select id, seccion_id from public.jugadores where id = public.mi_jugador_id()),
  t as (
    select j.id, j.alias::text as alias, j.avatar_url::text as avatar_url, sum(e.puntos)::bigint as total, count(*)::bigint as partidas, max(e.puntos)::int as mejor
    from public.entrenamiento e join public.jugadores j on j.id = e.jugador_id
    where e.juego = p_juego and (p_dias is null or e.creado > now() - make_interval(days => p_dias))
      and (j.id = (select id from yo)                                   -- uno mismo siempre se ve
           or (j.activo and (j.seccion_id = (select seccion_id from yo) or public.es_docente())))
    group by j.id, j.alias, j.avatar_url)
  select t.alias, t.avatar_url, t.total, t.partidas, t.mejor, (rank() over (order by t.total desc))::bigint, coalesce(t.id = (select id from yo), false)
  from t order by t.total desc, t.alias
$$;
grant execute on function public.top_entrenamiento(text, int) to authenticated;
revoke execute on function public.top_entrenamiento(text, int) from anon, public;
notify pgrst, 'reload schema';
