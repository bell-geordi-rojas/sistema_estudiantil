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
- **Colegio o universidad:** el dueño elige el tipo al crear la institución. Los colegios trabajan por **trimestres**; las universidades por **ciclos** y pueden dar un **peso** (1–4) a cada nota; el promedio del curso es ponderado (`Σ nota × peso / Σ peso`) y sin peso elegido vale 1.
- **Trimestres / ciclos:** las notas se registran dentro de un periodo y se pueden filtrar por periodo. En los colegios el administrador agrega, renombra o quita trimestres; las universidades tienen **14 ciclos fijos** (Ciclo I a Ciclo XIV).
- **Cursos propios:** los colegios empiezan con 7 cursos y el administrador (o un docente con el permiso «gestionar_cursos») puede agregar, renombrar o quitar cursos. Las universidades empiezan sin cursos.
- **Dueño:** puede **eliminar instituciones** (pide escribir su nombre; borra cuentas, estudiantes y notas) y **pausar todo el sistema** por mantenimiento (solo el dueño puede entrar mientras tanto).
- **Mi cuenta:** cualquier cuenta puede subir su foto de perfil (se reduce a 192×192) y cambiar su nombre; si es alumno, también se actualiza en la lista de estudiantes.
- **Efectos visuales:** fundido con desenfoque entre pantallas (crossfade), la ventana de un curso o de la foto de perfil crece desde su tarjeta (elemento compartido), zoom al pasar el cursor (magnificación: tarjetas, botones, menú y avatares; la foto de perfil se amplía al tocarla) y fondo desenfocado (blur) en ventanas, menús y encabezado. Se pueden apagar en «Mi cuenta → Apariencia».
- **Rendimiento:** al iniciar sesión los datos se piden todos a la vez (un solo viaje de red), la sesión se renueva una sola vez aunque haya varias peticiones, las fotos se cargan después de pintar la pantalla y las transiciones son cortas: al abrir un curso su contenido aparece al instante y solo el banner se anima.
- **Cursos en tarjetas:** la sección «Cursos» / «Mis cursos» muestra cada curso como una tarjeta con banner de colores, promedio, favoritos (★) y menú ⋮; al abrirla el alumno ve sus notas y el personal ve a sus estudiantes.
- **Nombre y comentario de cada nota:** al agregar una nota se puede poner un nombre (examen, trabajo…) y un comentario. El alumno los ve en «Mis comentarios»; los comentarios solo los ven el personal de su institución y el propio alumno.
- **CSV:** una fila por nota: `codigo,nombre,periodo,curso,nota,peso,titulo,comentario`.

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `index.html` | La web (GitHub Pages). |
| `supabase.sql` | Crea todo en Supabase (tablas, seguridad, funciones). Se puede ejecutar más de una vez. |
| `api.php`, `sistema_estudiantes.cpp` | Versión local antigua (XAMPP/consola) de una sola institución, sin cuentas. Ya no se usa con la web. |

## Programas para PC y Android

Dentro de la web, en **Descargar sistema** (o en la pestaña «Descargar» del login) hay un instalador para Windows (`Estudiantil-Setup.exe`) y un APK para Android (`Estudiantil.apk`).
Son ventanas que abren la web publicada (mismas cuentas, mismos datos y siempre la última versión), con el logo de Master's Corporation. Necesitan internet.
Los compila GitHub Actions (`.github/workflows/build-apps.yml`, código en `app/`) y los publica en la versión **app-latest**; se recompilan al cambiar `app/` o a mano en *Actions → Compilar programas → Run workflow*.
El instalador de Windows no tiene firma digital (SmartScreen avisa) y el APK está firmado con clave de depuración (hay que permitir «instalar apps desconocidas»).

### Correo institucional y envío de credenciales por Gmail

