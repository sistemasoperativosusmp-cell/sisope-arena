alter table public.detalle add column if not exists se_escapo boolean not null default false, add column if not exists hora_salida time; notify pgrst, 'reload schema';
