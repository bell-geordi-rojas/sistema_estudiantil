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
insert into config (clave, valor) values
  ('email_dominio', 'acceso.estudiantil.app'),
  ('mantenimiento', 'off'),                         -- 'on' = sistema en pausa para todos menos el dueno
  ('mantenimiento_msg', 'El sistema esta en mantenimiento. Intenta de nuevo en unos minutos.')
  on conflict do nothing;

create table if not exists instituciones (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) between 2 and 120),
  slug text not null unique,                 -- nombre de la carpeta, p. ej. Maria_Auxiliadora
  activa boolean not null default true,
  vence date,                                -- fin del alquiler (null = sin vencimiento)
  creado timestamptz not null default now()
);
alter table instituciones add column if not exists dominio text      -- dominio del correo institucional, p. ej. midominio.edu
  check (dominio is null or dominio ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');
-- Si esta activa, al registrar a alguien tambien se crea su cuenta REAL de Google Workspace (usuario@dominio) con el script de la institucion
alter table instituciones add column if not exists google_workspace boolean not null default false;
alter table instituciones add column if not exists tipo text not null default 'colegio' check (tipo in ('colegio', 'universidad'));

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

-- Foto de perfil: imagen JPEG pequena (la web la reduce a 192x192) guardada como data URL
alter table perfiles add column if not exists foto text
  check (foto is null or (length(foto) <= 45000 and foto ~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$'));

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

-- Trimestres (colegio) o ciclos (universidad) de cada institucion
create table if not exists periodos (
  id bigint generated always as identity primary key,
  institucion_id bigint not null references instituciones (id) on delete cascade,
  nombre text not null check (length(trim(nombre)) between 1 and 40),
  orden int not null default 0
);
create unique index if not exists periodos_nombre_unico on periodos (institucion_id, lower(nombre));

-- Cursos de cada institucion (los colegios empiezan con 7 por defecto y pueden agregar mas)
create table if not exists cursos (
  id bigint generated always as identity primary key,
  institucion_id bigint not null references instituciones (id) on delete cascade,
  nombre text not null check (length(trim(nombre)) between 1 and 80),
  orden int not null default 0
);
create unique index if not exists cursos_nombre_unico on cursos (institucion_id, lower(nombre));

-- Nivel de un colegio: en PRIMARIA el docente (tutor) dicta todos los cursos de su aula; en SECUNDARIA (y en la universidad)
-- cada docente dicta cursos concretos y cada alumno se inscribe en cursos. La universidad ademas tiene carreras.
alter table instituciones add column if not exists nivel text not null default 'primaria' check (nivel in ('primaria', 'secundaria'));
alter table instituciones add column if not exists migrado_cursos boolean not null default false;

-- Carreras de una universidad, cada una con su numero de ciclos (14 Medicina, 10 las demas por defecto)
create table if not exists carreras (
  id bigint generated always as identity primary key,
  institucion_id bigint not null references instituciones (id) on delete cascade,
  nombre text not null check (length(trim(nombre)) between 2 and 80),
  ciclos smallint not null default 10 check (ciclos between 1 and 14),
  orden int not null default 0
);
create unique index if not exists carreras_nombre_unico on carreras (institucion_id, lower(nombre));

alter table estudiantes add column if not exists carrera_id bigint references carreras (id) on delete restrict;
alter table estudiantes add column if not exists ciclo smallint not null default 1 check (ciclo between 1 and 14);   -- ciclo actual del alumno (universidad)
alter table cursos add column if not exists carrera_id bigint references carreras (id) on delete cascade;   -- null = curso comun
alter table cursos add column if not exists ciclo smallint check (ciclo is null or ciclo between 1 and 14);
drop index if exists cursos_nombre_unico;
create unique index if not exists cursos_nombre_unico on cursos (institucion_id, coalesce(carrera_id, 0), lower(nombre));

-- Que cursos dicta cada docente (secundaria y universidad)
create table if not exists docente_cursos (
  docente_id uuid not null references perfiles (id) on delete cascade,
  curso_id bigint not null references cursos (id) on delete cascade,
  primary key (docente_id, curso_id)
);
-- En que cursos esta inscrito cada alumno
create table if not exists inscripciones (
  estudiante_id bigint not null references estudiantes (id) on delete cascade,
  curso_id bigint not null references cursos (id) on delete cascade,
  creado timestamptz not null default now(),
  primary key (estudiante_id, curso_id)
);
create index if not exists inscripciones_curso on inscripciones (curso_id);
alter table carreras enable row level security;
alter table docente_cursos enable row level security;
alter table inscripciones enable row level security;

create or replace function _ciclos_defecto(p_nombre text) returns int language sql immutable as $$ select case when p_nombre ~* 'medicina' then 14 else 10 end $$;

-- Lista de carreras que ya viene cargada (el administrador puede agregar o eliminar)
create or replace function _sembrar_carreras(p_inst bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from carreras where institucion_id = p_inst) then return; end if;
  insert into carreras (institucion_id, nombre, ciclos, orden)
    select p_inst, c.n, _ciclos_defecto(c.n), c.o
    from unnest(array['Medicina Humana', 'Derecho', 'Administracion de Empresas', 'Contabilidad', 'Ingenieria de Sistemas',
                      'Ingenieria Civil', 'Psicologia', 'Enfermeria', 'Arquitectura', 'Educacion']) with ordinality as c(n, o);
end $$;

-- Inscripcion AUTOMATICA (los docentes se siguen asignando a mano):
--   universidad: el alumno entra en los cursos de su carrera y su ciclo; al crear un curso entran los alumnos de esa carrera y ciclo.
--   colegio secundaria: todos los alumnos llevan todos los cursos.
-- El administrador puede quitar o agregar inscripciones a mano despues.
create or replace function _autoinscribir_estudiante(p_est bigint) returns void language plpgsql security definer set search_path = public as $$
declare e estudiantes; v_tipo text; v_nivel text;
begin
  select * into e from estudiantes where id = p_est;
  if not found then return; end if;
  select tipo, nivel into v_tipo, v_nivel from instituciones where id = e.institucion_id;
  if v_tipo = 'universidad' then
    if e.carrera_id is not null then
      insert into inscripciones (estudiante_id, curso_id)
        select e.id, c.id from cursos c
        where c.institucion_id = e.institucion_id and c.carrera_id = e.carrera_id and c.ciclo = e.ciclo
        on conflict do nothing;
    end if;
  elsif v_nivel = 'secundaria' then
    insert into inscripciones (estudiante_id, curso_id)
      select e.id, c.id from cursos c where c.institucion_id = e.institucion_id
      on conflict do nothing;
  end if;
end $$;

create or replace function _autoinscribir_curso(p_curso bigint) returns void language plpgsql security definer set search_path = public as $$
declare c cursos; v_tipo text; v_nivel text;
begin
  select * into c from cursos where id = p_curso;
  if not found then return; end if;
  select tipo, nivel into v_tipo, v_nivel from instituciones where id = c.institucion_id;
  if v_tipo = 'universidad' then
    if c.carrera_id is not null and c.ciclo is not null then
      insert into inscripciones (estudiante_id, curso_id)
        select e.id, c.id from estudiantes e
        where e.institucion_id = c.institucion_id and e.carrera_id = c.carrera_id and e.ciclo = c.ciclo
        on conflict do nothing;
    end if;
  elsif v_nivel = 'secundaria' then
    insert into inscripciones (estudiante_id, curso_id)
      select e.id, c.id from estudiantes e where e.institucion_id = c.institucion_id
      on conflict do nothing;
  end if;
end $$;

-- Al pasar una institucion que ya tenia datos al modelo "por curso", nadie pierde acceso: los alumnos se inscriben en los cursos
-- existentes (de su carrera) y cada docente con alumnos recibe todos los cursos. Solo se hace una vez por institucion.
create or replace function _migrar_a_cursos(p_inst bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from instituciones where id = p_inst and migrado_cursos) then return; end if;
  insert into inscripciones (estudiante_id, curso_id)
    select e.id, c.id from estudiantes e join cursos c on c.institucion_id = e.institucion_id and (c.carrera_id is null or c.carrera_id = e.carrera_id)
    where e.institucion_id = p_inst on conflict do nothing;
  insert into docente_cursos (docente_id, curso_id)
    select p.id, c.id from perfiles p join cursos c on c.institucion_id = p.institucion_id
    where p.rol = 'docente' and p.institucion_id = p_inst and exists (select 1 from estudiantes e where e.docente_id = p.id)
    on conflict do nothing;
  update instituciones set migrado_cursos = true where id = p_inst;
end $$;

-- Las universidades tienen 14 ciclos fijos (Ciclo I ... Ciclo XIV); agrega los que falten
create or replace function _asegurar_ciclos(p_inst bigint) returns void language plpgsql security definer set search_path = public as $$
declare r text[] := array['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII', 'XIII', 'XIV']; i int;
begin
  for i in 1..14 loop
    insert into periodos (institucion_id, nombre, orden) values (p_inst, 'Ciclo ' || r[i], i) on conflict do nothing;
  end loop;
end $$;

-- Periodos y cursos iniciales de una institucion (solo si aun no tiene)
create or replace function _sembrar_institucion(p_inst bigint) returns void language plpgsql security definer set search_path = public as $$
declare v_tipo text;
begin
  select tipo into v_tipo from instituciones where id = p_inst;
  if v_tipo = 'universidad' then
    perform _asegurar_ciclos(p_inst);
  elsif not exists (select 1 from periodos where institucion_id = p_inst) then
    insert into periodos (institucion_id, nombre, orden) values (p_inst, 'Trimestre 1', 1), (p_inst, 'Trimestre 2', 2), (p_inst, 'Trimestre 3', 3);
  end if;
  if v_tipo = 'universidad' then
    perform _sembrar_carreras(p_inst);
    update instituciones set migrado_cursos = true where id = p_inst and not exists (select 1 from estudiantes where institucion_id = p_inst);   -- institucion nueva: nada que migrar
  end if;
  if v_tipo = 'colegio' and not exists (select 1 from cursos where institucion_id = p_inst) then
    insert into cursos (institucion_id, nombre, orden)
      select p_inst, c.n, c.o from unnest(array['Matematica', 'Ciencia y Tecnologia', 'Ciencias Sociales',
        'Desarrollo Personal, Ciudadania y Civica', 'Comunicacion', 'Arte', 'Ingles']) with ordinality as c(n, o);
  end if;
end $$;

-- Universidades ya existentes: completar sus 14 ciclos
do $$ declare i record; begin
  for i in select id from instituciones where tipo = 'universidad' loop perform _asegurar_ciclos(i.id); end loop;
end $$;

create table if not exists notas (
  id bigint generated always as identity primary key,
  estudiante_id bigint not null references estudiantes (id) on delete cascade,
  curso_id bigint not null references cursos (id) on delete cascade,
  periodo_id bigint not null references periodos (id) on delete cascade,
  nota numeric(4,2) not null check (nota between 0 and 20),
  peso smallint not null default 1 check (peso between 1 and 10)      -- ponderacion (universidades); 1 si no se elige
);

-- Migracion desde v2 (notas con curso 0..6 y sin periodo): las notas pasan al primer periodo de su institucion
do $$
declare i record;
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'notas' and column_name = 'curso') then
    for i in select id from instituciones loop perform _sembrar_institucion(i.id); end loop;
    alter table notas add column if not exists curso_id bigint references cursos (id) on delete cascade;
    alter table notas add column if not exists periodo_id bigint references periodos (id) on delete cascade;
    alter table notas add column if not exists peso smallint not null default 1 check (peso between 1 and 10);
    update notas n
      set curso_id = c.id,
          periodo_id = (select p.id from periodos p where p.institucion_id = e.institucion_id order by p.orden, p.id limit 1)
      from estudiantes e, cursos c
      where e.id = n.estudiante_id and c.institucion_id = e.institucion_id and c.orden = n.curso + 1;
    alter table notas alter column curso_id set not null;
    alter table notas alter column periodo_id set not null;
    alter table notas drop column curso;
  end if;
end $$;
create index if not exists notas_estudiante_curso_periodo on notas (estudiante_id, curso_id, periodo_id);

-- Nombre de la nota (examen, trabajo...) y comentario del docente.
-- El comentario va en otra tabla para que solo lo vean el personal de la institucion y el propio alumno
-- (un companero con permiso de ver notas ve las notas, pero no los comentarios).
alter table notas add column if not exists titulo text check (titulo is null or length(titulo) between 1 and 60);
create table if not exists notas_detalle (
  nota_id bigint primary key references notas (id) on delete cascade,
  comentario text not null check (length(comentario) between 1 and 500)
);

create or replace function _guardar_comentario(p_nota bigint, p_comentario text) returns void
language plpgsql security definer set search_path = public as $$
begin
  p_comentario := left(trim(coalesce(p_comentario, '')), 500);
  if p_comentario = '' then
    delete from notas_detalle where nota_id = p_nota;
  else
    insert into notas_detalle (nota_id, comentario) values (p_nota, p_comentario)
      on conflict (nota_id) do update set comentario = excluded.comentario;
  end if;
end $$;

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

-- Correo personal al que se envian las credenciales de una cuenta nueva (opcional)
alter table invitaciones add column if not exists correo text
  check (correo is null or (length(correo) <= 120 and correo ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'));

-- Conexion de correo de cada institucion: el Apps Script de la cuenta de Google de su director/administrador.
-- Sin politicas de lectura: la URL y la clave nunca llegan al navegador (solo se escriben por funciones).
create table if not exists instituciones_correo (
  institucion_id bigint primary key references instituciones (id) on delete cascade,
  url text not null,
  secreto text not null
);
alter table instituciones_correo enable row level security;

-- El envio de credenciales usa pg_net para llamar a un Google Apps Script que manda el correo desde tu Gmail
do $$ begin create extension if not exists pg_net; exception when others then raise notice 'pg_net no esta disponible: los correos no se enviaran automaticamente.'; end $$;

-- Cada nota debe usar un curso y un periodo de la institucion del estudiante; maximo 20 por curso y periodo;
-- el peso solo cuenta en universidades (en colegios siempre vale 1)
create or replace function validar_nota() returns trigger language plpgsql security definer set search_path = public as $$
declare v_inst bigint; v_tipo text; v_carrera bigint; v_ccar bigint; v_ciclos int; v_orden int;
begin
  select e.institucion_id, i.tipo, e.carrera_id into v_inst, v_tipo, v_carrera
    from estudiantes e join instituciones i on i.id = e.institucion_id where e.id = new.estudiante_id;
  select carrera_id into v_ccar from cursos where id = new.curso_id and institucion_id = v_inst;
  if not found then raise exception 'Curso invalido.'; end if;
  select orden into v_orden from periodos where id = new.periodo_id and institucion_id = v_inst;
  if not found then raise exception 'Periodo invalido.'; end if;
  if v_tipo = 'universidad' and v_carrera is not null then
    if v_ccar is not null and v_ccar <> v_carrera then raise exception 'Ese curso no es de la carrera del estudiante.'; end if;
    select ciclos into v_ciclos from carreras where id = v_carrera;
    if v_orden > v_ciclos then raise exception 'La carrera del estudiante solo tiene % ciclos.', v_ciclos; end if;
  end if;
  if v_tipo <> 'universidad' then new.peso := 1; end if;
  if tg_op = 'INSERT' and (select count(*) from notas where estudiante_id = new.estudiante_id
        and curso_id = new.curso_id and periodo_id = new.periodo_id) >= 20 then
    raise exception 'Maximo 20 calificaciones por curso y periodo.';
  end if;
  return new;
end $$;
drop trigger if exists limitar_notas_trg on notas;
drop trigger if exists validar_nota_trg on notas;
drop function if exists limitar_notas();
create trigger validar_nota_trg before insert or update on notas for each row execute function validar_nota();

-- ---------------------------------------------------------------------------
-- 2. Funciones de apoyo (permisos y alcance)
-- ---------------------------------------------------------------------------
create or replace function claves_permiso() returns text[] language sql immutable as $$
  select array['ver_companeros', 'ver_notas_companeros', 'ver_estadisticas', 'registrar_estudiantes',
               'editar_estudiantes', 'editar_notas', 'eliminar', 'exportar', 'gestionar_alumnos', 'gestionar_cursos'] $$;

-- Permisos por defecto: el alumno solo ve a sus companeros; el docente tiene todo lo de su clase
-- (menos agregar cursos a la institucion, que el administrador le puede conceder)
create or replace function permiso_defecto(p_rol rol_usuario, p_clave text) returns boolean language sql immutable as $$
  select case p_rol when 'alumno' then p_clave = 'ver_companeros'
                    when 'docente' then p_clave <> 'gestionar_cursos'
                    else true end $$;

-- Mantenimiento: con el sistema en pausa solo el dueno puede usarlo
create or replace function en_mantenimiento() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select valor = 'on' from config where clave = 'mantenimiento'), false) $$;

create or replace function estado_sistema() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('mantenimiento', en_mantenimiento(), 'mensaje', (select valor from config where clave = 'mantenimiento_msg')) $$;

-- Rol del usuario actual; null si no tiene acceso (cuenta desactivada, institucion suspendida / vencida o sistema en pausa)
create or replace function mi_rol() returns rol_usuario language sql stable security definer set search_path = public as $$
  select p.rol from perfiles p left join instituciones i on i.id = p.institucion_id
  where p.id = auth.uid() and p.activo
    and (p.rol = 'dueno' or (not en_mantenimiento() and i.activa and (i.vence is null or i.vence >= current_date))) $$;

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
-- La institucion trabaja "por curso" (secundaria y universidad): docentes con cursos asignados y alumnos inscritos
create or replace function _por_curso(p_inst bigint) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select tipo = 'universidad' or nivel = 'secundaria' from instituciones where id = p_inst), false) $$;
create or replace function _mi_estudiante() returns bigint language sql stable security definer set search_path = public as $$
  select id from estudiantes where perfil_id = auth.uid() $$;
