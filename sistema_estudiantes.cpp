// Sistema de gestion de estudiantes (datos en MySQL a traves de api.php)
// Compilar: g++ sistema_estudiantes.cpp -o sistema_estudiantes -lwininet
// Requiere Apache y MySQL iniciados (XAMPP) y la carpeta del proyecto en htdocs.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wininet.h>

#include <algorithm>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

using namespace std;

const char* SERVIDOR = "127.0.0.1";
const INTERNET_PORT PUERTO = 80;
const string RUTA_API = "/sistema_estudiantes/api.php";
const double NOTA_MIN = 0.0;
const double NOTA_MAX = 20.0;
const double NOTA_APROBACION = 11.0;

const int NUM_CURSOS = 7;
const string CURSOS[NUM_CURSOS] = {
    "Matematica",
    "Ciencia y Tecnologia",
    "Ciencias Sociales",
    "Desarrollo Personal, Ciudadania y Civica",
    "Comunicacion",
    "Arte",
    "Ingles"};

struct Estudiante {
    string codigo;
    string nombre;
    vector<double> notas[NUM_CURSOS];  // notas de cada curso

    static double media(const vector<double>& v) {
        if (v.empty()) return 0.0;
        double suma = 0;
        for (double n : v) suma += n;
        return suma / v.size();
    }
    size_t totalNotas() const {
        size_t t = 0;
        for (const auto& v : notas) t += v.size();
        return t;
    }
    double promedioCurso(int c) const { return media(notas[c]); }
    // Promedio general: media de los promedios de los cursos que tienen notas
    double promedio() const {
        double suma = 0;
        int cursos = 0;
        for (const auto& v : notas)
            if (!v.empty()) { suma += media(v); ++cursos; }
        return cursos ? suma / cursos : 0.0;
    }
    bool aprobado() const { return totalNotas() > 0 && promedio() >= NOTA_APROBACION; }
};

vector<Estudiante> estudiantes;

string trim(const string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

string leerLinea(const string& mensaje) {
    cout << mensaje;
    string linea;
    if (!getline(cin, linea)) {
        cout << "\nEntrada finalizada.\n";
        exit(0);
    }
    return trim(linea);
}

bool convertirDouble(const string& texto, double& valor) {
    try {
        size_t pos;
        valor = stod(texto, &pos);
        return pos == texto.size();
    } catch (...) {
        return false;
    }
}

int leerEntero(const string& mensaje, int min, int max) {
    while (true) {
        string t = leerLinea(mensaje);
        try {
            size_t pos;
            int v = stoi(t, &pos);
            if (pos == t.size() && v >= min && v <= max) return v;
        } catch (...) {}
        cout << "  Error: ingrese un numero entero entre " << min << " y " << max << ".\n";
    }
}

double leerNota(const string& mensaje) {
    while (true) {
        double v;
        if (convertirDouble(leerLinea(mensaje), v) && v >= NOTA_MIN && v <= NOTA_MAX) return v;
        cout << "  Error: la calificacion debe ser un numero entre " << NOTA_MIN << " y " << NOTA_MAX << ".\n";
    }
}

bool nombreValido(const string& n) {
    if (n.empty() || n.find('|') != string::npos) return false;
    for (unsigned char c : n)
        if (isdigit(c)) return false;
    return true;
}

bool codigoValido(const string& c) {
    if (c.empty() || c.size() > 15) return false;
    for (unsigned char ch : c)
        if (!isalnum(ch)) return false;
    return true;
}

string aMayusculas(string s) {
    transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return toupper(c); });
    return s;
}

// ---------- Busqueda ----------

Estudiante* buscarPorCodigo(const string& codigo) {
    string c = aMayusculas(codigo);
    for (auto& e : estudiantes)
        if (aMayusculas(e.codigo) == c) return &e;
    return nullptr;
}

// ---------- Servidor (api.php + MySQL) ----------

