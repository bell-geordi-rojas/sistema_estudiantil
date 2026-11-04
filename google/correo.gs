/**
 * Envío de credenciales por Gmail para el sistema Estudiantil.
 *
 * La base de datos (Supabase) llama a esta aplicación web cada vez que se crea una cuenta con correo personal.
 * Los correos salen desde la cuenta de Google con la que publiques este script.
 *
 * Instalación (una sola vez), ver README.md:
 *   1. script.google.com > Nuevo proyecto > pega este archivo.
 *   2. Configuración del proyecto (engranaje) > Propiedades de la secuencia de comandos > agrega  SECRETO = una clave larga y privada.
 *   3. Implementar > Nueva implementación > Aplicación web > Ejecutar como: Yo > Quién tiene acceso: Cualquier persona > Implementar (autoriza el envío de correos).
 *   4. Copia la URL que termina en /exec y ejecútala en el SQL Editor de Supabase:
 *        select configurar_correo('URL-COPIADA', 'LA-MISMA-CLAVE-DE-SECRETO');
 */

function doPost(e) {
  try {
    const d = JSON.parse(e.postData.contents);
    const secreto = PropertiesService.getScriptProperties().getProperty("SECRETO");
    if (!secreto || d.secreto !== secreto) return respuesta("no autorizado");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(d.para || "")) return respuesta("correo invalido");

    const inst = limpiar(d.institucion) || "tu institución";
    const rol = { alumno: "estudiante", docente: "docente", admin: "administrador" }[d.rol] || "usuario";
    const acceso = limpiar(d.correo_institucional) || limpiar(d.usuario);
    const app = /^https:\/\//.test(d.app || "") ? d.app : "";

    const html =
      '<div style="font-family:Segoe UI,Arial,sans-serif;max-width:520px;margin:auto;color:#1f2937">' +
      '<h2 style="color:#0e9aa7;margin-bottom:4px">Estudiantil</h2>' +
      '<p>Hola <b>' + limpiar(d.nombre) + '</b>,</p>' +
      '<p>' + inst + ' creó tu cuenta de <b>' + rol + '</b>. Estas son tus credenciales de acceso:</p>' +
      '<table style="border-collapse:collapse;margin:12px 0">' +
      fila("Usuario", acceso) +
      fila("Código de activación", '<span style="font-size:20px;font-weight:700;letter-spacing:2px">' + limpiar(d.codigo) + '</span>') +
      '</table>' +
      '<ol style="line-height:1.7"><li>Abre el sistema' + (app ? ' (<a href="' + app + '">' + app + '</a>)' : '') + ' o la app.</li>' +
      '<li>Entra en <b>Activar cuenta</b>.</li>' +
      '<li>Escribe tu usuario (' + limpiar(d.usuario) + ') y el código, y elige tu contraseña.</li></ol>' +
      '<p style="color:#6b7280;font-size:13px">El código es de un solo uso. Si no esperabas este mensaje, ignóralo.</p></div>';

    const texto = "Hola " + d.nombre + ",\n" + inst + " creó tu cuenta de " + rol + ".\n\nUsuario: " + acceso +
      "\nCódigo de activación: " + d.codigo + "\n\nEntra en 'Activar cuenta' " + (app ? "en " + app + " " : "") +
      "con tu usuario (" + d.usuario + ") y el código, y elige tu contraseña. El código es de un solo uso.";

    MailApp.sendEmail({ to: d.para, subject: "Tus credenciales de acceso - " + inst, body: texto, htmlBody: html, name: "Estudiantil" });
    return respuesta("ok");
  } catch (err) {
    return respuesta("error: " + err);
  }
}

// Respuesta de prueba al abrir la URL en el navegador
function doGet() { return respuesta("Estudiantil: servicio de correo activo"); }

function respuesta(texto) { return ContentService.createTextOutput(texto); }
function fila(k, v) { return '<tr><td style="padding:6px 14px 6px 0;color:#6b7280">' + k + '</td><td style="padding:6px 0">' + v + '</td></tr>'; }
// Evita que un nombre o dato con símbolos HTML altere el mensaje
function limpiar(t) { return String(t == null ? "" : t).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
