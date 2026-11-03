-- Base de datos del Sistema de Gestion de Estudiantes para Supabase (Postgres).
-- Pegar completo en Supabase > SQL Editor > Run.

create table if not exists estudiantes (
  id bigint generated always as identity primary key,
  codigo text not null check (codigo ~ '^[A-Za-z0-9]{1,15}$'),
  nombre text not null check (length(nombre) between 1 and 100 and nombre !~ '[0-9|]')
);
create unique index if not exists estudiantes_codigo_unico on estudiantes (upper(codigo));

create table if not exists notas (
  id bigint generated always as identity primary key,
  estudiante_id bigint not null references estudiantes(id) on delete cascade,
  curso smallint not null check (curso between 0 and 6),  -- 0 Matematica ... 6 Ingles
  nota numeric(4,2) not null check (nota between 0 and 20)
);
create index if not exists notas_estudiante_curso on notas (estudiante_id, curso);

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

-- Registro atomico: p_notas es un arreglo con un arreglo de notas por curso, p. ej. [[15,18],[],[12],[],[],[],[]]
create or replace function registrar_estudiante(p_codigo text, p_nombre text, p_notas jsonb)
returns void language plpgsql as $$
declare v_id bigint; c int; n numeric;
begin
  if jsonb_array_length(p_notas) <> 7 then raise exception 'Formato de notas invalido.'; end if;
  insert into estudiantes (codigo, nombre) values (trim(p_codigo), trim(p_nombre)) returning id into v_id;
  for c in 0..6 loop
    for n in select jsonb_array_elements_text(p_notas -> c)::numeric loop
      insert into notas (estudiante_id, curso, nota) values (v_id, c, n);
    end loop;
  end loop;
end $$;

create or replace function agregar_nota(p_codigo text, p_curso int, p_nota numeric)
returns void language plpgsql as $$
declare v_id bigint;
begin
  select id into v_id from estudiantes where upper(codigo) = upper(trim(p_codigo));
  if v_id is null then raise exception 'No se encontro ningun estudiante con ese codigo.'; end if;
  insert into notas (estudiante_id, curso, nota) values (v_id, p_curso, p_nota);
end $$;

-- Acceso desde la pagina web (clave anon). Cualquiera que abra la web puede ver, registrar y eliminar.
alter table estudiantes enable row level security;
alter table notas enable row level security;
drop policy if exists web_estudiantes on estudiantes;
drop policy if exists web_notas on notas;
create policy web_estudiantes on estudiantes for all to anon using (true) with check (true);
create policy web_notas on notas for all to anon using (true) with check (true);