// Envia una peticion HTTP a api.php. Devuelve false si no hubo conexion.
bool http(bool post, const string& params, string& cuerpo, DWORD& estado) {
    cuerpo.clear();
    estado = 0;
    HINTERNET sesion = InternetOpenA("SistemaEstudiantes/1.0", INTERNET_OPEN_TYPE_DIRECT, nullptr, nullptr, 0);
    if (!sesion) return false;
    HINTERNET con = InternetConnectA(sesion, SERVIDOR, PUERTO, nullptr, nullptr, INTERNET_SERVICE_HTTP, 0, 0);
    HINTERNET req = nullptr;
    bool ok = false;
    if (con) {
        string ruta = post ? RUTA_API : RUTA_API + "?" + params;
        req = HttpOpenRequestA(con, post ? "POST" : "GET", ruta.c_str(), nullptr, nullptr, nullptr,
                               INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE, 0);
        if (req) {
            if (post) {
                const char* cab = "Content-Type: application/x-www-form-urlencoded";
                ok = HttpSendRequestA(req, cab, (DWORD)strlen(cab), (LPVOID)params.data(), (DWORD)params.size());
            } else {
                ok = HttpSendRequestA(req, nullptr, 0, nullptr, 0);
            }
        }
    }
    if (ok) {
        DWORD tam = sizeof(estado);
        HttpQueryInfoA(req, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &estado, &tam, nullptr);
        char buf[4096];
        DWORD n = 0;
        while (InternetReadFile(req, buf, sizeof(buf), &n) && n) cuerpo.append(buf, n);
    }
    if (req) InternetCloseHandle(req);
    if (con) InternetCloseHandle(con);
    InternetCloseHandle(sesion);
    return ok;
}

string urlCodificar(const string& s) {
    static const char* hex = "0123456789ABCDEF";
    string r;
    for (unsigned char c : s) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.') r += (char)c;
        else { r += '%'; r += hex[c >> 4]; r += hex[c & 15]; }
    }
    return r;
}

// Saca el texto de "error":"..." de la respuesta JSON de la API
string mensajeError(const string& cuerpo) {
    size_t p = cuerpo.find("\"error\":\"");
    if (p == string::npos) return "";
    p += 9;
    string r;
    for (; p < cuerpo.size() && cuerpo[p] != '"'; ++p) {
        if (cuerpo[p] == '\\' && p + 1 < cuerpo.size()) ++p;
        r += cuerpo[p];
    }
    return r;
}

void errorConexion() {
    cout << "  Error: no se pudo conectar con el servidor. Revise que Apache y MySQL esten iniciados en XAMPP.\n";
}

// Envia una accion de escritura; devuelve true si el servidor la acepto.
bool enviarAccion(const string& accion, const vector<pair<string, string>>& campos) {
    string params = "accion=" + accion, cuerpo;
    for (const auto& c : campos) params += "&" + c.first + "=" + urlCodificar(c.second);
    DWORD estado;
    if (!http(true, params, cuerpo, estado)) {
        errorConexion();
        return false;
    }
    if (estado != 200) {
        string m = mensajeError(cuerpo);
        cout << "  Error: " << (m.empty() ? "el servidor respondio con el codigo " + to_string(estado) : m) << '\n';
        return false;
    }
    return true;
}

// "n;n|n|...": un campo por curso, notas separadas por ';'
string notasATexto(const Estudiante& e) {
    ostringstream out;
    for (int c = 0; c < NUM_CURSOS; ++c) {
        if (c) out << '|';
        for (size_t i = 0; i < e.notas[c].size(); ++i) {
            if (i) out << ';';
            out << e.notas[c][i];
        }
    }
    return out.str();
}

// Lee todos los estudiantes desde la base de datos.
// Formato recibido: codigo|nombre|notas curso 1|...|notas curso N (notas separadas por ';')
bool cargar(bool mostrarMensaje) {
    string cuerpo;
    DWORD estado;
    if (!http(false, "accion=exportar", cuerpo, estado)) {
        errorConexion();
        return false;
    }
    if (estado != 200) {
        string m = mensajeError(cuerpo);
        cout << "  Error del servidor: " << (m.empty() ? "codigo " + to_string(estado) : m) << '\n';
        return false;
    }
    estudiantes.clear();
    istringstream in(cuerpo);
    string linea;
    int omitidas = 0;
    while (getline(in, linea)) {
        if (trim(linea).empty()) continue;
        vector<string> campos;
        stringstream campoSs(linea);
        string campo;
        while (getline(campoSs, campo, '|')) campos.push_back(campo);
        if (!linea.empty() && linea.back() == '|') campos.push_back("");
        if (campos.size() != 2 + NUM_CURSOS) { ++omitidas; continue; }

        Estudiante e;
        e.codigo = trim(campos[0]);
        e.nombre = trim(campos[1]);
        bool ok = codigoValido(e.codigo) && nombreValido(e.nombre) && !buscarPorCodigo(e.codigo);

        for (int c = 0; ok && c < NUM_CURSOS; ++c) {
            stringstream ss(campos[2 + c]);
            string tok;
            while (ok && getline(ss, tok, ';')) {
                tok = trim(tok);
                if (tok.empty()) continue;
                double v;
                if (!convertirDouble(tok, v) || v < NOTA_MIN || v > NOTA_MAX) ok = false;
                else e.notas[c].push_back(v);
            }
        }
        if (ok) estudiantes.push_back(e);
        else ++omitidas;
    }
    if (mostrarMensaje) cout << "Se cargaron " << estudiantes.size() << " registro(s) desde la base de datos.\n";
    if (omitidas) cout << "Aviso: " << omitidas << " registro(s) invalido(s) fueron omitidos.\n";
    return true;
}

