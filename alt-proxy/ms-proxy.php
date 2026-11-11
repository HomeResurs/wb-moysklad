<?php
/**
 * Прокси к API МойСклад для инструмента «Импорт заказов WB → МойСклад».
 *
 * Зачем: api.moysklad.ru не отдаёт CORS-заголовки, поэтому браузер не пускает
 * запросы к нему напрямую со страницы. Этот файл лежит на том же домене, что
 * и index.html (relaxdev.ru), поэтому браузер обращается к «своему» серверу, а
 * сервер уже ходит в МойСклад. Никаких внешних сервисов (Cloudflare и т.п.).
 *
 * Что делает:
 *   ms-proxy.php?ping=1                     — проверка, что прокси работает
 *   ms-proxy.php?path=/entity/product?...   — запрос к https://api.moysklad.ru/api/remap/1.2/entity/product?...
 *
 * Безопасность:
 *   • ходит ТОЛЬКО на api.moysklad.ru и только в разрешённые разделы API;
 *   • токен/пароль не сохраняется и не пишется в логи — просто передаётся дальше;
 *   • запросы с чужих сайтов (cross-site) отклоняются.
 *
 * Требования: PHP 7.2+ с расширением curl (есть на любом хостинге: Beget, Timeweb, REG.RU, Sprinthost…).
 */

declare(strict_types=1);

// ---------- Настройки ----------
const MS_BASE = 'https://api.moysklad.ru/api/remap/1.2';

// Разрешённые разделы API (всё остальное — 403)
const ALLOWED_PREFIXES = ['/entity/', '/context/', '/report/', '/security/token'];

// Разрешённые источники. Пустой массив = проверять только, что запрос не cross-site.
// При желании впишите свои домены: ['https://relaxdev.ru', 'https://www.relaxdev.ru']
const ALLOWED_ORIGINS = [];

const TIMEOUT_SEC = 60;

// ---------- Вспомогательное ----------
function fail(int $code, string $message): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(['errors' => [['error' => $message, 'proxy' => true]]], JSON_UNESCAPED_UNICODE);
    exit;
}

function header_value(string $name): string {
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    if (!empty($_SERVER[$key])) return (string)$_SERVER[$key];
    if (!empty($_SERVER['REDIRECT_' . $key])) return (string)$_SERVER['REDIRECT_' . $key];
    if (function_exists('getallheaders')) {
        foreach (getallheaders() as $k => $v) {
            if (strcasecmp($k, $name) === 0) return (string)$v;
        }
    }
    return '';
}

// ---------- Проверка источника ----------
$secFetchSite = header_value('Sec-Fetch-Site');
if ($secFetchSite === 'cross-site') {
    fail(403, 'Запрос с чужого сайта отклонён.');
}
$origin = header_value('Origin');
if ($origin !== '' && ALLOWED_ORIGINS && !in_array($origin, ALLOWED_ORIGINS, true)) {
    fail(403, 'Источник запроса не разрешён: ' . $origin);
}

// ---------- ping ----------
if (isset($_GET['ping'])) {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode([
        'ok'    => true,
        'proxy' => 'php',
        'php'   => PHP_VERSION,
        'curl'  => function_exists('curl_init'),
    ]);
    exit;
}

// ---------- Метод ----------
$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
if (!in_array($method, ['GET', 'POST', 'PUT'], true)) {
    fail(405, 'Метод не поддерживается: ' . $method);
}

// ---------- Путь ----------
$path = (string)($_GET['path'] ?? '');
if ($path === '' || $path[0] !== '/') fail(400, 'Не указан путь запроса (path).');
if (strpos($path, '..') !== false || strpos($path, '://') !== false || strpos($path, '\\') !== false
    || preg_match('/[\x00-\x1f]/', $path)) {
    fail(400, 'Недопустимый путь запроса.');
}
$allowed = false;
foreach (ALLOWED_PREFIXES as $p) {
    if (strncmp($path, $p, strlen($p)) === 0) { $allowed = true; break; }
}
if (!$allowed) fail(403, 'Этот раздел API через прокси недоступен.');

// ---------- Авторизация ----------
// Фронтенд кладёт её в X-Ms-Authorization: часть хостингов (Apache + PHP-CGI)
// вырезает стандартный заголовок Authorization.
$auth = header_value('X-Ms-Authorization');
if ($auth === '') $auth = header_value('Authorization');
if ($auth === '') fail(401, 'Не передан токен или логин/пароль МойСклад.');
if (!preg_match('/^(Bearer|Basic) [A-Za-z0-9+\/=._\-]+$/', $auth)) {
    fail(400, 'Неверный формат авторизации.');
}

$body = in_array($method, ['POST', 'PUT'], true) ? file_get_contents('php://input') : null;
if ($body !== null && strlen($body) > 5 * 1024 * 1024) fail(413, 'Слишком большой запрос.');

$url = MS_BASE . $path;
$reqHeaders = [
    'Authorization: ' . $auth,
    'Accept: application/json;charset=utf-8',
    'User-Agent: relaxdev-wb-moysklad/2.0',
];
if ($body !== null) $reqHeaders[] = 'Content-Type: application/json';

// ---------- Запрос ----------
$respHeaders = [];
$status = 0;
$respBody = '';

if (function_exists('curl_init')) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $reqHeaders,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_ENCODING       => '',        // МойСклад требует Accept-Encoding: gzip; curl сам распакует
        CURLOPT_TIMEOUT        => TIMEOUT_SEC,
        CURLOPT_CONNECTTIMEOUT => 15,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_HEADERFUNCTION => function ($ch, $line) use (&$respHeaders) {
            $parts = explode(':', $line, 2);
            if (count($parts) === 2) $respHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
            return strlen($line);
        },
    ]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    $respBody = curl_exec($ch);
    if ($respBody === false) {
        $err = curl_error($ch);
        curl_close($ch);
        fail(502, 'Сервер не смог связаться с МойСклад: ' . $err);
    }
    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
} else {
    // Запасной вариант без curl
    $ctx = stream_context_create(['http' => [
        'method'        => $method,
        'header'        => implode("\r\n", array_merge($reqHeaders, ['Accept-Encoding: gzip'])),
        'content'       => $body ?? '',
        'timeout'       => TIMEOUT_SEC,
        'ignore_errors' => true,
    ]]);
    $respBody = @file_get_contents($url, false, $ctx);
    if ($respBody === false) fail(502, 'Сервер не смог связаться с МойСклад (нет curl и allow_url_fopen).');
    foreach ($http_response_header ?? [] as $line) {
        if (preg_match('#^HTTP/\S+\s+(\d{3})#', $line, $m)) { $status = (int)$m[1]; continue; }
        $parts = explode(':', $line, 2);
        if (count($parts) === 2) $respHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
    }
    if (($respHeaders['content-encoding'] ?? '') === 'gzip') {
        $decoded = @gzdecode($respBody);
        if ($decoded !== false) $respBody = $decoded;
    }
}

// ---------- Ответ ----------
http_response_code($status ?: 502);
header('Content-Type: ' . ($respHeaders['content-type'] ?? 'application/json; charset=utf-8'));
header('Cache-Control: no-store');
foreach (['x-lognex-retry-after', 'x-ratelimit-remaining', 'x-lognex-retry-timeinterval'] as $h) {
    if (isset($respHeaders[$h])) header($h . ': ' . $respHeaders[$h]);
}
echo $respBody;
