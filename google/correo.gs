/**
 * Envío de credenciales por Gmail (y creación opcional de cuentas de Google Workspace) para el sistema Estudiantil.
 *
 * La base de datos (Supabase) llama a esta aplicación web cada vez que se registra a alguien. El correo sale desde la
 * cuenta de Google que publica este script (la del director o la institucional).
 *
 * Si la institución usa Google Workspace y activa «Crear también la cuenta de Google», este mismo script crea la cuenta
 * REAL (usuario@dominio) con una contraseña temporal. Para eso la cuenta que lo publica debe ser administradora de
 * Workspace (con permiso para administrar usuarios) y debes activar el servicio «Admin SDK API» (ver README).
 *
 * Instalación (una sola vez):
 *   1. script.google.com > Nuevo proyecto > pega este archivo.
 *   2. Configuración del proyecto > Propiedades de la secuencia de comandos > agrega  SECRETO = una clave larga y privada.
 *   3. (Solo para crear cuentas de Workspace) Servicios (+) > «Admin SDK API» > Agregar.
 *   4. Implementar > Nueva implementación > Aplicación web > Ejecutar como: Yo > Acceso: Cualquier persona.
 *      Si cambias el código más adelante: Implementar > Administrar implementaciones > editar > Nueva versión.
 *   5. Pega la URL (termina en /exec) y la clave en la pantalla «Correo institucional» del sistema.
 */

function doPost(e) {
  try {
    const d = JSON.parse(e.postData.contents);
    const secreto = PropertiesService.getScriptProperties().getProperty("SECRETO");
    if (!secreto || d.secreto !== secreto) return respuesta("no autorizado");

    // 1) Cuenta real de Google Workspace (opcional)
    const cuenta = d.crear_google ? crearCuentaGoogle(d) : null;

    // 2) Correo con las credenciales (si hay correo personal)
    if (!d.para) return respuesta(cuenta && cuenta.ok ? "cuenta creada" : "sin destinatario");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(d.para)) return respuesta("correo invalido");

    const inst = limpiar(d.institucion) || "tu institución";
    const rol = { alumno: "estudiante", docente: "docente", admin: "administrador" }[d.rol] || "usuario";
    const acceso = limpiar(d.correo_institucional) || limpiar(d.usuario);
    const app = /^https:\/\//.test(d.app || "") ? d.app : "";

    let filas = fila("Usuario", acceso) +
      fila("Código de activación", '<span style="font-size:20px;font-weight:700;letter-spacing:2px">' + limpiar(d.codigo) + '</span>');
    let aviso = "";
    let textoGoogle = "";
    if (cuenta && cuenta.ok) {
      filas += fila("Cuenta de Google", limpiar(cuenta.correo)) +
        fila("Contraseña temporal de Google", '<span style="font-size:18px;font-weight:700;letter-spacing:1px">' + limpiar(d.clave_google) + '</span>');
      aviso = '<p style="background:#fef3c7;padding:10px;border-radius:6px;font-size:14px">Tu cuenta de Google institucional ya existe: entra en <a href="https://mail.google.com">mail.google.com</a> con ese correo y la contraseña temporal. Google te pedirá cambiarla.</p>';
      textoGoogle = "\nCuenta de Google: " + cuenta.correo + "\nContraseña temporal de Google: " + d.clave_google + " (Google te pedirá cambiarla)";
    }

    const html =
      '<div style="font-family:Segoe UI,Arial,sans-serif;max-width:520px;margin:auto;color:#1f2937">' +
      '<h2 style="color:#0e9aa7;margin-bottom:4px">Estudiantil</h2>' +
      '<p>Hola <b>' + limpiar(d.nombre) + '</b>,</p>' +
      '<p>' + inst + ' creó tu cuenta de <b>' + rol + '</b>. Estas son tus credenciales de acceso:</p>' +
      '<table style="border-collapse:collapse;margin:12px 0">' + filas + '</table>' + aviso +
      '<ol style="line-height:1.7"><li>Abre el sistema' + (app ? ' (<a href="' + app + '">' + app + '</a>)' : '') + ' o la app.</li>' +
      '<li>Entra en <b>Activar cuenta</b>.</li>' +
      '<li>Escribe tu usuario (' + limpiar(d.usuario) + ') y el código, y elige tu contraseña.</li></ol>' +
      '<p style="color:#6b7280;font-size:13px">El código es de un solo uso. Si no esperabas este mensaje, ignóralo.</p></div>';

    const texto = "Hola " + d.nombre + ",\n" + inst + " creó tu cuenta de " + rol + ".\n\nUsuario: " + (d.correo_institucional || d.usuario) +
      "\nCódigo de activación: " + d.codigo + textoGoogle + "\n\nEntra en 'Activar cuenta' " + (app ? "en " + app + " " : "") +
      "con tu usuario (" + d.usuario + ") y el código, y elige tu contraseña. El código es de un solo uso.";

    MailApp.sendEmail({ to: d.para, subject: "Tus credenciales de acceso - " + inst, body: texto, htmlBody: html, name: "Estudiantil" });
    return respuesta("ok");
  } catch (err) {
    return respuesta("error: " + err);
  }
}

