<?php
// API del Sistema de Gestion de Estudiantes (PHP + MySQL).
// Crea la base de datos y las tablas la primera vez que se usa.

const DB_HOST = 'localhost';
const DB_USER = 'root';
const DB_PASS = '';
const DB_NAME = 'sistema_estudiantes';

const NOTA_MIN = 0.0;
const NOTA_MAX = 20.0;
const MAX_NOTAS = 20;
const CURSOS = [
    'Matematica',
    'Ciencia y Tecnologia',
    'Ciencias Sociales',
    'Desarrollo Personal, Ciudadania y Civica',
    'Comunicacion',
    'Arte',
    'Ingles',
];

function responder(array $datos, int $codigo = 200): void {
    http_response_code($codigo);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($datos, JSON_UNESCAPED_UNICODE);
    exit;
}

function fallar(string $mensaje, int $codigo = 400): void {
    responder(['ok' => false, 'error' => $mensaje], $codigo);
}

function conectar(): PDO {
    $pdo = new PDO('mysql:host=' . DB_HOST . ';charset=utf8mb4', DB_USER, DB_PASS, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    $pdo->exec('CREATE DATABASE IF NOT EXISTS `' . DB_NAME . '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
    $pdo->exec('USE `' . DB_NAME . '`');

    $opciones = 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci';
    $pdo->exec("CREATE TABLE IF NOT EXISTS cursos (
        id TINYINT UNSIGNED PRIMARY KEY,
        nombre VARCHAR(60) NOT NULL
    ) $opciones");
    $pdo->exec("CREATE TABLE IF NOT EXISTS estudiantes (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        codigo VARCHAR(15) NOT NULL UNIQUE,
        nombre VARCHAR(100) NOT NULL
    ) $opciones");
    $pdo->exec("CREATE TABLE IF NOT EXISTS notas (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        estudiante_id INT UNSIGNED NOT NULL,
        curso_id TINYINT UNSIGNED NOT NULL,
        nota DECIMAL(4,2) NOT NULL,
        INDEX (estudiante_id, curso_id),
        FOREIGN KEY (estudiante_id) REFERENCES estudiantes(id) ON DELETE CASCADE,
        FOREIGN KEY (curso_id) REFERENCES cursos(id)
    ) $opciones");

    $ins = $pdo->prepare('INSERT IGNORE INTO cursos (id, nombre) VALUES (?, ?)');
    foreach (CURSOS as $i => $nombre) $ins->execute([$i, $nombre]);
    return $pdo;
}

function listar(PDO $pdo): array {
    $est = [];
    foreach ($pdo->query('SELECT id, codigo, nombre FROM estudiantes ORDER BY id') as $r) {
        $est[$r['id']] = [
            'codigo' => $r['codigo'],
            'nombre' => $r['nombre'],
            'notas' => array_fill(0, count(CURSOS), []),
        ];
    }
    foreach ($pdo->query('SELECT estudiante_id, curso_id, nota FROM notas ORDER BY id') as $n) {
        $est[$n['estudiante_id']]['notas'][(int)$n['curso_id']][] = (float)$n['nota'];
    }
    return array_values($est);
}

// "n;n|n|...|n": un campo por curso, notas separadas por ';'
function parsearNotas(string $texto): array {
    $campos = explode('|', $texto);
    if (count($campos) !== count(CURSOS)) fallar('Formato de notas invalido.');
    $res = [];
    foreach ($campos as $c => $campo) {
        $v = [];
        foreach (explode(';', $campo) as $tok) {
            $tok = trim($tok);
            if ($tok === '') continue;
            if (!is_numeric($tok) || (float)$tok < NOTA_MIN || (float)$tok > NOTA_MAX)
                fallar(CURSOS[$c] . ": la calificacion '$tok' debe ser un numero entre " . NOTA_MIN . ' y ' . NOTA_MAX . '.');
            $v[] = (float)$tok;
        }
        if (count($v) > MAX_NOTAS) fallar(CURSOS[$c] . ': maximo ' . MAX_NOTAS . ' calificaciones.');
        $res[] = $v;
    }
    return $res;
}

function idPorCodigo(PDO $pdo, string $codigo): ?int {
    $st = $pdo->prepare('SELECT id FROM estudiantes WHERE codigo = ?');
    $st->execute([$codigo]);
    $id = $st->fetchColumn();
    return $id === false ? null : (int)$id;
}

$accion = $_REQUEST['accion'] ?? '';
$esPost = $_SERVER['REQUEST_METHOD'] === 'POST';

try {
    $pdo = conectar();

    switch ($accion) {
        case 'listar':
            responder(['ok' => true, 'estudiantes' => listar($pdo)]);

        case 'exportar':  // texto plano: codigo|nombre|notas curso 1|...|notas curso N (lo usa el .cpp)
            header('Content-Type: text/plain; charset=utf-8');
            foreach (listar($pdo) as $e) {
                echo $e['codigo'], '|', $e['nombre'];
                foreach ($e['notas'] as $v) echo '|', implode(';', $v);
                echo "\n";
            }
            exit;

        case 'registrar':
            if (!$esPost) fallar('Metodo no permitido.', 405);
            $codigo = trim($_POST['codigo'] ?? '');
            $nombre = trim($_POST['nombre'] ?? '');
            if (!preg_match('/^[A-Za-z0-9]{1,15}$/', $codigo)) fallar('Codigo invalido (solo letras/numeros, max. 15).');
            if ($nombre === '' || mb_strlen($nombre) > 100 || strpos($nombre, '|') !== false || preg_match('/\d/', $nombre))
                fallar("El nombre no puede estar vacio ni contener numeros o '|'.");
            $notas = parsearNotas($_POST['notas'] ?? str_repeat('|', count(CURSOS) - 1));
            if (idPorCodigo($pdo, $codigo) !== null) fallar('Ya existe un estudiante con ese codigo.', 409);

            $pdo->beginTransaction();
            $pdo->prepare('INSERT INTO estudiantes (codigo, nombre) VALUES (?, ?)')->execute([$codigo, $nombre]);
            $id = (int)$pdo->lastInsertId();
            $ins = $pdo->prepare('INSERT INTO notas (estudiante_id, curso_id, nota) VALUES (?, ?, ?)');
            foreach ($notas as $c => $v) foreach ($v as $n) $ins->execute([$id, $c, $n]);
            $pdo->commit();
            responder(['ok' => true]);

        case 'nota':
            if (!$esPost) fallar('Metodo no permitido.', 405);
            $id = idPorCodigo($pdo, trim($_POST['codigo'] ?? ''));
            if ($id === null) fallar('No se encontro ningun estudiante con ese codigo.', 404);
            $curso = filter_var($_POST['curso'] ?? null, FILTER_VALIDATE_INT);
            if ($curso === false || $curso < 0 || $curso >= count(CURSOS)) fallar('Curso invalido.');
            $nota = $_POST['nota'] ?? '';
            if (!is_numeric($nota) || (float)$nota < NOTA_MIN || (float)$nota > NOTA_MAX)
                fallar('La calificacion debe ser un numero entre ' . NOTA_MIN . ' y ' . NOTA_MAX . '.');
            $st = $pdo->prepare('SELECT COUNT(*) FROM notas WHERE estudiante_id = ? AND curso_id = ?');
            $st->execute([$id, $curso]);
            if ($st->fetchColumn() >= MAX_NOTAS) fallar(CURSOS[$curso] . ': maximo ' . MAX_NOTAS . ' calificaciones.');
            $pdo->prepare('INSERT INTO notas (estudiante_id, curso_id, nota) VALUES (?, ?, ?)')->execute([$id, $curso, (float)$nota]);
            responder(['ok' => true]);

        case 'eliminar':
            if (!$esPost) fallar('Metodo no permitido.', 405);
            $st = $pdo->prepare('DELETE FROM estudiantes WHERE codigo = ?');
            $st->execute([trim($_POST['codigo'] ?? '')]);
            if ($st->rowCount() === 0) fallar('No se encontro ningun estudiante con ese codigo.', 404);
            responder(['ok' => true]);

        default:
            fallar('Accion desconocida.', 404);
    }
} catch (PDOException $e) {
    if (isset($pdo) && $pdo->inTransaction()) $pdo->rollBack();
    fallar('Error de base de datos: ' . $e->getMessage(), 500);
}
