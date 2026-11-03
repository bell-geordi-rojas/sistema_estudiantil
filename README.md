# Sistema Estudiantil

Gestión de estudiantes con notas por curso (escala 0–20, aprobado desde 11) para varias instituciones afiliadas.
Cursos: Matemática, Ciencia y Tecnología, Ciencias Sociales, Desarrollo Personal, Ciudadanía y Cívica, Comunicación, Arte e Inglés.

## Cómo funciona

- **Login** con usuario y contraseña, **activación de cuenta** con un código que entrega la institución, y **afiliación**: la persona busca su institución y deja sus nombres; el administrador aprueba y le da usuario + código.
- **Roles:** `dueño` → `admin` (director de una institución) → `docente` → `alumno`.
- **Permisos:** cada cuenta tiene permisos que el nivel superior puede dar o quitar (registrar, editar notas, eliminar, exportar, estadísticas, ver compañeros…). Un alumno por defecto solo ve sus propias notas y a sus compañeros.
- **Aislamiento:** cada cuenta ve solo su institución; un docente solo sus alumnos; un alumno solo a los compañeros del mismo docente. Lo aplica la base de datos (Row Level Security), no solo la página.
- **Carpetas:** `Admin / <Institución> / Docentes / <docente> / Alumnos / <alumno>` (vista `carpetas` en la base y panel «Carpetas» del dueño).
- **Modo claro / oscuro** y edición de datos y notas de los estudiantes.

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `index.html` | La web (GitHub Pages). |
| `supabase.sql` | Crea todo en Supabase (tablas, seguridad, funciones). Se puede ejecutar más de una vez. |
| `api.php`, `sistema_estudiantes.cpp` | Versión local antigua (XAMPP/consola) de una sola institución, sin cuentas. Ya no se usa con la web. |

## Puesta en marcha (una sola vez)

1. En Supabase: **Authentication → Sign In / Providers → Email → desactivar «Confirm email»** (las cuentas usan un correo interno).
2. **SQL Editor** → pegar `supabase.sql` completo → **Run**. Los datos anteriores quedan en las tablas `estudiantes_v1` y `notas_v1`.
3. Crear la cuenta del dueño (elige tu usuario y tu código secreto, mínimo 8 caracteres):
   ```sql
   select crear_invitacion_dueno('tuusuario', 'Tu Nombre', 'TuCodigoSecreto');
   ```
4. En la web: **Activar cuenta** → tu usuario, ese código y la contraseña que quieras.
5. Como dueño: **Instituciones** → crear la institución → **+ Administrador** → entregar usuario y código al director.

> La clave `sb_publishable_…` de `index.html` es pública por diseño; no da acceso a nada sin una cuenta.
