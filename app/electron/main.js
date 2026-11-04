// Programa de PC: abre la web del sistema en una ventana propia (mismas cuentas, mismos datos).
// Antes de entrar busca una versión nueva del programa; si la hay, la descarga, se instala sola y se vuelve a abrir.
const { app, BrowserWindow, Menu, shell } = require("electron");
const { autoUpdater } = require("electron-updater");
const path = require("path");

const URL_APP = "https://bell786u-ctrl.github.io/sistema_estudiantil/";
const ORIGEN = new URL(URL_APP).origin;

if (!app.requestSingleInstanceLock()) app.quit();

let win;
function estado(texto, pct) {
  if (win && !win.isDestroyed()) win.webContents.executeJavaScript(`window.estado && window.estado(${JSON.stringify(texto)}, ${pct})`).catch(() => {});
}

// Resuelve "instalando" (se reiniciará con la versión nueva) o cualquier otra cosa para seguir y abrir la web
function buscarActualizacion() {
  return new Promise(resolve => {
    if (!app.isPackaged) return resolve("desarrollo");
    let fin = false; const salir = r => { if (!fin) { fin = true; resolve(r); } };
    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = false;
    autoUpdater.logger = null;
    const espera = setTimeout(() => salir("tiempo"), 6000);   // sin respuesta: se sigue (solo vale hasta que empieza la descarga)
    autoUpdater.on("update-available", info => { clearTimeout(espera); estado("Descargando la versión " + info.version + "…", 0); });
    autoUpdater.on("download-progress", p => estado("Descargando la actualización…", Math.round(p.percent)));
    autoUpdater.on("update-downloaded", () => {
      estado("Instalando la actualización…", 100);
      setTimeout(() => autoUpdater.quitAndInstall(true, true), 800);   // silencioso y vuelve a abrir el programa
      salir("instalando");
    });
    autoUpdater.on("update-not-available", () => { clearTimeout(espera); salir("al-dia"); });
    autoUpdater.on("error", () => { clearTimeout(espera); salir("error"); });
    autoUpdater.checkForUpdates().catch(() => { clearTimeout(espera); salir("error"); });
  });
}

async function crear() {
  Menu.setApplicationMenu(null);
  // Abre ya las conexiones al sistema y a la base de datos mientras se busca la actualización
  try { const s = require("electron").session.defaultSession; s.preconnect({ url: ORIGEN, numSockets: 2 }); s.preconnect({ url: "https://tikpnokwqkofitguvpdx.supabase.co", numSockets: 4 }); } catch {}
  win = new BrowserWindow({
    width: 1280, height: 800, minWidth: 900, minHeight: 600,
    title: "Estudiantil", icon: path.join(__dirname, "icon.png"), backgroundColor: "#0f1420", autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true, spellcheck: false },
  });
  // La web reconoce esta marca (y la versión instalada) para no ofrecer la descarga dentro del programa
  // y para exigir la actualización cuando haya una versión nueva que este programa no pudo instalar solo
  win.webContents.setUserAgent(win.webContents.getUserAgent() + " EstudiantilApp/" + app.getVersion());
  // Todo lo que no sea el sistema se abre en el navegador
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: "deny" }; });
  win.webContents.on("will-navigate", (e, url) => {
    if (!url.startsWith(ORIGEN) && !url.startsWith("file://")) { e.preventDefault(); shell.openExternal(url); }
  });
  // Sin internet: pantalla local con botón para reintentar
  win.webContents.on("did-fail-load", (_e, codigo, _desc, url, principal) => {
    if (principal && codigo !== -3 && url.startsWith("http")) win.loadFile(path.join(__dirname, "offline.html"));
  });
  await win.loadFile(path.join(__dirname, "actualizando.html"));
  if ((await buscarActualizacion()) === "instalando") return;
  win.loadURL(URL_APP);
}

app.on("second-instance", () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(crear);
app.on("window-all-closed", () => app.quit());
