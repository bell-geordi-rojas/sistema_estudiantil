-- Sistema de Gestion de Estudiantes - v2 (multi-institucion con cuentas, roles y permisos)
-- Pegar completo en Supabase > SQL Editor > Run. Se puede ejecutar mas de una vez.
--
-- Jerarquia (vista "carpetas"):  Admin / <Institucion> / Docentes / <docente> / Alumnos / <alumno>
-- Roles: dueno (tu) > admin (director de una institucion) > docente > alumno

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- 0. Cerrar y respaldar lo anterior (v1: acceso publico sin cuentas)
-- ---------------------------------------------------------------------------
drop function if exists registrar_estudiante(text, text, jsonb);
drop function if exists agregar_nota(text, int, numeric);
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'estudiantes' and column_name = 'codigo')
     and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'estudiantes' and column_name = 'institucion_id') then
    drop policy if exists web_estudiantes on estudiantes;
    drop policy if exists web_notas on notas;
    drop trigger if exists limitar_notas_trg on notas;
    alter table notas rename to notas_v1;
    alter table estudiantes rename to estudiantes_v1;
    alter index if exists estudiantes_pkey rename to estudiantes_v1_pkey;
    alter index if exists estudiantes_codigo_unico rename to estudiantes_v1_codigo_unico;
    alter index if exists notas_pkey rename to notas_v1_pkey;
    alter index if exists notas_estudiante_curso rename to notas_v1_estudiante_curso;
    alter table estudiantes_v1 enable row level security;  -- sin politicas: nadie por la web
    alter table notas_v1 enable row level security;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------
do $$ begin create type rol_usuario as enum ('dueno', 'admin', 'docente', 'alumno');
exception when duplicate_object then null; end $$;

create table if not exists config (
  clave text primary key,
  valor text not null
);
insert into config (clave, valor) values ('email_dominio', 'acceso.estudiantil.app') on conflict do nothing;

create table if not exists instituciones (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) between 2 and 120),
  slug text not null unique,                 -- nombre de la carpeta, p. ej. Maria_Auxiliadora
  activa boolean not null default true,
  vence date,                                -- fin del alquiler (null = sin vencimiento)
  creado timestamptz not null default now()
);

create table if not exists perfiles (
  id uuid primary key references auth.users (id) on delete cascade,
  usuario text not null unique check (usuario ~ '^[a-z0-9]{3,30}$'),
  nombres text not null,
  apellidos text not null default '',
  rol rol_usuario not null,
  institucion_id bigint references instituciones (id) on delete cascade,
  docente_id uuid references perfiles (id) on delete set null,   -- docente de un alumno
  permisos jsonb not null default '{}',                           -- cambios sobre los permisos por defecto del rol
  activo boolean not null default true,
  creado timestamptz not null default now(),
  check ((rol = 'dueno') = (institucion_id is null))
);

create table if not exists estudiantes (
  id bigint generated always as identity primary key,
  institucion_id bigint not null references instituciones (id) on delete cascade,
  docente_id uuid references perfiles (id) on delete set null,
  perfil_id uuid unique references perfiles (id) on delete set null,   -- cuenta del alumno, si la tiene
  codigo text not null check (codigo ~ '^[A-Za-z0-9]{1,15}$'),
  nombre text not null check (length(nombre) between 1 and 100 and nombre !~ '[0-9|]')
);
create unique index if not exists estudiantes_codigo_inst_unico on estudiantes (institucion_id, upper(codigo));
create index if not exists estudiantes_docente on estudiantes (docente_id);

create table if not exists notas (
  id bigint generated always as identity primary key,
  estudiante_id bigint not null references estudiantes (id) on delete cascade,
  curso smallint not null check (curso between 0 and 6),   -- 0 Matematica ... 6 Ingles
  nota numeric(4,2) not null check (nota between 0 and 20)
);
create index if not exists notas_estudiante_curso on notas (estudiante_id, curso);

create table if not exists solicitudes (
  id bigint generated always as identity primary key,
  institucion_id bigint not null references instituciones (id) on delete cascade,
  nombres text not null,
  apellidos text not null default '',
  rol_solicitado text not null check (rol_solicitado in ('docente', 'alumno')),
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobada', 'rechazada')),
  creado timestamptz not null default now()
);