- Cada institución puede tener un **dominio de correo** (p. ej. `midominio.edu`; lo define el dueño en «Instituciones» o el administrador en su pantalla de cursos). Con él, el usuario de una cuenta nueva se genera con el patrón institucional: inicial del 1.er apellido + 2.º apellido + inicial del nombre. «Juan Carlos Pérez Gómez» → `pgomezj@midominio.edu`. Si ya existe se agrega un número. Se puede entrar escribiendo `pgomezj` o el correo completo.
  > Es el *usuario dentro de este sistema* con formato de correo institucional: no crea un buzón real en Google Workspace (eso solo lo hace el área de TI de la universidad).
- **Registrar varios a la vez:** en «Registrar estudiante → Varios a la vez» se pega una persona por línea (`nombre completo, correo personal`), se revisa la lista y se crean todas; las credenciales se envían a cada correo personal y se puede descargar un CSV de respaldo.
- **Los correos salen desde la cuenta de Google de cada institución** (la del director o la institucional), no desde la del dueño. Cada administrador lo conecta una sola vez en **Correo institucional → Envío de credenciales por Gmail**: copia el código, lo pega en <https://script.google.com> con esa cuenta, publica la aplicación web, y pega aquí la URL y la clave. El botón «Enviar correo de prueba» comprueba la conexión. El código del script está en [`google/correo.gs`](google/correo.gs) (y embebido en la web).
  La base de datos llama a ese script con `pg_net`; la URL y la clave se guardan en una tabla cerrada y nunca llegan al navegador.
  Si una institución no conecta su cuenta, se usa —si existe— la conexión general del dueño (`select configurar_correo('URL', 'CLAVE');`); para desactivarla: `delete from config where clave in ('correo_url', 'correo_secreto');`.
  Límite de Gmail: unos 100 correos por día en cuentas personales (1500 en Google Workspace, lo habitual en un colegio o universidad); los que excedan no se envían, pero las cuentas se crean y salen en el CSV.
- **Cuentas reales de Google Workspace (opcional).** Las cuentas que crea el sistema (`usuario@dominio`) son *internas*: sirven para entrar aquí, no son buzones de Google. Si la institución tiene **Google Workspace** con su propio dominio, en **Correo institucional → Cuentas reales de Google Workspace** se puede activar que, al registrar a alguien, el mismo script cree también su cuenta real (`AdminDirectory.Users.insert`) con una contraseña temporal aleatoria que Google obliga a cambiar. Requisitos: Workspace con el dominio, script publicado por una cuenta **administradora de Workspace**, servicio *Admin SDK API* agregado en el editor del script y acceso a API permitido en admin.google.com. Solo se crean cuentas del dominio de la cuenta que publicó el script; si algo falla, ese administrador recibe un correo con el motivo. No se pueden crear cuentas `@gmail.com` ni de dominios que la institución no administre.
### Publicar una versión nueva (actualización obligatoria)

1. Sube el número de `version.json` (p. ej. `1.1.0` → `1.2.0`) y haz commit/push (también se puede ejecutar a mano en *Actions → Compilar programas*).
2. El workflow compila el instalador y el APK con esa versión, los publica en **app-latest** y al final actualiza `actualizacion.json`.
3. Los programas instalados se actualizan solos: **PC** descarga e instala la versión nueva al abrirse (electron-updater, con `latest.yml`) y se reabre sola; **Android** descarga el APK y abre el instalador del sistema (el usuario solo pulsa «Actualizar»; la primera vez debe permitir «instalar apps desconocidas» a Estudiantil). Si una actualización no se pudo hacer, la web muestra «Actualización obligatoria» en vez del login.Los cambios solo de la web (`index.html`) no necesitan versión nueva: los programas ya cargan siempre la web publicada.
El APK se firma con una clave permanente guardada en los *secrets* de GitHub (`ANDROID_KEYSTORE_B64` y `ANDROID_KEYSTORE_PASS`); hay copia en `Documents\EstudiantilKeystore`. Si se pierde, los usuarios tendrán que desinstalar la app para actualizar.

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
