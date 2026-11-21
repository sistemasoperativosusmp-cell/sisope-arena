-- =====================================================================
-- SISOPE Arena · Script 38 · Temas del Pupiletras editables (Ajustes → Pupiletras)
-- Se puede volver a ejecutar: la carga inicial de 6 temas solo se hace si no hay temas.
--   · pupi_temas     : temas (nombre, activo, orden)
--   · pupi_palabras  : palabras correctas e intrusas de cada tema, con su explicación
--     palabra  = lo que se esconde en la sopa (solo letras; se limpian tildes, espacios y signos)
--     mostrar  = cómo se ve en la lista (opcional, ej. "Hyper-V" para la palabra HYPERV)
-- =====================================================================
create table if not exists public.pupi_temas (
  id     bigint generated always as identity primary key,
  nombre text not null check (length(btrim(nombre)) between 2 and 60),
  activo boolean not null default true,
  orden  int not null default 0,
  creado timestamptz not null default now()
);
create table if not exists public.pupi_palabras (
  id          bigint generated always as identity primary key,
  tema_id     bigint not null references public.pupi_temas(id) on delete cascade,
  palabra     text not null,
  clave       text generated always as (regexp_replace(upper(translate(palabra, 'áéíóúÁÉÍÓÚñÑüÜ', 'aeiouAEIOUnNuU')), '[^A-Z]', '', 'g')) stored,
  mostrar     text,
  explicacion text,
  intruso     boolean not null default false,
  creado      timestamptz not null default now(),
  constraint pupi_clave_largo check (length(regexp_replace(upper(translate(palabra, 'áéíóúÁÉÍÓÚñÑüÜ', 'aeiouAEIOUnNuU')), '[^A-Z]', '', 'g')) between 2 and 12)
);
create index if not exists pupi_palabras_tema on public.pupi_palabras (tema_id);

alter table public.pupi_temas enable row level security;
alter table public.pupi_palabras enable row level security;
drop policy if exists pupi_t_leer on public.pupi_temas;
create policy pupi_t_leer on public.pupi_temas for select to authenticated using (activo or public.es_docente());
drop policy if exists pupi_t_doc on public.pupi_temas;
create policy pupi_t_doc on public.pupi_temas for all to authenticated using (public.es_docente()) with check (public.es_docente());
drop policy if exists pupi_p_leer on public.pupi_palabras;
create policy pupi_p_leer on public.pupi_palabras for select to authenticated using (public.es_docente() or exists (select 1 from public.pupi_temas t where t.id = tema_id and t.activo));
drop policy if exists pupi_p_doc on public.pupi_palabras;
create policy pupi_p_doc on public.pupi_palabras for all to authenticated using (public.es_docente()) with check (public.es_docente());
grant select, insert, update, delete on public.pupi_temas, public.pupi_palabras to authenticated;
revoke all on public.pupi_temas, public.pupi_palabras from anon;