// ---------- Presentacion ----------

void encabezadoTabla() {
    cout << left << setw(12) << "Codigo" << setw(28) << "Nombre" << setw(10) << "Notas"
         << setw(10) << "Promedio" << "Estado\n"
         << string(70, '-') << '\n';
}

void imprimirFila(const Estudiante& e) {
    cout << left << setw(12) << e.codigo << setw(28) << e.nombre.substr(0, 27) << setw(10)
         << e.totalNotas() << fixed << setprecision(2) << setw(10) << e.promedio()
         << (e.totalNotas() == 0 ? "Sin notas" : (e.aprobado() ? "Aprobado" : "Reprobado")) << '\n';
}

void imprimirLista(const vector<Estudiante>& lista) {
    if (lista.empty()) {
        cout << "  No hay estudiantes registrados.\n";
        return;
    }
    encabezadoTabla();
    for (const auto& e : lista) imprimirFila(e);
}

// ---------- Opciones del menu ----------

void registrarEstudiante() {
    cout << "\n--- Registrar estudiante ---\n";
    string codigo;
    while (true) {
        codigo = leerLinea("Codigo (letras/numeros, max. 15): ");
        if (!codigoValido(codigo)) cout << "  Error: codigo invalido.\n";
        else if (buscarPorCodigo(codigo)) cout << "  Error: ya existe un estudiante con ese codigo.\n";
        else break;
    }
    string nombre;
    while (true) {
        nombre = leerLinea("Nombre completo: ");
        if (nombreValido(nombre)) break;
        cout << "  Error: el nombre no puede estar vacio ni contener numeros o '|'.\n";
    }
    Estudiante e;
    e.codigo = codigo;
    e.nombre = nombre;

    for (int c = 0; c < NUM_CURSOS; ++c) {
        int n = leerEntero("Cuantas notas para " + CURSOS[c] + " (0-20): ", 0, 20);
        for (int i = 1; i <= n; ++i)
            e.notas[c].push_back(leerNota("  " + CURSOS[c] + " - nota " + to_string(i) + ": "));
    }

    if (enviarAccion("registrar", {{"codigo", e.codigo}, {"nombre", e.nombre}, {"notas", notasATexto(e)}})) {
        cargar(false);
        cout << "Estudiante registrado y guardado.\n";
    }
}

void agregarCalificacion() {
    cout << "\n--- Agregar calificacion ---\n";
    Estudiante* e = buscarPorCodigo(leerLinea("Codigo del estudiante: "));
    if (!e) {
        cout << "  No se encontro ningun estudiante con ese codigo.\n";
        return;
    }
    cout << "Cursos:\n";
    for (int c = 0; c < NUM_CURSOS; ++c) cout << "  " << c + 1 << ") " << CURSOS[c] << '\n';
    int c = leerEntero("Curso: ", 1, NUM_CURSOS) - 1;
    double nota = leerNota("Nueva calificacion de " + CURSOS[c] + ": ");
    string codigo = e->codigo;
    if (enviarAccion("nota", {{"codigo", codigo}, {"curso", to_string(c)}, {"nota", to_string(nota)}})) {
        cargar(false);
        e = buscarPorCodigo(codigo);
        if (e)
            cout << "Calificacion agregada. Promedio en " << CURSOS[c] << ": " << fixed << setprecision(2)
                 << e->promedioCurso(c) << " | Promedio general: " << e->promedio() << '\n';
    }
}