create table if not exists invitaciones (
  id bigint generated always as identity primary key,
  institucion_id bigint references instituciones (id) on delete cascade,
  rol rol_usuario not null,
  nombres text not null,
  apellidos text not null default '',
  usuario text not null unique,
  codigo_hash text not null,                  -- el codigo en claro solo se muestra una vez al crearlo
  docente_id uuid references perfiles (id) on delete set null,
  estudiante_id bigint references estudiantes (id) on delete set null,
  creado_por uuid references perfiles (id) on delete set null,
  usado boolean not null default false,
  creado timestamptz not null default now(),
  check ((rol = 'dueno') = (institucion_id is null))
);

-- Maximo 20 notas por curso y estudiante
create or replace function limitar_notas() returns trigger language plpgsql as $$
begin
  if (select count(*) from notas where estudiante_id = new.estudiante_id and curso = new.curso) >= 20 then
    raise exception 'Maximo 20 calificaciones por curso.';
  end if;
  return new;
end $$;
drop trigger if exists limitar_notas_trg on notas;
create trigger limitar_notas_trg before insert on notas for each row execute function limitar_notas();

-- ---------------------------------------------------------------------------
-- 2. Funciones de apoyo (permisos y alcance)
-- ---------------------------------------------------------------------------
create or replace function claves_permiso() returns text[] language sql immutable as $$
  select array['ver_companeros', 'ver_notas_companeros', 'ver_estadisticas', 'registrar_estudiantes',
               'editar_estudiantes', 'editar_notas', 'eliminar', 'exportar', 'gestionar_alumnos'] $$;

-- Permisos por defecto: el alumno solo ve a sus companeros; el docente tiene todo lo de su clase
create or replace function permiso_defecto(p_rol rol_usuario, p_clave text) returns boolean language sql immutable as $$
  select case p_rol when 'alumno' then p_clave = 'ver_companeros' else true end $$;

-- Rol del usuario actual; null si no tiene acceso (cuenta desactivada o institucion suspendida / vencida)
create or replace function mi_rol() returns rol_usuario language sql stable security definer set search_path = public as $$
  select p.rol from perfiles p left join instituciones i on i.id = p.institucion_id
  where p.id = auth.uid() and p.activo
    and (p.rol = 'dueno' or (i.activa and (i.vence is null or i.vence >= current_date))) $$;

create or replace function mi_inst() returns bigint language sql stable security definer set search_path = public as $$
  select institucion_id from perfiles where id = auth.uid() and mi_rol() is not null $$;

create or replace function mi_docente() returns uuid language sql stable security definer set search_path = public as $$
  select docente_id from perfiles where id = auth.uid() and mi_rol() is not null $$;

create or replace function permiso(p_clave text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when p.rol in ('dueno', 'admin') then true
                else coalesce((p.permisos ->> p_clave)::boolean, permiso_defecto(p.rol, p_clave)) end
    from perfiles p where p.id = auth.uid() and mi_rol() is not null
  ), false) $$;

-- El usuario actual puede modificar los datos/notas de ese estudiante (admin de su institucion o su docente)
create or replace function _puedo_gestionar(p_est bigint) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from estudiantes e where e.id = p_est and (
    (mi_rol() = 'admin' and e.institucion_id = mi_inst())
    or (mi_rol() = 'docente' and e.docente_id = auth.uid()))) $$;

-- El usuario actual puede administrar esa cuenta (permisos, estado, contrasena)
create or replace function _alcance_perfil(p_perfil uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfiles t where t.id = p_perfil and t.id <> auth.uid() and (
    (mi_rol() = 'dueno' and t.rol <> 'dueno')
    or (mi_rol() = 'admin' and t.institucion_id = mi_inst() and t.rol in ('docente', 'alumno'))
    or (mi_rol() = 'docente' and permiso('gestionar_alumnos') and t.rol = 'alumno' and t.docente_id = auth.uid()))) $$;

