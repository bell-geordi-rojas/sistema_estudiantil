// Programa de PC: abre la web del sistema en una ventana propia (mismas cuentas, mismos datos).
const { app, BrowserWindow, Menu, shell } = require("electron");
const path = require("path");

const URL_APP = "https://bell786u-ctrl.github.io/sistema_estudiantil/";
const ORIGEN = new URL(URL_APP).origin;

if (!app.requestSingleInstanceLock()) app.quit();

let win;
function crear() {
  Menu.setApplicationMenu(null);
  win = new BrowserWindow({
    width: 1280, height: 800, minWidth: 900, minHeight: 600,
    title: "Estudiantil", icon: path.join(__dirname, "icon.png"), backgroundColor: "#0f1420", autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  // La web reconoce esta marca y no ofrece descargar el programa dentro del programa
  win.webContents.setUserAgent(win.webContents.getUserAgent() + " EstudiantilApp");
  // Todo lo que no sea el sistema se abre en el navegador
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: "deny" }; });
  win.webContents.on("will-navigate", (e, url) => {
    if (!url.startsWith(ORIGEN) && !url.startsWith("file://")) { e.preventDefault(); shell.openExternal(url); }
  });
  // Sin internet: pantalla local con botón para reintentar
  win.webContents.on("did-fail-load", (_e, codigo, _desc, url, principal) => {
    if (principal && codigo !== -3 && url.startsWith("http")) win.loadFile(path.join(__dirname, "offline.html"));
  });
  win.loadURL(URL_APP);
}

app.on("second-instance", () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(crear);
app.on("window-all-closed", () => app.quit());
