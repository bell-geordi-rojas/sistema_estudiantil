package com.masters.estudiantil;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.core.content.FileProvider;

import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/** Descarga la actualización (APK) y abre el instalador de Android para instalarla encima de la versión actual. */
@CapacitorPlugin(name = "Instalador")
public class InstaladorPlugin extends Plugin {

    @PluginMethod
    public void instalar(final PluginCall call) {
        final String url = call.getString("url");
        if (url == null || !url.startsWith("https://github.com/bell-geordi-rojas/sistema_estudiantil/")) {
            call.reject("Dirección de descarga no válida.");
            return;
        }
        final Context ctx = getContext();
        // Android exige que el usuario permita a esta app instalar otras apps (una sola vez)
        if (Build.VERSION.SDK_INT >= 26 && !ctx.getPackageManager().canRequestPackageInstalls()) {
            Intent ajustes = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + ctx.getPackageName()));
            ajustes.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(ajustes);
            call.reject("permiso");
            return;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    File apk = new File(ctx.getCacheDir(), "actualizacion.apk");
                    HttpURLConnection con = (HttpURLConnection) new URL(url).openConnection();
                    con.setConnectTimeout(15000);
                    con.setReadTimeout(30000);
                    if (con.getResponseCode() != 200) throw new Exception("El servidor respondió " + con.getResponseCode());
                    InputStream in = con.getInputStream();
                    FileOutputStream out = new FileOutputStream(apk);
                    byte[] buf = new byte[65536];
                    int n;
                    while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
                    out.close();
                    in.close();
                    Uri uri = FileProvider.getUriForFile(ctx, ctx.getPackageName() + ".fileprovider", apk);
                    Intent i = new Intent(Intent.ACTION_VIEW);
                    i.setDataAndType(uri, "application/vnd.android.package-archive");
                    i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
                    ctx.startActivity(i);
                    call.resolve();
                } catch (Exception e) {
                    call.reject(e.getMessage() == null ? "No se pudo descargar la actualización." : e.getMessage());
                }
            }
        }).start();
    }
}