create or replace function limpiar_slug(t text) returns text language sql immutable as $$
  select trim(both '_' from regexp_replace(translate(t, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'), '[^A-Za-z0-9]+', '_', 'g')) $$;

-- ---------------------------------------------------------------------------
-- 3. Seguridad por filas: cada cuenta solo ve lo suyo
-- ---------------------------------------------------------------------------
alter table config enable row level security;          -- sin politicas: cerrada
alter table instituciones enable row level security;
alter table perfiles enable row level security;
alter table estudiantes enable row level security;
alter table notas enable row level security;
alter table solicitudes enable row level security;
alter table invitaciones enable row level security;

drop policy if exists inst_sel on instituciones;
create policy inst_sel on instituciones for select to authenticated using (
  mi_rol() = 'dueno' or id = mi_inst());

drop policy if exists perf_sel on perfiles;
create policy perf_sel on perfiles for select to authenticated using (
  id = auth.uid()
  or mi_rol() = 'dueno'
  or (mi_rol() = 'admin' and institucion_id = mi_inst())
  or (mi_rol() = 'docente' and docente_id = auth.uid())
  or (mi_rol() = 'alumno' and (id = mi_docente()
        or (permiso('ver_companeros') and rol = 'alumno' and docente_id is not null and docente_id = mi_docente()))));

drop policy if exists est_sel on estudiantes;
create policy est_sel on estudiantes for select to authenticated using (
  mi_rol() = 'dueno'
  or (mi_rol() = 'admin' and institucion_id = mi_inst())
  or (mi_rol() = 'docente' and docente_id = auth.uid())
  or (mi_rol() = 'alumno' and (perfil_id = auth.uid()
        or (permiso('ver_companeros') and docente_id is not null and docente_id = mi_docente()))));

drop policy if exists notas_sel on notas;
create policy notas_sel on notas for select to authenticated using (
  exists (select 1 from estudiantes e where e.id = notas.estudiante_id
          and (mi_rol() <> 'alumno' or e.perfil_id = auth.uid() or permiso('ver_notas_companeros'))));

drop policy if exists sol_sel on solicitudes;
create policy sol_sel on solicitudes for select to authenticated using (
  mi_rol() = 'dueno'
  or (mi_rol() = 'admin' and institucion_id = mi_inst())
  or (mi_rol() = 'docente' and permiso('gestionar_alumnos') and rol_solicitado = 'alumno' and institucion_id = mi_inst()));

drop policy if exists inv_sel on invitaciones;
create policy inv_sel on invitaciones for select to authenticated using (
  mi_rol() = 'dueno'
  or (mi_rol() = 'admin' and institucion_id = mi_inst())
  or (mi_rol() = 'docente' and creado_por = auth.uid()));

-- Toda escritura pasa por las funciones de abajo (no hay politicas de insert/update/delete)

-- ---------------------------------------------------------------------------
-- 4. Vista de carpetas: Admin / Institucion / Docentes / docente / Alumnos / alumno
-- ---------------------------------------------------------------------------
create or replace view carpetas with (security_invoker = true) as
  select 'Admin'::text as ruta, 'dueno'::text as tipo, trim(p.nombres || ' ' || p.apellidos) as nombre, null::bigint as institucion_id
    from perfiles p where p.rol = 'dueno'
  union all
  select 'Admin/' || i.slug, 'institucion', i.nombre, i.id from instituciones i
  union all
  select 'Admin/' || i.slug || '/Administradores/' || p.usuario, 'admin', trim(p.nombres || ' ' || p.apellidos), i.id
    from perfiles p join instituciones i on i.id = p.institucion_id where p.rol = 'admin'
  union all
  select 'Admin/' || i.slug || '/Docentes/' || p.usuario, 'docente', trim(p.nombres || ' ' || p.apellidos), i.id
    from perfiles p join instituciones i on i.id = p.institucion_id where p.rol = 'docente'
  union all
  select 'Admin/' || i.slug || '/Docentes/' || coalesce(d.usuario, '_sin_docente') || '/Alumnos/' || e.codigo, 'alumno', e.nombre, i.id
    from estudiantes e join instituciones i on i.id = e.institucion_id left join perfiles d on d.id = e.docente_id;

-- ---------------------------------------------------------------------------
-- 5. Funciones publicas (sin sesion): buscar afiliacion, solicitar acceso, verificar activacion
-- ---------------------------------------------------------------------------
create or replace function buscar_instituciones(p_q text) returns table (id bigint, nombre text)
language sql stable security definer set search_path = public as $$
  select i.id, i.nombre from instituciones i
  where i.activa and (i.vence is null or i.vence >= current_date)
    and i.nombre ilike '%' || trim(coalesce(p_q, '')) || '%'
  order by i.nombre limit 10 $$;

create or replace function solicitar_afiliacion(p_institucion bigint, p_nombres text, p_apellidos text, p_rol text)
returns void language plpgsql security definer set search_path = public as $$
begin
  p_nombres := trim(coalesce(p_nombres, ''));
  p_apellidos := trim(coalesce(p_apellidos, ''));
  if p_rol not in ('docente', 'alumno') then raise exception 'Rol invalido.'; end if;
  if p_nombres = '' or p_nombres ~ '[0-9|]' or p_apellidos ~ '[0-9|]' or length(p_nombres || p_apellidos) > 100 then
    raise exception 'Escribe tus nombres y apellidos (sin numeros).';
  end if;
  if not exists (select 1 from instituciones i where i.id = p_institucion and i.activa and (i.vence is null or i.vence >= current_date)) then
    raise exception 'Institucion no disponible.';
  end if;
  if (select count(*) from solicitudes where institucion_id = p_institucion and estado = 'pendiente') >= 200 then
    raise exception 'Hay demasiadas solicitudes pendientes. Contacta a tu institucion.';
  end if;
  insert into solicitudes (institucion_id, nombres, apellidos, rol_solicitado) values (p_institucion, p_nombres, p_apellidos, p_rol);
end $$;

create or replace function verificar_activacion(p_usuario text, p_codigo text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare inv invitaciones;
begin
  select * into inv from invitaciones where usuario = lower(trim(coalesce(p_usuario, ''))) and not usado;
  if not found or inv.codigo_hash <> crypt(coalesce(p_codigo, ''), inv.codigo_hash) then return null; end if;
  return jsonb_build_object('nombres', inv.nombres, 'apellidos', inv.apellidos, 'rol', inv.rol,
    'institucion', (select nombre from instituciones where id = inv.institucion_id));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Activacion de cuenta: al crearse el usuario en Auth se valida usuario + codigo y se crea el perfil
-- ---------------------------------------------------------------------------
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  inv invitaciones;
  v_usuario text := lower(trim(coalesce(new.raw_user_meta_data ->> 'usuario', '')));
  v_dominio text;
begin
  select valor into v_dominio from config where clave = 'email_dominio';
  select * into inv from invitaciones where usuario = v_usuario and not usado for update;
  if not found
     or inv.codigo_hash <> crypt(coalesce(new.raw_user_meta_data ->> 'codigo', ''), inv.codigo_hash)
     or lower(new.email) <> v_usuario || '@' || v_dominio then
    raise exception 'Usuario o codigo de activacion invalido.';
  end if;
  insert into perfiles (id, usuario, nombres, apellidos, rol, institucion_id, docente_id)
    values (new.id, inv.usuario, inv.nombres, inv.apellidos, inv.rol, inv.institucion_id, inv.docente_id);
  if inv.estudiante_id is not null then
    update estudiantes set perfil_id = new.id where id = inv.estudiante_id;
  end if;
  update invitaciones set usado = true where id = inv.id;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- ---------------------------------------------------------------------------
-- 7. Sesion
-- ---------------------------------------------------------------------------
create or replace function mi_sesion() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p perfiles; i instituciones; v_ok boolean := true; v_motivo text;
begin
  select * into p from perfiles where id = auth.uid();
  if not found then return null; end if;
  if p.institucion_id is not null then select * into i from instituciones where id = p.institucion_id; end if;
  if not p.activo then
    v_ok := false; v_motivo := 'Tu cuenta esta desactivada. Contacta a tu administrador.';
  elsif p.rol <> 'dueno' and not i.activa then
    v_ok := false; v_motivo := 'La afiliacion de tu institucion esta suspendida.';
  elsif p.rol <> 'dueno' and i.vence is not null and i.vence < current_date then
    v_ok := false; v_motivo := 'La afiliacion de tu institucion vencio.';
  end if;
  return jsonb_build_object(
    'id', p.id, 'usuario', p.usuario, 'nombres', p.nombres, 'apellidos', p.apellidos, 'rol', p.rol,
    'docente_id', p.docente_id, 'acceso', v_ok, 'motivo', v_motivo,
    'institucion', case when i.id is null then null
                        else jsonb_build_object('id', i.id, 'nombre', i.nombre, 'slug', i.slug, 'vence', i.vence) end,
    'permisos', (select jsonb_object_agg(k, permiso(k)) from unnest(claves_permiso()) as k));
end $$;

-- ---------------------------------------------------------------------------
-- 8. Cuentas e instituciones
-- ---------------------------------------------------------------------------
create or replace function _generar_usuario(p_nombres text, p_apellidos text) returns text language plpgsql set search_path = public as $$
declare base text; u text; n int := 1;
begin
  base := lower(translate(left(trim(p_nombres), 1) || split_part(trim(p_apellidos), ' ', 1), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'));
  base := regexp_replace(base, '[^a-z0-9]', '', 'g');
  if length(base) < 3 then base := base || 'usr'; end if;
  base := left(base, 24);
  u := base;
  while exists (select 1 from perfiles where usuario = u) or exists (select 1 from invitaciones where usuario = u) loop
    n := n + 1; u := base || n;
  end loop;
  return u;
end $$;

create or replace function _crear_invitacion(p_rol rol_usuario, p_nombres text, p_apellidos text, p_inst bigint, p_docente uuid, p_creador uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_usuario text; v_codigo text; v_est bigint; v_cod_est text; base text; n int := 1;
begin
  v_usuario := _generar_usuario(p_nombres, p_apellidos);
  v_codigo := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 10));
  if p_rol = 'alumno' then
    base := left(upper(v_usuario), 13);
    v_cod_est := base;
    while exists (select 1 from estudiantes where institucion_id = p_inst and upper(codigo) = v_cod_est) loop
      n := n + 1; v_cod_est := base || n;
    end loop;
    insert into estudiantes (institucion_id, docente_id, codigo, nombre)
      values (p_inst, p_docente, v_cod_est, trim(p_nombres || ' ' || p_apellidos)) returning id into v_est;
  end if;
  insert into invitaciones (institucion_id, rol, nombres, apellidos, usuario, codigo_hash, docente_id, estudiante_id, creado_por)
    values (p_inst, p_rol, trim(p_nombres), trim(p_apellidos), v_usuario, crypt(v_codigo, gen_salt('bf')), p_docente, v_est, p_creador);
  return jsonb_build_object('usuario', v_usuario, 'codigo', v_codigo, 'rol', p_rol);
end $$;

-- Crea una cuenta pendiente de activar; devuelve usuario + codigo (el codigo solo se ve ahora)
create or replace function crear_invitacion(p_rol text, p_nombres text, p_apellidos text, p_institucion bigint default null, p_docente uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r rol_usuario := mi_rol(); v_rol rol_usuario; v_inst bigint; v_doc uuid;
begin
  if r is null then raise exception 'No autorizado.'; end if;
  p_nombres := trim(coalesce(p_nombres, ''));
  p_apellidos := trim(coalesce(p_apellidos, ''));
  if p_nombres = '' or p_nombres ~ '[0-9|]' or p_apellidos ~ '[0-9|]' or length(p_nombres || p_apellidos) > 100 then
    raise exception 'Nombres invalidos (sin numeros).';
  end if;
  if p_rol not in ('admin', 'docente', 'alumno') then raise exception 'Rol invalido.'; end if;
  v_rol := p_rol::rol_usuario;
  if r = 'dueno' then
    v_inst := p_institucion; v_doc := p_docente;
    if v_inst is null or not exists (select 1 from instituciones where id = v_inst) then raise exception 'Institucion invalida.'; end if;
  elsif r = 'admin' then
    if v_rol = 'admin' then raise exception 'Solo el dueno puede crear administradores.'; end if;
    v_inst := mi_inst(); v_doc := p_docente;
  elsif r = 'docente' then
    if v_rol <> 'alumno' or not permiso('gestionar_alumnos') then raise exception 'No autorizado.'; end if;
    v_inst := mi_inst(); v_doc := auth.uid();
  else
    raise exception 'No autorizado.';
  end if;
  if v_rol = 'alumno' then
    if v_doc is null then raise exception 'Elige el docente del alumno.'; end if;
    if not exists (select 1 from perfiles where id = v_doc and rol = 'docente' and institucion_id = v_inst) then raise exception 'Docente invalido.'; end if;
  else
    v_doc := null;
  end if;
  return _crear_invitacion(v_rol, p_nombres, p_apellidos, v_inst, v_doc, auth.uid());
end $$;

create or replace function _puede_resolver_solicitud(s solicitudes) returns boolean language sql stable security definer set search_path = public as $$
  select case mi_rol()
    when 'dueno' then true
    when 'admin' then s.institucion_id = mi_inst()
    when 'docente' then permiso('gestionar_alumnos') and s.rol_solicitado = 'alumno' and s.institucion_id = mi_inst()
    else false end $$;

create or replace function aprobar_solicitud(p_id bigint, p_docente uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitudes; v_doc uuid; v jsonb;
begin
  select * into s from solicitudes where id = p_id and estado = 'pendiente' for update;
  if not found then raise exception 'Solicitud no encontrada.'; end if;
  if not _puede_resolver_solicitud(s) then raise exception 'No autorizado.'; end if;
  if s.rol_solicitado = 'alumno' then
    v_doc := case when mi_rol() = 'docente' then auth.uid() else p_docente end;
    if v_doc is null or not exists (select 1 from perfiles where id = v_doc and rol = 'docente' and institucion_id = s.institucion_id) then
      raise exception 'Elige el docente del alumno.';
    end if;
  end if;
  v := _crear_invitacion(s.rol_solicitado::rol_usuario, s.nombres, s.apellidos, s.institucion_id, v_doc, auth.uid());
  update solicitudes set estado = 'aprobada' where id = p_id;
  return v;
end $$;

create or replace function rechazar_solicitud(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare s solicitudes;
begin
  select * into s from solicitudes where id = p_id and estado = 'pendiente' for update;
  if not found then raise exception 'Solicitud no encontrada.'; end if;
  if not _puede_resolver_solicitud(s) then raise exception 'No autorizado.'; end if;
  update solicitudes set estado = 'rechazada' where id = p_id;
end $$;

-- Cuentas pendientes de activar: generar un codigo nuevo (por si se perdio) o anularlas
create or replace function _puede_invitacion(inv invitaciones) returns boolean language sql stable security definer set search_path = public as $$
  select case mi_rol()
    when 'dueno' then true
    when 'admin' then inv.institucion_id = mi_inst()
    when 'docente' then inv.creado_por = auth.uid()
    else false end $$;

create or replace function regenerar_codigo(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare inv invitaciones; v_codigo text;
begin
  select * into inv from invitaciones where id = p_id and not usado for update;
  if not found then raise exception 'Invitacion no encontrada.'; end if;
  if not _puede_invitacion(inv) then raise exception 'No autorizado.'; end if;
  v_codigo := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 10));
  update invitaciones set codigo_hash = crypt(v_codigo, gen_salt('bf')) where id = p_id;
  return jsonb_build_object('usuario', inv.usuario, 'codigo', v_codigo, 'rol', inv.rol);
end $$;

create or replace function eliminar_invitacion(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare inv invitaciones;
begin
  select * into inv from invitaciones where id = p_id and not usado for update;
  if not found then raise exception 'Invitacion no encontrada.'; end if;
  if not _puede_invitacion(inv) then raise exception 'No autorizado.'; end if;
  delete from invitaciones where id = p_id;
end $$;

create or replace function crear_institucion(p_nombre text, p_vence date default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare base text; v_slug text; v_id bigint; n int := 1;
begin
  if mi_rol() is distinct from 'dueno' then raise exception 'No autorizado.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if length(p_nombre) < 2 then raise exception 'Escribe el nombre de la institucion.'; end if;
  base := limpiar_slug(p_nombre);
  if base = '' then base := 'Institucion'; end if;
  v_slug := base;
  while exists (select 1 from instituciones where slug = v_slug) loop n := n + 1; v_slug := base || '_' || n; end loop;
  insert into instituciones (nombre, slug, vence) values (p_nombre, v_slug, p_vence) returning id into v_id;
  return v_id;
end $$;

create or replace function actualizar_institucion(p_id bigint, p_activa boolean, p_vence date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'dueno' then raise exception 'No autorizado.'; end if;
  update instituciones set activa = p_activa, vence = p_vence where id = p_id;
  if not found then raise exception 'Institucion no encontrada.'; end if;
end $$;

create or replace function actualizar_permisos(p_perfil uuid, p_permisos jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k text; v jsonb;
begin
  if not _alcance_perfil(p_perfil) then raise exception 'No autorizado.'; end if;
  for k, v in select key, value from jsonb_each(p_permisos) loop
    if not (k = any (claves_permiso())) then raise exception 'Permiso desconocido: %', k; end if;
    if jsonb_typeof(v) <> 'boolean' then raise exception 'Valor invalido para %', k; end if;
    -- Un docente no puede conceder un permiso que el no tiene (si el alumno ya lo tenia, se respeta)
    if (v)::boolean and mi_rol() not in ('dueno', 'admin') and not permiso(k) and not coalesce(
         (select coalesce((t.permisos ->> k)::boolean, permiso_defecto(t.rol, k)) from perfiles t where t.id = p_perfil), false) then
      raise exception 'No puedes conceder un permiso que tu no tienes.';
    end if;
  end loop;
  update perfiles set permisos = p_permisos where id = p_perfil;
end $$;

create or replace function actualizar_estado_perfil(p_perfil uuid, p_activo boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _alcance_perfil(p_perfil) then raise exception 'No autorizado.'; end if;
  update perfiles set activo = p_activo where id = p_perfil;
end $$;

create or replace function restablecer_contrasena(p_perfil uuid, p_nueva text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not _alcance_perfil(p_perfil) then raise exception 'No autorizado.'; end if;
  if length(coalesce(p_nueva, '')) < 6 then raise exception 'La contrasena debe tener al menos 6 caracteres.'; end if;
  update auth.users set encrypted_password = crypt(p_nueva, gen_salt('bf')), updated_at = now() where id = p_perfil;
end $$;

-- Solo el dueno: ascender un docente a admin (director) o devolverlo a docente
create or replace function cambiar_rol(p_perfil uuid, p_rol text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'dueno' then raise exception 'No autorizado.'; end if;
  if p_rol not in ('admin', 'docente') then raise exception 'Rol invalido.'; end if;
  if not exists (select 1 from perfiles where id = p_perfil and rol in ('admin', 'docente')) then
    raise exception 'Solo se puede cambiar entre docente y admin.';
  end if;
  update perfiles set rol = p_rol::rol_usuario where id = p_perfil;
end $$;

create or replace function eliminar_cuenta(p_perfil uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _alcance_perfil(p_perfil) then raise exception 'No autorizado.'; end if;
  delete from auth.users where id = p_perfil;   -- el perfil se borra en cascada
end $$;

-- ---------------------------------------------------------------------------
-- 9. Estudiantes y notas (admin y docentes, segun permisos)
-- ---------------------------------------------------------------------------
create or replace function registrar_estudiante(p_codigo text, p_nombre text, p_notas jsonb, p_docente uuid default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare r rol_usuario := mi_rol(); v_inst bigint := mi_inst(); v_doc uuid; v_id bigint; c int; n numeric;
begin
  if r not in ('admin', 'docente') or not permiso('registrar_estudiantes') then raise exception 'No autorizado.'; end if;
  v_doc := case when r = 'docente' then auth.uid() else p_docente end;
  if v_doc is not null and not exists (select 1 from perfiles where id = v_doc and rol = 'docente' and institucion_id = v_inst) then
    raise exception 'Docente invalido.';
  end if;
  if jsonb_array_length(p_notas) <> 7 then raise exception 'Formato de notas invalido.'; end if;
  insert into estudiantes (institucion_id, docente_id, codigo, nombre) values (v_inst, v_doc, trim(p_codigo), trim(p_nombre)) returning id into v_id;
  for c in 0..6 loop
    for n in select jsonb_array_elements_text(p_notas -> c)::numeric loop
      insert into notas (estudiante_id, curso, nota) values (v_id, c, n);
    end loop;
  end loop;
  return v_id;
end $$;

create or replace function actualizar_estudiante(p_id bigint, p_codigo text, p_nombre text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not permiso('editar_estudiantes') or not _puedo_gestionar(p_id) then raise exception 'No autorizado.'; end if;
  update estudiantes set codigo = trim(p_codigo), nombre = trim(p_nombre) where id = p_id;
end $$;

create or replace function reasignar_docente(p_id bigint, p_docente uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'admin' or not _puedo_gestionar(p_id) then raise exception 'No autorizado.'; end if;
  if p_docente is not null and not exists (select 1 from perfiles where id = p_docente and rol = 'docente' and institucion_id = mi_inst()) then
    raise exception 'Docente invalido.';
  end if;
  update estudiantes set docente_id = p_docente where id = p_id;
  update perfiles set docente_id = p_docente where id = (select perfil_id from estudiantes where id = p_id);
end $$;

create or replace function eliminar_estudiante(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not permiso('eliminar') or not _puedo_gestionar(p_id) then raise exception 'No autorizado.'; end if;
  delete from estudiantes where id = p_id;
end $$;

create or replace function agregar_nota(p_estudiante bigint, p_curso int, p_nota numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not permiso('editar_notas') or not _puedo_gestionar(p_estudiante) then raise exception 'No autorizado.'; end if;
  insert into notas (estudiante_id, curso, nota) values (p_estudiante, p_curso, p_nota);
end $$;

create or replace function actualizar_nota(p_id bigint, p_nota numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_est bigint;
begin
  select estudiante_id into v_est from notas where id = p_id;
  if v_est is null or not permiso('editar_notas') or not _puedo_gestionar(v_est) then raise exception 'No autorizado.'; end if;
  update notas set nota = p_nota where id = p_id;
end $$;

create or replace function eliminar_nota(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_est bigint;
begin
  select estudiante_id into v_est from notas where id = p_id;
  if v_est is null or not permiso('editar_notas') or not _puedo_gestionar(v_est) then raise exception 'No autorizado.'; end if;
  delete from notas where id = p_id;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Primera cuenta: el dueno (se ejecuta una vez, a mano, con TU usuario y TU codigo secreto)
-- ---------------------------------------------------------------------------
create or replace function crear_invitacion_dueno(p_usuario text, p_nombres text, p_codigo text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  p_usuario := lower(trim(p_usuario));
  if p_usuario !~ '^[a-z0-9]{3,30}$' then raise exception 'Usuario invalido (3-30 letras minusculas o numeros).'; end if;
  if length(coalesce(p_codigo, '')) < 8 then raise exception 'El codigo debe tener al menos 8 caracteres.'; end if;
  insert into invitaciones (institucion_id, rol, nombres, usuario, codigo_hash)
    values (null, 'dueno', trim(p_nombres), p_usuario, crypt(p_codigo, gen_salt('bf')));
end $$;

-- ---------------------------------------------------------------------------
-- 11. Permisos de ejecucion: solo lo necesario queda abierto
-- ---------------------------------------------------------------------------
do $$
declare f regprocedure;
begin
  -- Solo con sesion
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array[
             'mi_sesion', 'crear_invitacion', 'aprobar_solicitud', 'rechazar_solicitud', 'crear_institucion',
             'actualizar_institucion', 'actualizar_permisos', 'actualizar_estado_perfil', 'restablecer_contrasena',
             'cambiar_rol', 'eliminar_cuenta', 'regenerar_codigo', 'eliminar_invitacion', 'registrar_estudiante', 'actualizar_estudiante', 'reasignar_docente',
             'eliminar_estudiante', 'agregar_nota', 'actualizar_nota', 'eliminar_nota'])
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- Internas: solo las usan otras funciones
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array[
             '_generar_usuario', '_crear_invitacion', '_puede_resolver_solicitud', '_puede_invitacion', '_puedo_gestionar', '_alcance_perfil', 'crear_invitacion_dueno'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
-- Quedan abiertas a todos: buscar_instituciones, solicitar_afiliacion, verificar_activacion (y las funciones de apoyo de las politicas)
