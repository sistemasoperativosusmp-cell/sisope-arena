-- Borra los 10 alumnos demo, sus cuentas y el aula "DEMO Equipos" (no toca nada real)
delete from public.jugadores where correo like 'demo__@demo.sisope.pe'; delete from auth.users where email like 'demo__@demo.sisope.pe'; delete from public.secciones where nombre = 'DEMO Equipos'; notify pgrst, 'reload schema';
