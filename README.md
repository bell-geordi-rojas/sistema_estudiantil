# Sistema de Gestión de Estudiantes

Registro de estudiantes con notas por curso (escala 0–20, aprobado desde 11):
Matemática, Ciencia y Tecnología, Ciencias Sociales, Desarrollo Personal, Ciudadanía y Cívica, Comunicación, Arte e Inglés.

| Archivo | Para qué sirve |
|---|---|
| `index.html` | La web. Se publica con GitHub Pages. |
| `supabase.sql` | Crea las tablas en Supabase (base de datos en la nube). |
| `api.php` | Alternativa local: API PHP + MySQL (XAMPP). |
| `sistema_estudiantes.cpp` | Versión de consola; usa `api.php` (XAMPP). |

## Web (GitHub Pages + Supabase)

1. En [supabase.com](https://supabase.com) crea un proyecto y ejecuta `supabase.sql` en **SQL Editor**.
2. En `index.html` completa `SUPABASE_URL` y `SUPABASE_KEY` (clave *anon public*, en **Project Settings → API**).
3. En el repo: **Settings → Pages → Deploy from a branch → `main` / root**.

> Con la clave anon, cualquiera que abra la web puede ver, registrar y eliminar estudiantes. Es suficiente para un proyecto de práctica; para uso real habría que añadir inicio de sesión.

## Local (XAMPP)

Copia `api.php` e `index.html` a `C:\xampp\htdocs\sistema_estudiantes\`, inicia Apache y MySQL y abre `http://localhost/sistema_estudiantes/`.
Deja `SUPABASE_URL` y `SUPABASE_KEY` vacíos para que use `api.php`.

Consola: `g++ sistema_estudiantes.cpp -o sistema_estudiantes -lwininet`