create or replace function _ensena(p_curso bigint) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from docente_cursos where docente_id = auth.uid() and curso_id = p_curso) $$;
create or replace function _inscrito(p_est bigint, p_curso bigint) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from inscripciones where estudiante_id = p_est and curso_id = p_curso) $$;
-- El alumno actual comparte al menos un curso con p_est
create or replace function _comparten_curso(p_est bigint) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from inscripciones a join inscripciones b on a.curso_id = b.curso_id
                 where a.estudiante_id = p_est and b.estudiante_id = (select id from estudiantes where perfil_id = auth.uid())) $$;
create or replace function _comparten_perfil(p_perfil uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from estudiantes e where e.perfil_id = p_perfil and _comparten_curso(e.id)) $$;
-- El docente actual dicta algun curso en el que esta inscrito p_est
create or replace function _docente_ve_est(p_est bigint) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from inscripciones i join docente_cursos d on d.curso_id = i.curso_id where i.estudiante_id = p_est and d.docente_id = auth.uid()) $$;
create or replace function _docente_ve_perfil(p_perfil uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from estudiantes e where e.perfil_id = p_perfil and _docente_ve_est(e.id)) $$;

-- El usuario actual puede modificar los datos de ese estudiante (admin de su institucion; en primaria tambien su docente a cargo)
create or replace function _puedo_gestionar(p_est bigint) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from estudiantes e where e.id = p_est and (
    (mi_rol() = 'admin' and e.institucion_id = mi_inst())
    or (mi_rol() = 'docente' and e.docente_id = auth.uid() and not _por_curso(e.institucion_id)))) $$;