/** Crea la cuenta de Google Workspace usuario@dominio con contraseña temporal. Nunca lanza: avisa al director si falla. */
function crearCuentaGoogle(d) {
  const correo = String(d.correo_institucional || "").toLowerCase();
  try {
    const yo = Session.getEffectiveUser().getEmail().toLowerCase();
    const dominio = yo.split("@")[1];
    if (!/^[a-z0-9._'-]+@[a-z0-9.-]+\.[a-z]{2,}$/.test(correo)) throw new Error("correo institucional no válido: " + correo);
    // Solo se crean cuentas del dominio de la cuenta que publicó el script (evita usos indebidos)
    if (correo.split("@")[1] !== dominio) throw new Error("el dominio de " + correo + " no coincide con el de la cuenta que publicó el script (" + dominio + ")");
    if (String(d.clave_google || "").length < 8) throw new Error("falta la contraseña temporal");
    const nombres = String(d.nombres || d.nombre || "").trim() || "Usuario";
    const apellidos = String(d.apellidos || "").trim() || "-";
    try {
      AdminDirectory.Users.insert({
        primaryEmail: correo,
        name: { givenName: nombres, familyName: apellidos },
        password: d.clave_google,
        changePasswordAtNextLogin: true
      });
    } catch (err) {
      if (/already exists/i.test(String(err))) { avisarAlDirector("La cuenta " + correo + " ya existía", "No se creó otra. Si es una persona distinta, regístrala con otro usuario."); return { ok: false, existe: true, correo: correo }; }
      throw err;
    }
    return { ok: true, correo: correo };
  } catch (err) {
    avisarAlDirector("No se pudo crear la cuenta de Google " + correo,
      String(err) + "\n\nComprueba que: (1) este script lo publicó una cuenta administradora de Google Workspace, (2) agregaste el servicio «Admin SDK API» en el editor de Apps Script, " +
      "y (3) el acceso a la API está permitido en la consola de administración (Seguridad > Controles de API).");
    return { ok: false, error: String(err), correo: correo };
  }
}

function avisarAlDirector(asunto, detalle) {
  try { MailApp.sendEmail(Session.getEffectiveUser().getEmail(), "[Estudiantil] " + asunto, detalle); } catch (e) {}
}

// Respuesta de prueba al abrir la URL en el navegador
function doGet() { return respuesta("Estudiantil: servicio de correo activo"); }

function respuesta(texto) { return ContentService.createTextOutput(texto); }
function fila(k, v) { return '<tr><td style="padding:6px 14px 6px 0;color:#6b7280">' + k + '</td><td style="padding:6px 0">' + v + '</td></tr>'; }
// Evita que un nombre o dato con símbolos HTML altere el mensaje
function limpiar(t) { return String(t == null ? "" : t).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