void buscarEstudiante() {
    cout << "\n--- Buscar por codigo ---\n";
    Estudiante* e = buscarPorCodigo(leerLinea("Codigo: "));
    if (!e) {
        cout << "  No se encontro ningun estudiante con ese codigo.\n";
        return;
    }
    encabezadoTabla();
    imprimirFila(*e);
    cout << "\nCalificaciones por curso:\n";
    for (int c = 0; c < NUM_CURSOS; ++c) {
        cout << "  " << left << setw(42) << CURSOS[c];
        if (e->notas[c].empty()) cout << "(sin notas)";
        else {
            for (double n : e->notas[c]) cout << n << ' ';
            cout << "-> prom. " << fixed << setprecision(2) << e->promedioCurso(c);
        }
        cout << '\n';
    }
}

void listarEstudiantes() {
    cout << "\n--- Lista de estudiantes ---\n";
    imprimirLista(estudiantes);
}

void ordenarPorCalificacion() {
    cout << "\n--- Ordenar por promedio ---\n";
    int op = leerEntero("1) Mayor a menor  2) Menor a mayor: ", 1, 2);
    vector<Estudiante> copia = estudiantes;
    stable_sort(copia.begin(), copia.end(), [op](const Estudiante& a, const Estudiante& b) {
        return op == 1 ? a.promedio() > b.promedio() : a.promedio() < b.promedio();
    });
    imprimirLista(copia);
}

void estadisticas() {
    cout << "\n--- Estadisticas ---\n";
    if (estudiantes.empty()) {
        cout << "  No hay estudiantes registrados.\n";
        return;
    }
    int aprobados = 0, conNotas = 0;
    double suma = 0;
    for (const auto& e : estudiantes) {
        if (e.totalNotas() == 0) continue;
        ++conNotas;
        suma += e.promedio();
        if (e.aprobado()) ++aprobados;
    }
    cout << "Total de estudiantes: " << estudiantes.size() << '\n'
         << "Con calificaciones:   " << conNotas << '\n'
         << "Aprobados (>= " << NOTA_APROBACION << "): " << aprobados << '\n'
         << "Reprobados:           " << conNotas - aprobados << '\n';
    if (conNotas) cout << "Promedio general:     " << fixed << setprecision(2) << suma / conNotas << '\n';

    cout << "\nPromedio por curso:\n";
    for (int c = 0; c < NUM_CURSOS; ++c) {
        double s = 0;
        int n = 0;
        for (const auto& e : estudiantes)
            if (!e.notas[c].empty()) { s += e.promedioCurso(c); ++n; }
        cout << "  " << left << setw(42) << CURSOS[c];
        if (n) cout << fixed << setprecision(2) << s / n << '\n';
        else cout << "(sin notas)\n";
    }
}

void eliminarEstudiante() {
    cout << "\n--- Eliminar estudiante ---\n";
    Estudiante* e = buscarPorCodigo(leerLinea("Codigo: "));
    if (!e) {
        cout << "  No se encontro ningun estudiante con ese codigo.\n";
        return;
    }
    if (aMayusculas(leerLinea("Eliminar a '" + e->nombre + "'? (s/n): ")) != "S") {
        cout << "Operacion cancelada.\n";
        return;
    }
    if (enviarAccion("eliminar", {{"codigo", e->codigo}})) {
        cargar(false);
        cout << "Estudiante eliminado.\n";
    }
}

int main() {
    SetConsoleCP(CP_UTF8);        // nombres con tildes: la base de datos usa UTF-8
    SetConsoleOutputCP(CP_UTF8);
    cout << "=== Sistema de Gestion de Estudiantes ===\n";
    if (!cargar(true)) return 1;
    while (true) {
        cargar(false);  // refresca por si el HTML modifico los datos
        cout << "\n1) Registrar estudiante\n2) Agregar calificacion\n3) Buscar por codigo\n"
                "4) Listar estudiantes\n5) Ordenar por promedio\n6) Estadisticas\n"
                "7) Eliminar estudiante\n0) Salir\n";
        switch (leerEntero("Opcion: ", 0, 7)) {
            case 1: registrarEstudiante(); break;
            case 2: agregarCalificacion(); break;
            case 3: buscarEstudiante(); break;
            case 4: listarEstudiantes(); break;
            case 5: ordenarPorCalificacion(); break;
            case 6: estadisticas(); break;
            case 7: eliminarEstudiante(); break;
            case 0:
                cout << "Hasta luego.\n";
                return 0;
        }
    }
}