-- El usuario actual puede poner notas a p_est en el curso p_curso:
--   primaria: el admin o el docente a cargo del alumno (cualquier curso);
--   secundaria/universidad: el alumno debe estar inscrito en el curso y quien califica ser el admin o el docente que lo dicta.
create or replace function _puedo_calificar(p_est bigint, p_curso bigint) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from estudiantes e join cursos c on c.id = p_curso and c.institucion_id = e.institucion_id
    where e.id = p_est and (
      case when _por_curso(e.institucion_id) then
        exists (select 1 from inscripciones i where i.estudiante_id = e.id and i.curso_id = c.id)
        and ((mi_rol() = 'admin' and e.institucion_id = mi_inst())
             or (mi_rol() = 'docente' and exists (select 1 from docente_cursos d where d.docente_id = auth.uid() and d.curso_id = c.id)))
      else
        (mi_rol() = 'admin' and e.institucion_id = mi_inst()) or (mi_rol() = 'docente' and e.docente_id = auth.uid())
      end)) $$;

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
alter table notas_detalle enable row level security;
alter table cursos enable row level security;
alter table periodos enable row level security;
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
  or (mi_rol() = 'docente' and (docente_id = auth.uid() or (rol = 'alumno' and _docente_ve_perfil(id))))
  or (mi_rol() = 'alumno' and (id = mi_docente()
        or (permiso('ver_companeros') and rol = 'alumno' and ((docente_id is not null and docente_id = mi_docente()) or _comparten_perfil(id))))));

drop policy if exists est_sel on estudiantes;
create policy est_sel on estudiantes for select to authenticated using (
  mi_rol() = 'dueno'
  or (mi_rol() = 'admin' and institucion_id = mi_inst())
  or (mi_rol() = 'docente' and (docente_id = auth.uid() or _docente_ve_est(id)))
  or (mi_rol() = 'alumno' and (perfil_id = auth.uid()
        or (permiso('ver_companeros') and ((docente_id is not null and docente_id = mi_docente()) or _comparten_curso(id))))));

drop policy if exists notas_sel on notas;
create policy notas_sel on notas for select to authenticated using (
  exists (select 1 from estudiantes e where e.id = notas.estudiante_id
          and (mi_rol() <> 'alumno' or e.perfil_id = auth.uid() or permiso('ver_notas_companeros'))
          and (mi_rol() <> 'docente' or not _por_curso(e.institucion_id) or _ensena(notas.curso_id))));   -- en secundaria/universidad el docente solo ve las notas de sus cursos

drop policy if exists nd_sel on notas_detalle;
create policy nd_sel on notas_detalle for select to authenticated using (
  exists (select 1 from notas n join estudiantes e on e.id = n.estudiante_id
          where n.id = notas_detalle.nota_id and (mi_rol() <> 'alumno' or e.perfil_id = auth.uid())));

drop policy if exists cursos_sel on cursos;
create policy cursos_sel on cursos for select to authenticated using (
  mi_rol() = 'dueno'
  or (institucion_id = mi_inst() and (
        not _por_curso(institucion_id)                                   -- primaria: todos los cursos
        or mi_rol() = 'admin'                                            -- admin: todos
        or (mi_rol() = 'docente' and _ensena(id))                        -- docente: los que dicta
        or (mi_rol() = 'alumno' and _inscrito(_mi_estudiante(), id)))));  -- alumno: aquellos en los que esta inscrito

drop policy if exists carreras_sel on carreras;
create policy carreras_sel on carreras for select to authenticated using (mi_rol() = 'dueno' or institucion_id = mi_inst());

drop policy if exists dc_sel on docente_cursos;
create policy dc_sel on docente_cursos for select to authenticated using (
  mi_rol() = 'dueno' or docente_id = auth.uid()
  or (mi_rol() = 'admin' and exists (select 1 from cursos c where c.id = docente_cursos.curso_id and c.institucion_id = mi_inst())));

drop policy if exists insc_sel on inscripciones;
create policy insc_sel on inscripciones for select to authenticated using (
  mi_rol() = 'dueno'
  or (mi_rol() = 'admin' and exists (select 1 from cursos c where c.id = inscripciones.curso_id and c.institucion_id = mi_inst()))
  or (mi_rol() = 'docente' and _ensena(curso_id))
  or (mi_rol() = 'alumno' and estudiante_id = _mi_estudiante()));

drop policy if exists periodos_sel on periodos;
create policy periodos_sel on periodos for select to authenticated using (mi_rol() = 'dueno' or institucion_id = mi_inst());

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
  where i.activa and (i.vence is null or i.vence >= current_date) and not en_mantenimiento()
    and i.nombre ilike '%' || trim(coalesce(p_q, '')) || '%'
  order by i.nombre limit 10 $$;

create or replace function solicitar_afiliacion(p_institucion bigint, p_nombres text, p_apellidos text, p_rol text)
returns void language plpgsql security definer set search_path = public as $$
begin
  p_nombres := trim(coalesce(p_nombres, ''));
  p_apellidos := trim(coalesce(p_apellidos, ''));
  if en_mantenimiento() then raise exception 'El sistema esta en mantenimiento. Intenta de nuevo mas tarde.'; end if;
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
  if en_mantenimiento() then raise exception 'El sistema esta en mantenimiento. Intenta de nuevo mas tarde.'; end if;
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
  if en_mantenimiento() then raise exception 'El sistema esta en mantenimiento.'; end if;
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
  if p.rol <> 'dueno' and en_mantenimiento() then
    v_ok := false; v_motivo := (select valor from config where clave = 'mantenimiento_msg');
  elsif not p.activo then
    v_ok := false; v_motivo := 'Tu cuenta esta desactivada. Contacta a tu administrador.';
  elsif p.rol <> 'dueno' and not i.activa then
    v_ok := false; v_motivo := 'La afiliacion de tu institucion esta suspendida.';
  elsif p.rol <> 'dueno' and i.vence is not null and i.vence < current_date then
    v_ok := false; v_motivo := 'La afiliacion de tu institucion vencio.';
  end if;
  return jsonb_build_object(
    'id', p.id, 'usuario', p.usuario, 'nombres', p.nombres, 'apellidos', p.apellidos, 'rol', p.rol, 'foto', p.foto,
    'docente_id', p.docente_id, 'acceso', v_ok, 'motivo', v_motivo,
    'mantenimiento', en_mantenimiento(), 'mensaje_mantenimiento', (select valor from config where clave = 'mantenimiento_msg'),
    'correo', exists (select 1 from instituciones_correo where institucion_id = p.institucion_id)
              or (exists (select 1 from config where clave = 'correo_url') and exists (select 1 from config where clave = 'correo_secreto')),
    'institucion', case when i.id is null then null
                        else jsonb_build_object('id', i.id, 'nombre', i.nombre, 'slug', i.slug, 'vence', i.vence, 'tipo', i.tipo, 'nivel', i.nivel, 'dominio', i.dominio,
                                                  'correo_propio', exists (select 1 from instituciones_correo where institucion_id = i.id),
                                                  'google', i.google_workspace) end,
    'permisos', (select jsonb_object_agg(k, permiso(k)) from unnest(claves_permiso()) as k));