-- Carga inicial: los 6 temas que traía el juego
do $$
declare r record; v_tema bigint; v_last int := 0;
begin
  if exists (select 1 from public.pupi_temas) then return; end if;
  for r in select * from (values
(1, 'Hipervisores y virtualización', 'VIRTUALBOX', 'VirtualBox', 'Hipervisor tipo 2 gratuito de Oracle: corre sobre Windows, Linux o macOS.', false),
(1, 'Hipervisores y virtualización', 'HYPERV', 'Hyper-V', 'Hipervisor tipo 1 de Microsoft, incluido en Windows Server y Windows Pro.', false),
(1, 'Hipervisores y virtualización', 'VMWARE', 'VMware', 'Fabricante de vSphere/ESXi y Workstation (hoy parte de Broadcom).', false),
(1, 'Hipervisores y virtualización', 'XENSERVER', 'XenServer', 'Hipervisor tipo 1 basado en Xen; antes se llamó Citrix Hypervisor.', false),
(1, 'Hipervisores y virtualización', 'KVM', 'KVM', 'Hipervisor integrado en el kernel de Linux.', false),
(1, 'Hipervisores y virtualización', 'PROXMOX', 'Proxmox', 'Plataforma open source de virtualización basada en KVM y contenedores LXC.', false),
(1, 'Hipervisores y virtualización', 'ESXI', 'ESXi', 'Hipervisor tipo 1 (bare-metal) de VMware.', false),
(1, 'Hipervisores y virtualización', 'QEMU', 'QEMU', 'Emulador y virtualizador open source; con KVM ejecuta VMs a velocidad casi nativa.', false),
(1, 'Hipervisores y virtualización', 'DOCKER', 'Docker', 'No es un hipervisor: crea contenedores que comparten el kernel del host, no máquinas virtuales completas.', true),
(1, 'Hipervisores y virtualización', 'PODMAN', 'Podman', 'Motor de contenedores (alternativa a Docker), no de máquinas virtuales.', true),
(2, 'Sistemas operativos de servidor', 'WINDOWS', 'Windows Server', 'Sistema operativo de servidor de Microsoft (AD DS, DNS, DHCP, Hyper-V).', false),
(2, 'Sistemas operativos de servidor', 'UBUNTU', 'Ubuntu Server', 'Distribución Linux de Canonical, muy usada en la nube.', false),
(2, 'Sistemas operativos de servidor', 'DEBIAN', 'Debian', 'Distribución Linux comunitaria y estable; base de Ubuntu.', false),
(2, 'Sistemas operativos de servidor', 'REDHAT', 'Red Hat (RHEL)', 'Red Hat Enterprise Linux: Linux empresarial con soporte de pago.', false),
(2, 'Sistemas operativos de servidor', 'ROCKY', 'Rocky Linux', 'Clon gratuito de RHEL, sucesor de CentOS.', false),
(2, 'Sistemas operativos de servidor', 'SUSE', 'SUSE', 'Linux empresarial alemán (SLES), fuerte en SAP.', false),
(2, 'Sistemas operativos de servidor', 'FREEBSD', 'FreeBSD', 'Sistema tipo Unix muy usado en firewalls y almacenamiento.', false),
(2, 'Sistemas operativos de servidor', 'OFFICE', 'Office', 'Es una suite ofimática, no un sistema operativo.', true),
(2, 'Sistemas operativos de servidor', 'CHROME', 'Chrome', 'Es un navegador web, no un sistema operativo de servidor.', true),
(3, 'Proveedores de nube', 'AZURE', 'Microsoft Azure', 'Nube de Microsoft: VMs, Entra ID, redes virtuales.', false),
(3, 'Proveedores de nube', 'AWS', 'AWS', 'Amazon Web Services: el proveedor de nube con mayor cuota de mercado.', false),
(3, 'Proveedores de nube', 'GOOGLE', 'Google Cloud', 'Nube de Google (GCP).', false),
(3, 'Proveedores de nube', 'ORACLE', 'Oracle Cloud', 'Oracle Cloud Infrastructure (OCI).', false),
(3, 'Proveedores de nube', 'IBM', 'IBM Cloud', 'Nube de IBM, orientada a empresa y nube híbrida.', false),
(3, 'Proveedores de nube', 'ALIBABA', 'Alibaba Cloud', 'Principal proveedor de nube en China.', false),
(3, 'Proveedores de nube', 'HUAWEI', 'Huawei Cloud', 'Nube de Huawei, con presencia en Latinoamérica.', false),
(3, 'Proveedores de nube', 'NETFLIX', 'Netflix', 'Es cliente de la nube (usa AWS), no un proveedor de nube.', true),
(3, 'Proveedores de nube', 'ZOOM', 'Zoom', 'Es una aplicación SaaS de videollamadas, no un proveedor de infraestructura.', true),
(4, 'Servicios y protocolos de red', 'DNS', 'DNS', 'Traduce nombres de dominio a direcciones IP.', false),
(4, 'Servicios y protocolos de red', 'DHCP', 'DHCP', 'Asigna direcciones IP automáticamente.', false),
(4, 'Servicios y protocolos de red', 'NAT', 'NAT', 'Traduce direcciones privadas a una IP pública.', false),
(4, 'Servicios y protocolos de red', 'VPN', 'VPN', 'Túnel cifrado entre redes o usuarios.', false),
(4, 'Servicios y protocolos de red', 'LDAP', 'LDAP', 'Protocolo para consultar directorios como Active Directory.', false),
(4, 'Servicios y protocolos de red', 'SMTP', 'SMTP', 'Protocolo de envío de correo.', false),
(4, 'Servicios y protocolos de red', 'HTTPS', 'HTTPS', 'HTTP cifrado con TLS, puerto 443.', false),
(4, 'Servicios y protocolos de red', 'SSH', 'SSH', 'Acceso remoto seguro por consola, puerto 22.', false),
(4, 'Servicios y protocolos de red', 'RAID', 'RAID', 'Es una técnica de almacenamiento con varios discos, no un servicio de red.', true),
(4, 'Servicios y protocolos de red', 'HDMI', 'HDMI', 'Es un conector de video, no un protocolo de red.', true),
(5, 'Almacenamiento y respaldo', 'RAID', 'RAID', 'Combina discos para redundancia o rendimiento.', false),
(5, 'Almacenamiento y respaldo', 'NAS', 'NAS', 'Almacenamiento en red que comparte archivos.', false),
(5, 'Almacenamiento y respaldo', 'SAN', 'SAN', 'Red de almacenamiento por bloques para servidores.', false),
(5, 'Almacenamiento y respaldo', 'SSD', 'SSD', 'Disco de estado sólido, sin partes móviles.', false),
(5, 'Almacenamiento y respaldo', 'NVME', 'NVMe', 'Protocolo de discos SSD por PCIe, muy rápido.', false),
(5, 'Almacenamiento y respaldo', 'ISCSI', 'iSCSI', 'Discos por red usando TCP/IP.', false),
(5, 'Almacenamiento y respaldo', 'SNAPSHOT', 'Snapshot', 'Estado de una VM en un instante; no reemplaza un respaldo.', false),
(5, 'Almacenamiento y respaldo', 'BACKUP', 'Backup', 'Copia de seguridad (regla 3-2-1).', false),
(5, 'Almacenamiento y respaldo', 'DHCP', 'DHCP', 'Es un servicio de red que asigna IPs, no de almacenamiento.', true),
(5, 'Almacenamiento y respaldo', 'GPO', 'GPO', 'Es una directiva de grupo de Active Directory.', true),
(6, 'Identidad y seguridad', 'ENTRAID', 'Entra ID', 'Servicio de identidad en la nube de Microsoft.', false),
(6, 'Identidad y seguridad', 'MFA', 'MFA', 'Autenticación con dos o más factores.', false),
(6, 'Identidad y seguridad', 'KERBEROS', 'Kerberos', 'Autenticación por tickets usada en Active Directory.', false),
(6, 'Identidad y seguridad', 'RBAC', 'RBAC', 'Control de acceso basado en roles.', false),
(6, 'Identidad y seguridad', 'SSO', 'SSO', 'Inicio de sesión único para varias aplicaciones.', false),
(6, 'Identidad y seguridad', 'PIM', 'PIM', 'Activación de roles privilegiados por tiempo limitado.', false),
(6, 'Identidad y seguridad', 'ZEROTRUST', 'Zero Trust', 'Nunca confiar, verificar siempre.', false),
(6, 'Identidad y seguridad', 'BITLOCKER', 'BitLocker', 'Cifrado de disco de Windows.', false),
(6, 'Identidad y seguridad', 'EXCEL', 'Excel', 'Es una hoja de cálculo, no un mecanismo de seguridad.', true),
(6, 'Identidad y seguridad', 'RAM', 'RAM', 'Es memoria del equipo, no un control de identidad.', true)
  ) as v(o, tema, palabra, mostrar, explicacion, intruso) order by o loop
    if r.o <> v_last then insert into public.pupi_temas (nombre, orden) values (r.tema, r.o) returning id into v_tema; v_last := r.o; end if;
    insert into public.pupi_palabras (tema_id, palabra, mostrar, explicacion, intruso) values (v_tema, r.palabra, r.mostrar, r.explicacion, r.intruso);
  end loop;
end $$;
notify pgrst, 'reload schema';