end $$;

-- ---------------------------------------------------------------------------
-- 8. Cuentas e instituciones
-- ---------------------------------------------------------------------------
-- Cualquier cuenta puede cambiar su propio nombre y su foto (si es alumno, tambien cambia su nombre en la lista de estudiantes)
create or replace function actualizar_mi_perfil(p_nombres text, p_apellidos text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is null then raise exception 'No autorizado.'; end if;
  p_nombres := trim(coalesce(p_nombres, ''));
  p_apellidos := trim(coalesce(p_apellidos, ''));
  if p_nombres = '' or p_nombres ~ '[0-9|]' or p_apellidos ~ '[0-9|]' or length(p_nombres || p_apellidos) > 100 then
    raise exception 'Escribe tus nombres y apellidos (sin numeros).';
  end if;
  update perfiles set nombres = p_nombres, apellidos = p_apellidos where id = auth.uid();
  update estudiantes set nombre = trim(p_nombres || ' ' || p_apellidos) where perfil_id = auth.uid();
end $$;

create or replace function actualizar_mi_foto(p_foto text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is null then raise exception 'No autorizado.'; end if;
  update perfiles set foto = nullif(trim(coalesce(p_foto, '')), '') where id = auth.uid();
end $$;

drop function if exists _generar_usuario(text, text);
create or replace function _generar_usuario(p_nombres text, p_apellidos text, p_inst bigint default null, p_ap1 text default null, p_ap2 text default null) returns text
language plpgsql set search_path = public as $$
declare base text; u text; n int := 1; v_dom text; a1 text; a2 text; ap text := trim(coalesce(p_apellidos, ''));
begin
  select dominio into v_dom from instituciones where id = p_inst;
  if v_dom is not null then
    -- Patron institucional (ej. Juan Carlos Pérez Gómez -> pgomezj): inicial del 1er apellido + 2do apellido + inicial del nombre
    a1 := coalesce(nullif(trim(p_ap1), ''), split_part(ap, ' ', 1));
    a2 := coalesce(nullif(trim(p_ap2), ''), nullif(trim(substr(ap, length(split_part(ap, ' ', 1)) + 1)), ''));
    -- la inicial del apellido ignora particulas (de la Cruz -> c)
    base := case when a2 is null then left(trim(p_nombres), 1) || a1
                 else left(regexp_replace(a1, '^((de|del|la|las|los|y|san|santa|da|di|van|von)\s+)+', '', 'i'), 1) || a2 || left(trim(p_nombres), 1) end;
  else
    base := left(trim(p_nombres), 1) || split_part(ap, ' ', 1);
  end if;
  base := lower(translate(base, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'));
  base := regexp_replace(base, '[^a-z0-9]', '', 'g');
  if length(base) < 3 then base := base || 'usr'; end if;
  base := left(base, 26);
  u := base;
  while exists (select 1 from perfiles where usuario = u) or exists (select 1 from invitaciones where usuario = u) loop
    n := n + 1; u := base || n;
  end loop;
  return u;
end $$;

-- Envia las credenciales al correo personal (Gmail) mediante el Apps Script configurado con configurar_correo(); nunca rompe la creacion de la cuenta
drop function if exists _enviar_credenciales(text, text, text, text, text, bigint, text);
create or replace function _enviar_credenciales(p_correo text, p_nombre text, p_correo_inst text, p_usuario text, p_codigo text, p_inst bigint, p_rol text,
                                                p_nombres text default null, p_apellidos text default null, p_clave_google text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_url text; v_sec text; v_nom text; v_propio boolean;
begin
  select url, secreto into v_url, v_sec from instituciones_correo where institucion_id = p_inst;   -- cuenta de Google de la propia institucion
  v_propio := v_url is not null;
  if v_url is null then
    select valor into v_url from config where clave = 'correo_url';                                -- si no, la conexion general del sistema (si el dueno la configuro)
    select valor into v_sec from config where clave = 'correo_secreto';
  end if;
  if v_url is null or v_sec is null or (p_correo is null and p_clave_google is null) then return false; end if;
  select nombre into v_nom from instituciones where id = p_inst;
  perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('secreto', v_sec, 'para', p_correo, 'nombre', p_nombre, 'nombres', p_nombres, 'apellidos', p_apellidos,
                               'correo_institucional', p_correo_inst, 'usuario', p_usuario, 'codigo', p_codigo, 'institucion', v_nom, 'rol', p_rol,
                               'crear_google', (p_clave_google is not null and v_propio),   -- la cuenta de Google solo se crea con el script de la propia institucion
                               'clave_google', case when v_propio then p_clave_google end,
                               'app', 'https://bell786u-ctrl.github.io/sistema_estudiantil/'));
  return true;
exception when others then
  return false;
end $$;

drop function if exists _crear_invitacion(rol_usuario, text, text, bigint, uuid, uuid);
drop function if exists _crear_invitacion(rol_usuario, text, text, bigint, uuid, uuid, text, text, text);
drop function if exists _crear_invitacion(rol_usuario, text, text, bigint, uuid, uuid, text, text, text, bigint);
create or replace function _crear_invitacion(p_rol rol_usuario, p_nombres text, p_apellidos text, p_inst bigint, p_docente uuid, p_creador uuid, p_correo text default null, p_ap1 text default null, p_ap2 text default null, p_carrera bigint default null, p_ciclo int default 1)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_usuario text; v_codigo text; v_est bigint; v_cod_est text; base text; n int := 1; v_dom text; v_ci text; v_env boolean := false; v_gw boolean; v_cg text; v_tipo text;
begin
  if p_rol = 'alumno' then
    select tipo into v_tipo from instituciones where id = p_inst;
    if v_tipo = 'universidad' then
      if p_carrera is null or not exists (select 1 from carreras where id = p_carrera and institucion_id = p_inst) then raise exception 'Elige la carrera del alumno.'; end if;
      p_ciclo := coalesce(p_ciclo, 1);
      if p_ciclo < 1 or p_ciclo > (select ciclos from carreras where id = p_carrera) then raise exception 'Esa carrera solo tiene % ciclos.', (select ciclos from carreras where id = p_carrera); end if;
    else
      p_carrera := null; p_ciclo := 1;
    end if;
  end if;
  v_usuario := _generar_usuario(p_nombres, p_apellidos, p_inst, p_ap1, p_ap2);
  v_codigo := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 10));
  if p_rol = 'alumno' then
    base := left(upper(v_usuario), 13);
    v_cod_est := base;
    while exists (select 1 from estudiantes where institucion_id = p_inst and upper(codigo) = v_cod_est) loop
      n := n + 1; v_cod_est := base || n;
    end loop;
    insert into estudiantes (institucion_id, docente_id, carrera_id, ciclo, codigo, nombre)
      values (p_inst, p_docente, p_carrera, coalesce(p_ciclo, 1), v_cod_est, trim(p_nombres || ' ' || p_apellidos)) returning id into v_est;
    perform _autoinscribir_estudiante(v_est);   -- queda inscrito en los cursos de su carrera y ciclo
  end if;
  insert into invitaciones (institucion_id, rol, nombres, apellidos, usuario, codigo_hash, docente_id, estudiante_id, creado_por, correo)
    values (p_inst, p_rol, trim(p_nombres), trim(p_apellidos), v_usuario, crypt(v_codigo, gen_salt('bf')), p_docente, v_est, p_creador, nullif(trim(coalesce(p_correo, '')), ''));
  select dominio, google_workspace into v_dom, v_gw from instituciones where id = p_inst;
  if v_dom is not null then v_ci := v_usuario || '@' || v_dom; end if;
  -- Cuenta real de Google Workspace: contrasena temporal aleatoria (Google pedira cambiarla al primer ingreso)
  if v_gw and v_dom is not null and exists (select 1 from instituciones_correo where institucion_id = p_inst) then
    v_cg := translate(encode(gen_random_bytes(9), 'base64'), '+/', 'Ab') || '7';
  end if;
  if nullif(trim(coalesce(p_correo, '')), '') is not null or v_cg is not null then
    v_env := _enviar_credenciales(nullif(trim(coalesce(p_correo, '')), ''), trim(p_nombres || ' ' || p_apellidos), v_ci, v_usuario, v_codigo, p_inst, p_rol::text,
                                  trim(p_nombres), trim(p_apellidos), v_cg);
  end if;
  return jsonb_build_object('usuario', v_usuario, 'codigo', v_codigo, 'rol', p_rol, 'correo_institucional', v_ci,
                            'correo_personal', nullif(trim(coalesce(p_correo, '')), ''), 'enviado', v_env, 'clave_google', v_cg);
end $$;

-- Crea una cuenta pendiente de activar; devuelve usuario + codigo (el codigo solo se ve ahora)
drop function if exists crear_invitacion(text, text, text, bigint, uuid);
drop function if exists crear_invitacion(text, text, text, bigint, uuid, text, text, text);
drop function if exists crear_invitacion(text, text, text, bigint, uuid, text, text, text, bigint);
create or replace function crear_invitacion(p_rol text, p_nombres text, p_apellidos text, p_institucion bigint default null, p_docente uuid default null, p_correo text default null, p_ap1 text default null, p_ap2 text default null, p_carrera bigint default null, p_ciclo int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r rol_usuario := mi_rol(); v_rol rol_usuario; v_inst bigint; v_doc uuid;
begin
  if r is null then raise exception 'No autorizado.'; end if;
  p_nombres := trim(coalesce(p_nombres, ''));
  p_apellidos := trim(coalesce(p_apellidos, ''));
  if p_nombres = '' or p_nombres ~ '[0-9|]' or p_apellidos ~ '[0-9|]' or coalesce(p_ap1, '') ~ '[0-9|]' or coalesce(p_ap2, '') ~ '[0-9|]' or length(p_nombres || p_apellidos) > 100 then
    raise exception 'Nombres invalidos (sin numeros).';
  end if;
  p_correo := nullif(lower(trim(coalesce(p_correo, ''))), '');
  if p_correo is not null and (length(p_correo) > 120 or p_correo !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'Correo personal invalido.'; end if;
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
    if _por_curso(mi_inst()) then raise exception 'En esta institucion solo el administrador registra e inscribe alumnos.'; end if;
    v_inst := mi_inst(); v_doc := auth.uid();
  else
    raise exception 'No autorizado.';
  end if;
  if v_rol = 'alumno' and not _por_curso(v_inst) then
    if v_doc is null then raise exception 'Elige el docente del alumno.'; end if;
    if not exists (select 1 from perfiles where id = v_doc and rol = 'docente' and institucion_id = v_inst) then raise exception 'Docente invalido.'; end if;
  else
    v_doc := null;   -- en secundaria/universidad el alumno no tiene un unico docente: se inscribe en cursos
  end if;
  return _crear_invitacion(v_rol, p_nombres, p_apellidos, v_inst, v_doc, auth.uid(), p_correo, p_ap1, p_ap2, p_carrera, p_ciclo);
end $$;

-- Varias cuentas a la vez: [{nombres, ap1, ap2, correo}]. Devuelve una fila por cuenta (credenciales o el motivo del error);
-- un error en una fila no frena las demas. Maximo 30 por llamada (la web envia por tandas).
drop function if exists crear_invitaciones_masivo(jsonb, text, uuid, bigint);
drop function if exists crear_invitaciones_masivo(jsonb, text, uuid, bigint, bigint);
create or replace function crear_invitaciones_masivo(p_items jsonb, p_rol text, p_docente uuid default null, p_institucion bigint default null, p_carrera bigint default null, p_ciclo int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; r jsonb := '[]'::jsonb; v jsonb; v_nom text;
begin
  if mi_rol() is null then raise exception 'No autorizado.'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then raise exception 'Formato invalido.'; end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Maximo 30 cuentas por envio.'; end if;
  for x in select * from jsonb_array_elements(p_items) loop
    v_nom := trim(coalesce(x ->> 'nombres', '') || ' ' || coalesce(x ->> 'ap1', '') || ' ' || coalesce(x ->> 'ap2', ''));
    begin
      v := crear_invitacion(p_rol, x ->> 'nombres', trim(coalesce(x ->> 'ap1', '') || ' ' || coalesce(x ->> 'ap2', '')),
                            p_institucion, p_docente, x ->> 'correo', x ->> 'ap1', x ->> 'ap2', p_carrera, p_ciclo);
      r := r || jsonb_build_array(v || jsonb_build_object('ok', true, 'nombre', v_nom));
    exception when others then
      r := r || jsonb_build_array(jsonb_build_object('ok', false, 'nombre', v_nom, 'error', sqlerrm));
    end;
  end loop;
  return r;
end $$;

create or replace function _puede_resolver_solicitud(s solicitudes) returns boolean language sql stable security definer set search_path = public as $$
  select case mi_rol()
    when 'dueno' then true
    when 'admin' then s.institucion_id = mi_inst()
    when 'docente' then permiso('gestionar_alumnos') and s.rol_solicitado = 'alumno' and s.institucion_id = mi_inst()
    else false end $$;

drop function if exists aprobar_solicitud(bigint, uuid);
drop function if exists aprobar_solicitud(bigint, uuid, bigint);
create or replace function aprobar_solicitud(p_id bigint, p_docente uuid default null, p_carrera bigint default null, p_ciclo int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s solicitudes; v_doc uuid; v jsonb;
begin
  select * into s from solicitudes where id = p_id and estado = 'pendiente' for update;
  if not found then raise exception 'Solicitud no encontrada.'; end if;
  if not _puede_resolver_solicitud(s) then raise exception 'No autorizado.'; end if;
  if mi_rol() = 'docente' and _por_curso(s.institucion_id) then raise exception 'En esta institucion solo el administrador registra e inscribe alumnos.'; end if;
  if s.rol_solicitado = 'alumno' and not _por_curso(s.institucion_id) then
    v_doc := case when mi_rol() = 'docente' then auth.uid() else p_docente end;
    if v_doc is null or not exists (select 1 from perfiles where id = v_doc and rol = 'docente' and institucion_id = s.institucion_id) then
      raise exception 'Elige el docente del alumno.';
    end if;
  end if;
  v := _crear_invitacion(s.rol_solicitado::rol_usuario, s.nombres, s.apellidos, s.institucion_id, v_doc, auth.uid(), null, null, null, p_carrera, p_ciclo);
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
declare inv invitaciones; v_codigo text; v_dom text; v_ci text; v_env boolean := false;
begin
  select * into inv from invitaciones where id = p_id and not usado for update;
  if not found then raise exception 'Invitacion no encontrada.'; end if;
  if not _puede_invitacion(inv) then raise exception 'No autorizado.'; end if;
  v_codigo := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 10));
  update invitaciones set codigo_hash = crypt(v_codigo, gen_salt('bf')) where id = p_id;
  select dominio into v_dom from instituciones where id = inv.institucion_id;
  if v_dom is not null then v_ci := inv.usuario || '@' || v_dom; end if;
  if inv.correo is not null then   -- si se registro un correo personal, el codigo nuevo se reenvia ahi
    v_env := _enviar_credenciales(inv.correo, trim(inv.nombres || ' ' || inv.apellidos), v_ci, inv.usuario, v_codigo, inv.institucion_id, inv.rol::text);
  end if;
  return jsonb_build_object('usuario', inv.usuario, 'codigo', v_codigo, 'rol', inv.rol, 'correo_institucional', v_ci, 'correo_personal', inv.correo, 'enviado', v_env);
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

drop function if exists crear_institucion(text, date);
drop function if exists crear_institucion(text, date, text);
create or replace function crear_institucion(p_nombre text, p_vence date default null, p_tipo text default 'colegio', p_nivel text default 'primaria') returns bigint
language plpgsql security definer set search_path = public as $$
declare base text; v_slug text; v_id bigint; n int := 1;
begin
  if mi_rol() is distinct from 'dueno' then raise exception 'No autorizado.'; end if;
  if p_tipo not in ('colegio', 'universidad') then raise exception 'Tipo de institucion invalido.'; end if;
  if coalesce(p_nivel, 'primaria') not in ('primaria', 'secundaria') then raise exception 'Nivel invalido.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if length(p_nombre) < 2 then raise exception 'Escribe el nombre de la institucion.'; end if;
  base := limpiar_slug(p_nombre);
  if base = '' then base := 'Institucion'; end if;
  v_slug := base;
  while exists (select 1 from instituciones where slug = v_slug) loop n := n + 1; v_slug := base || '_' || n; end loop;
  insert into instituciones (nombre, slug, vence, tipo, nivel) values (p_nombre, v_slug, p_vence, p_tipo, coalesce(p_nivel, 'primaria')) returning id into v_id;
  perform _sembrar_institucion(v_id);
  if _por_curso(v_id) then update instituciones set migrado_cursos = true where id = v_id; end if;   -- institucion nueva: nada que migrar
  return v_id;
end $$;

-- Dominio del correo institucional (p. ej. midominio.edu): lo define el dueno o el administrador de esa institucion
create or replace function actualizar_dominio(p_inst bigint, p_dominio text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (mi_rol() = 'dueno' or (mi_rol() = 'admin' and p_inst = mi_inst())) then raise exception 'No autorizado.'; end if;
  p_dominio := regexp_replace(lower(trim(coalesce(p_dominio, ''))), '^@', '');
  if p_dominio <> '' and p_dominio !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' then
    raise exception 'Dominio invalido (ejemplo: midominio.edu).';
  end if;
  update instituciones set dominio = nullif(p_dominio, '') where id = p_inst;
  if not found then raise exception 'Institucion no encontrada.'; end if;
end $$;

-- Colegio <-> universidad (al volver a colegio, todos los pesos quedan en 1)
drop function if exists cambiar_tipo_institucion(bigint, text);
create or replace function cambiar_tipo_institucion(p_id bigint, p_tipo text, p_nivel text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'dueno' then raise exception 'No autorizado.'; end if;
  if p_tipo not in ('colegio', 'universidad') then raise exception 'Tipo de institucion invalido.'; end if;
  if p_nivel is not null and p_nivel not in ('primaria', 'secundaria') then raise exception 'Nivel invalido.'; end if;
  update instituciones set tipo = p_tipo, nivel = coalesce(p_nivel, nivel) where id = p_id;
  if not found then raise exception 'Institucion no encontrada.'; end if;
  if p_tipo = 'universidad' then perform _asegurar_ciclos(p_id); perform _sembrar_carreras(p_id); end if;
  if p_tipo = 'colegio' then
    update notas set peso = 1 where peso <> 1 and estudiante_id in (select id from estudiantes where institucion_id = p_id);
  end if;
  if _por_curso(p_id) then perform _migrar_a_cursos(p_id); end if;   -- primaria -> secundaria/universidad: nadie pierde acceso
end $$;

-- Borra la institucion con todo lo suyo: cuentas, estudiantes, notas, cursos, periodos, solicitudes e invitaciones
create or replace function eliminar_institucion(p_id bigint, p_confirmar text) returns void
language plpgsql security definer set search_path = public as $$
declare v_nombre text;
begin
  if mi_rol() is distinct from 'dueno' then raise exception 'No autorizado.'; end if;
  select nombre into v_nombre from instituciones where id = p_id;
  if not found then raise exception 'Institucion no encontrada.'; end if;
  if trim(coalesce(p_confirmar, '')) <> v_nombre then raise exception 'El nombre escrito no coincide: no se elimino nada.'; end if;
  delete from auth.users where id in (select id from perfiles where institucion_id = p_id);
  delete from instituciones where id = p_id;
end $$;

-- Pausar / reanudar todo el sistema (mantenimiento)
create or replace function poner_mantenimiento(p_activo boolean, p_mensaje text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'dueno' then raise exception 'No autorizado.'; end if;
  insert into config (clave, valor) values ('mantenimiento', case when p_activo then 'on' else 'off' end)
    on conflict (clave) do update set valor = excluded.valor;
  if nullif(trim(coalesce(p_mensaje, '')), '') is not null then
    insert into config (clave, valor) values ('mantenimiento_msg', left(trim(p_mensaje), 300))
      on conflict (clave) do update set valor = excluded.valor;
  end if;
end $$;

-- Cursos (administrador, o docente con el permiso gestionar_cursos) y periodos (solo administrador) de su institucion
create or replace function _puede_cursos() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(mi_rol() = 'admin' or (mi_rol() = 'docente' and permiso('gestionar_cursos')), false) $$;

drop function if exists crear_curso(text);
create or replace function crear_curso(p_nombre text, p_carrera bigint default null, p_ciclo int default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_inst bigint := mi_inst(); v_ciclos int;
begin
  if not _puede_cursos() then raise exception 'No autorizado.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if p_nombre = '' or length(p_nombre) > 80 then raise exception 'Escribe el nombre del curso (maximo 80 caracteres).'; end if;
  if p_carrera is not null then
    select ciclos into v_ciclos from carreras where id = p_carrera and institucion_id = v_inst;
    if not found then raise exception 'Carrera invalida.'; end if;
    if p_ciclo is not null and (p_ciclo < 1 or p_ciclo > v_ciclos) then raise exception 'Esa carrera solo tiene % ciclos.', v_ciclos; end if;
  else
    p_ciclo := null;
  end if;
  if exists (select 1 from cursos where institucion_id = v_inst and coalesce(carrera_id, 0) = coalesce(p_carrera, 0) and lower(nombre) = lower(p_nombre)) then
    raise exception 'Ya existe un curso con ese nombre%.', case when p_carrera is null then '' else ' en esa carrera' end;
  end if;
  if (select count(*) from cursos where institucion_id = v_inst) >= 600 then raise exception 'Se alcanzo el maximo de 600 cursos.'; end if;
  insert into cursos (institucion_id, nombre, orden, carrera_id, ciclo)
    values (v_inst, p_nombre, coalesce((select max(orden) from cursos where institucion_id = v_inst), 0) + 1, p_carrera, p_ciclo) returning id into v_id;
  if mi_rol() = 'docente' and _por_curso(v_inst) then insert into docente_cursos (docente_id, curso_id) values (auth.uid(), v_id); end if;   -- el docente que lo crea lo dicta
  perform _autoinscribir_curso(v_id);   -- los alumnos de esa carrera y ciclo (o todos, en secundaria) quedan inscritos
  return v_id;
end $$;

create or replace function renombrar_curso(p_id bigint, p_nombre text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _puede_cursos() then raise exception 'No autorizado.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if p_nombre = '' or length(p_nombre) > 80 then raise exception 'Escribe el nombre del curso (maximo 80 caracteres).'; end if;
  if exists (select 1 from cursos c where c.institucion_id = mi_inst() and lower(c.nombre) = lower(p_nombre) and c.id <> p_id
             and coalesce(c.carrera_id, 0) = coalesce((select carrera_id from cursos where id = p_id), 0)) then raise exception 'Ya existe un curso con ese nombre.'; end if;
  update cursos set nombre = p_nombre where id = p_id and institucion_id = mi_inst();
  if not found then raise exception 'Curso no encontrado.'; end if;
end $$;

-- Ojo: borrar un curso borra tambien las notas que tenga
create or replace function eliminar_curso(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _puede_cursos() then raise exception 'No autorizado.'; end if;
  delete from cursos where id = p_id and institucion_id = mi_inst();
  if not found then raise exception 'Curso no encontrado.'; end if;
end $$;

create or replace function crear_periodo(p_nombre text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_inst bigint := mi_inst();
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  if (select tipo from instituciones where id = v_inst) = 'universidad' then raise exception 'Las universidades tienen 14 ciclos fijos.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if p_nombre = '' or length(p_nombre) > 40 then raise exception 'Escribe el nombre (maximo 40 caracteres).'; end if;
  if exists (select 1 from periodos where institucion_id = v_inst and lower(nombre) = lower(p_nombre)) then raise exception 'Ya existe uno con ese nombre.'; end if;
  if (select count(*) from periodos where institucion_id = v_inst) >= 30 then raise exception 'Se alcanzo el maximo de 30 periodos.'; end if;
  insert into periodos (institucion_id, nombre, orden)
    values (v_inst, p_nombre, coalesce((select max(orden) from periodos where institucion_id = v_inst), 0) + 1) returning id into v_id;
  return v_id;
end $$;

create or replace function renombrar_periodo(p_id bigint, p_nombre text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  if (select tipo from instituciones where id = mi_inst()) = 'universidad' then raise exception 'Las universidades tienen 14 ciclos fijos.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if p_nombre = '' or length(p_nombre) > 40 then raise exception 'Escribe el nombre (maximo 40 caracteres).'; end if;
  if exists (select 1 from periodos where institucion_id = mi_inst() and lower(nombre) = lower(p_nombre) and id <> p_id) then raise exception 'Ya existe uno con ese nombre.'; end if;
  update periodos set nombre = p_nombre where id = p_id and institucion_id = mi_inst();
  if not found then raise exception 'No encontrado.'; end if;
end $$;

-- Ojo: borrar un periodo borra tambien las notas de ese periodo (siempre debe quedar al menos uno)
create or replace function eliminar_periodo(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  if (select tipo from instituciones where id = mi_inst()) = 'universidad' then raise exception 'Las universidades tienen 14 ciclos fijos.'; end if;
  if (select count(*) from periodos where institucion_id = mi_inst()) <= 1 then raise exception 'Debe quedar al menos un periodo.'; end if;
  delete from periodos where id = p_id and institucion_id = mi_inst();
  if not found then raise exception 'No encontrado.'; end if;
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
declare r rol_usuario := mi_rol(); v_inst bigint := mi_inst(); v_doc uuid; v_id bigint; v_nota bigint; x jsonb;
begin
  if r not in ('admin', 'docente') or not permiso('registrar_estudiantes') then raise exception 'No autorizado.'; end if;
  if r = 'docente' and _por_curso(v_inst) then raise exception 'En esta institucion solo el administrador registra e inscribe alumnos.'; end if;
  v_doc := case when r = 'docente' then auth.uid() else p_docente end;
  if v_doc is not null and not exists (select 1 from perfiles where id = v_doc and rol = 'docente' and institucion_id = v_inst) then
    raise exception 'Docente invalido.';
  end if;
  -- p_notas: [{"curso": id, "periodo": id, "nota": 0-20, "peso": 1, "titulo": "Examen 1", "comentario": "..."}] (peso, titulo y comentario son opcionales)
  p_notas := coalesce(p_notas, '[]'::jsonb);
  if jsonb_typeof(p_notas) <> 'array' then raise exception 'Formato de notas invalido.'; end if;
  insert into estudiantes (institucion_id, docente_id, codigo, nombre) values (v_inst, v_doc, trim(p_codigo), trim(p_nombre)) returning id into v_id;
  for x in select * from jsonb_array_elements(p_notas) loop
    insert into notas (estudiante_id, curso_id, periodo_id, nota, peso, titulo)
      values (v_id, (x ->> 'curso')::bigint, (x ->> 'periodo')::bigint, (x ->> 'nota')::numeric, coalesce((x ->> 'peso')::smallint, 1),
              nullif(left(trim(coalesce(x ->> 'titulo', '')), 60), ''))
      returning id into v_nota;
    perform _guardar_comentario(v_nota, x ->> 'comentario');
    if _por_curso(v_inst) then insert into inscripciones (estudiante_id, curso_id) values (v_id, (x ->> 'curso')::bigint) on conflict do nothing; end if;
  end loop;
  if _por_curso(v_inst) then perform _autoinscribir_estudiante(v_id); end if;
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

drop function if exists agregar_nota(bigint, int, numeric);
drop function if exists agregar_nota(bigint, bigint, bigint, numeric, int);
create or replace function agregar_nota(p_estudiante bigint, p_curso bigint, p_periodo bigint, p_nota numeric, p_peso int default 1,
                                        p_titulo text default null, p_comentario text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not permiso('editar_notas') or not _puedo_calificar(p_estudiante, p_curso) then raise exception 'No autorizado: el alumno debe estar inscrito en el curso y el curso debe ser tuyo.'; end if;
  insert into notas (estudiante_id, curso_id, periodo_id, nota, peso, titulo)
    values (p_estudiante, p_curso, p_periodo, p_nota, coalesce(p_peso, 1), nullif(left(trim(coalesce(p_titulo, '')), 60), ''))
    returning id into v_id;
  perform _guardar_comentario(v_id, p_comentario);
end $$;

-- Al editar, titulo y comentario se reemplazan siempre (vacio = quitarlos); el peso solo cambia si se envia
drop function if exists actualizar_nota(bigint, numeric);
drop function if exists actualizar_nota(bigint, numeric, int);
create or replace function actualizar_nota(p_id bigint, p_nota numeric, p_peso int default null,
                                           p_titulo text default null, p_comentario text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_est bigint; v_cur bigint;
begin
  select estudiante_id, curso_id into v_est, v_cur from notas where id = p_id;
  if v_est is null or not permiso('editar_notas') or not _puedo_calificar(v_est, v_cur) then raise exception 'No autorizado.'; end if;
  update notas set nota = p_nota, peso = coalesce(p_peso, peso), titulo = nullif(left(trim(coalesce(p_titulo, '')), 60), '') where id = p_id;
  perform _guardar_comentario(p_id, p_comentario);
end $$;

create or replace function eliminar_nota(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_est bigint; v_cur bigint;
begin
  select estudiante_id, curso_id into v_est, v_cur from notas where id = p_id;
  if v_est is null or not permiso('editar_notas') or not _puedo_calificar(v_est, v_cur) then raise exception 'No autorizado.'; end if;
  delete from notas where id = p_id;
end $$;

-- ---------------------------------------------------------------------------
-- Carreras, docentes por curso e inscripciones (administrador)
-- ---------------------------------------------------------------------------
create or replace function crear_carrera(p_nombre text, p_ciclos int default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_inst bigint := mi_inst();
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  if not exists (select 1 from instituciones where id = v_inst and tipo = 'universidad') then raise exception 'Las carreras son solo para universidades.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if length(p_nombre) < 2 or length(p_nombre) > 80 then raise exception 'Escribe el nombre de la carrera.'; end if;
  p_ciclos := coalesce(p_ciclos, _ciclos_defecto(p_nombre));   -- Medicina: 14 ciclos; las demas: 10
  if p_ciclos < 1 or p_ciclos > 14 then raise exception 'Los ciclos deben ser de 1 a 14.'; end if;
  if exists (select 1 from carreras where institucion_id = v_inst and lower(nombre) = lower(p_nombre)) then raise exception 'Ya existe esa carrera.'; end if;
  insert into carreras (institucion_id, nombre, ciclos, orden)
    values (v_inst, p_nombre, p_ciclos, coalesce((select max(orden) from carreras where institucion_id = v_inst), 0) + 1) returning id into v_id;
  return v_id;
end $$;

create or replace function editar_carrera(p_id bigint, p_nombre text, p_ciclos int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  p_nombre := trim(coalesce(p_nombre, ''));
  if length(p_nombre) < 2 or length(p_nombre) > 80 then raise exception 'Escribe el nombre de la carrera.'; end if;
  if p_ciclos < 1 or p_ciclos > 14 then raise exception 'Los ciclos deben ser de 1 a 14.'; end if;
  if exists (select 1 from carreras where institucion_id = mi_inst() and lower(nombre) = lower(p_nombre) and id <> p_id) then raise exception 'Ya existe esa carrera.'; end if;
  if exists (select 1 from cursos where carrera_id = p_id and ciclo > p_ciclos) then raise exception 'Hay cursos en ciclos mayores a %: muevelos o eliminalos antes.', p_ciclos; end if;
  update carreras set nombre = p_nombre, ciclos = p_ciclos where id = p_id and institucion_id = mi_inst();
  if not found then raise exception 'Carrera no encontrada.'; end if;
end $$;

-- Una carrera con estudiantes no se puede eliminar; sus cursos se eliminan con ella (sin estudiantes no hay notas)
create or replace function eliminar_carrera(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  if exists (select 1 from estudiantes where carrera_id = p_id) then raise exception 'Hay estudiantes en esa carrera: pasalos a otra antes de eliminarla.'; end if;
  delete from carreras where id = p_id and institucion_id = mi_inst();
  if not found then raise exception 'Carrera no encontrada.'; end if;
end $$;

create or replace function asignar_curso_docente(p_docente uuid, p_curso bigint, p_asignar boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  if not exists (select 1 from perfiles where id = p_docente and rol = 'docente' and institucion_id = mi_inst()) then raise exception 'Docente invalido.'; end if;
  if not exists (select 1 from cursos where id = p_curso and institucion_id = mi_inst()) then raise exception 'Curso invalido.'; end if;
  if p_asignar then
    insert into docente_cursos (docente_id, curso_id) values (p_docente, p_curso) on conflict do nothing;
  else
    delete from docente_cursos where docente_id = p_docente and curso_id = p_curso;
  end if;
end $$;

-- Inscribe (o quita) a varios alumnos en un curso; en un curso de carrera solo entran alumnos de esa carrera. Devuelve cuantos cambiaron.
create or replace function inscribir_estudiantes(p_curso bigint, p_estudiantes bigint[], p_inscribir boolean) returns int
language plpgsql security definer set search_path = public as $$
declare v_inst bigint := mi_inst(); v_car bigint; n int := 0;
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  select carrera_id into v_car from cursos where id = p_curso and institucion_id = v_inst;
  if not found then raise exception 'Curso no encontrado.'; end if;
  if p_inscribir then
    insert into inscripciones (estudiante_id, curso_id)
      select e.id, p_curso from estudiantes e
      where e.id = any (p_estudiantes) and e.institucion_id = v_inst and (v_car is null or e.carrera_id = v_car)
      on conflict do nothing;
  else
    delete from inscripciones where curso_id = p_curso and estudiante_id = any (p_estudiantes)
      and estudiante_id in (select id from estudiantes where institucion_id = v_inst);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- Inscribe (o quita) a un alumno en todos los cursos de un ciclo de su carrera
create or replace function inscribir_ciclo(p_estudiante bigint, p_ciclo int, p_inscribir boolean default true) returns int
language plpgsql security definer set search_path = public as $$
declare v_inst bigint := mi_inst(); v_car bigint; n int := 0;
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  select carrera_id into v_car from estudiantes where id = p_estudiante and institucion_id = v_inst;
  if not found then raise exception 'Estudiante no encontrado.'; end if;
  if v_car is null then raise exception 'El alumno no tiene carrera asignada.'; end if;
  if p_inscribir then
    insert into inscripciones (estudiante_id, curso_id)
      select p_estudiante, c.id from cursos c where c.institucion_id = v_inst and c.carrera_id = v_car and c.ciclo = p_ciclo
      on conflict do nothing;
  else
    delete from inscripciones where estudiante_id = p_estudiante
      and curso_id in (select id from cursos where institucion_id = v_inst and carrera_id = v_car and ciclo = p_ciclo);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- Cambia la carrera de un alumno (se quitan sus inscripciones a cursos de otras carreras)
drop function if exists cambiar_carrera_estudiante(bigint, bigint);
create or replace function cambiar_carrera_estudiante(p_est bigint, p_carrera bigint, p_ciclo int default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_ciclos int; v_ciclo int;
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  if not exists (select 1 from estudiantes where id = p_est and institucion_id = mi_inst()) then raise exception 'Estudiante no encontrado.'; end if;
  select ciclos into v_ciclos from carreras where id = p_carrera and institucion_id = mi_inst();
  if not found then raise exception 'Carrera invalida.'; end if;
  if p_ciclo is not null and (p_ciclo < 1 or p_ciclo > v_ciclos) then raise exception 'Esa carrera solo tiene % ciclos.', v_ciclos; end if;
  v_ciclo := least(coalesce(p_ciclo, (select ciclo from estudiantes where id = p_est)), v_ciclos);
  update estudiantes set carrera_id = p_carrera, ciclo = v_ciclo where id = p_est;
  delete from inscripciones where estudiante_id = p_est
    and curso_id in (select id from cursos where carrera_id is not null and carrera_id <> p_carrera);
  perform _autoinscribir_estudiante(p_est);   -- se suma a los cursos de su ciclo (las inscripciones anteriores se conservan)
end $$;

-- ---------------------------------------------------------------------------
-- 10. Primera cuenta: el dueno (se ejecuta una vez, a mano, con TU usuario y TU codigo secreto)
-- ---------------------------------------------------------------------------
-- Cada administrador conecta la cuenta de Google de su institucion (desde la pantalla «Correo»); el dueno puede indicar p_inst
create or replace function configurar_correo_institucion(p_url text, p_secreto text, p_inst bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_inst bigint;
begin
  if mi_rol() = 'dueno' then v_inst := p_inst; elsif mi_rol() = 'admin' then v_inst := mi_inst(); else raise exception 'No autorizado.'; end if;
  if v_inst is null or not exists (select 1 from instituciones where id = v_inst) then raise exception 'Institucion invalida.'; end if;
  p_url := trim(coalesce(p_url, ''));
  if p_url !~ '^https://script\.google\.com/(a/macros/[^/]+/|macros/)s/[A-Za-z0-9_-]+/exec$' then
    raise exception 'La URL debe ser la de tu aplicacion web de Apps Script y terminar en /exec.';
  end if;
  if length(coalesce(p_secreto, '')) < 12 or length(p_secreto) > 100 then raise exception 'La clave secreta debe tener entre 12 y 100 caracteres.'; end if;
  insert into instituciones_correo (institucion_id, url, secreto) values (v_inst, p_url, p_secreto)
    on conflict (institucion_id) do update set url = excluded.url, secreto = excluded.secreto;
end $$;

create or replace function quitar_correo_institucion(p_inst bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_inst bigint;
begin
  if mi_rol() = 'dueno' then v_inst := p_inst; elsif mi_rol() = 'admin' then v_inst := mi_inst(); else raise exception 'No autorizado.'; end if;
  delete from instituciones_correo where institucion_id = v_inst;
  update instituciones set google_workspace = false where id = v_inst;
end $$;

-- Activa/desactiva la creacion automatica de cuentas reales de Google Workspace (requiere dominio y la conexion propia de la institucion)
create or replace function actualizar_cuentas_google(p_activo boolean, p_inst bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_inst bigint;
begin
  if mi_rol() = 'dueno' then v_inst := p_inst; elsif mi_rol() = 'admin' then v_inst := mi_inst(); else raise exception 'No autorizado.'; end if;
  if p_activo and not exists (select 1 from instituciones where id = v_inst and dominio is not null) then
    raise exception 'Primero define el dominio de correo de la institucion.';
  end if;
  if p_activo and not exists (select 1 from instituciones_correo where institucion_id = v_inst) then
    raise exception 'Primero conecta la cuenta de Google de la institucion (administradora de Google Workspace).';
  end if;
  update instituciones set google_workspace = coalesce(p_activo, false) where id = v_inst;
  if not found then raise exception 'Institucion no encontrada.'; end if;
end $$;

-- Manda un correo de prueba a p_correo con la conexion de la institucion del administrador
create or replace function probar_correo(p_correo text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_dom text;
begin
  if mi_rol() is distinct from 'admin' then raise exception 'No autorizado.'; end if;
  p_correo := lower(trim(coalesce(p_correo, '')));
  if p_correo !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Correo invalido.'; end if;
  select dominio into v_dom from instituciones where id = mi_inst();
  return _enviar_credenciales(p_correo, 'Prueba de envio', case when v_dom is null then null else 'usuarioprueba@' || v_dom end, 'usuarioprueba', 'PRUEBA-0000', mi_inst(), 'alumno');
end $$;

-- Conecta el envio de correos (se ejecuta una sola vez, a mano, desde el SQL Editor):
--   select configurar_correo('https://script.google.com/macros/s/XXXX/exec', 'el-secreto-del-script');
create or replace function configurar_correo(p_url text, p_secreto text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_url, '') !~ '^https://script\.google\.com/' then raise exception 'La URL debe ser la de tu Apps Script (https://script.google.com/...).'; end if;
  if length(coalesce(p_secreto, '')) < 12 then raise exception 'El secreto debe tener al menos 12 caracteres.'; end if;
  insert into config (clave, valor) values ('correo_url', trim(p_url)) on conflict (clave) do update set valor = excluded.valor;
  insert into config (clave, valor) values ('correo_secreto', p_secreto) on conflict (clave) do update set valor = excluded.valor;
end $$;

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
-- Universidades que ya existian: carreras precargadas y acceso conservado (inscripciones y cursos de los docentes que ya tenian alumnos)
do $$ declare i record; begin
  for i in select id from instituciones where tipo = 'universidad' loop perform _sembrar_carreras(i.id); perform _migrar_a_cursos(i.id); end loop;
end $$;

-- Alumnos y cursos que ya existian: se inscribe automaticamente una sola vez (el marcador evita rehacerlo si se vuelve a ejecutar este script)
do $$ declare r record; begin
  if not exists (select 1 from config where clave = 'autoinscripcion_v1') then
    for r in select e.id from estudiantes e where _por_curso(e.institucion_id) loop perform _autoinscribir_estudiante(r.id); end loop;
    insert into config (clave, valor) values ('autoinscripcion_v1', '1');
  end if;
end $$;

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
             'eliminar_estudiante', 'agregar_nota', 'actualizar_nota', 'eliminar_nota',
             'cambiar_tipo_institucion', 'eliminar_institucion', 'crear_invitaciones_masivo', 'actualizar_dominio', 'configurar_correo_institucion', 'quitar_correo_institucion', 'probar_correo', 'actualizar_cuentas_google',
             'crear_carrera', 'editar_carrera', 'eliminar_carrera', 'asignar_curso_docente', 'inscribir_estudiantes', 'inscribir_ciclo', 'cambiar_carrera_estudiante', 'poner_mantenimiento', 'crear_curso', 'renombrar_curso', 'eliminar_curso',
             'crear_periodo', 'renombrar_periodo', 'eliminar_periodo', 'actualizar_mi_perfil', 'actualizar_mi_foto'])
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- Internas: solo las usan otras funciones
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array[
             '_generar_usuario', '_crear_invitacion', '_puede_resolver_solicitud', '_puede_invitacion', '_puedo_gestionar', '_alcance_perfil', 'crear_invitacion_dueno',
             '_sembrar_institucion', '_asegurar_ciclos', '_puede_cursos', '_guardar_comentario', '_enviar_credenciales', 'configurar_correo', '_sembrar_carreras', '_migrar_a_cursos', '_ciclos_defecto', '_puedo_calificar', '_autoinscribir_estudiante', '_autoinscribir_curso'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
-- Quedan abiertas a todos: buscar_instituciones, solicitar_afiliacion, verificar_activacion, estado_sistema (y las funciones de apoyo de las politicas)
