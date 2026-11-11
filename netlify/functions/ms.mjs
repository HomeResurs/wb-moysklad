// Прокси к API МойСклад для «Импорт заказов WB → МойСклад» (Netlify Function).
// Страница на GitHub Pages обращается к https://wb-moysklad-proxy.netlify.app/api/ms,
// функция — к api.moysklad.ru. Токен не сохраняется и не логируется,
// ходим только на api.moysklad.ru и только в разрешённые разделы API.

const MS_BASE = 'https://api.moysklad.ru/api/remap/1.2';
const ALLOWED_PREFIXES = ['/entity/', '/context/', '/report/', '/security/token'];
const UPSTREAM_TIMEOUT_MS = 9500; // лимит Netlify на синхронную функцию — 10 с
const PASSTHROUGH_HEADERS = ['x-lognex-retry-after', 'x-ratelimit-remaining', 'x-lognex-retry-timeinterval'];

// Откуда разрешены запросы из браузера (CORS). Дополнительные адреса — через
// переменную окружения ALLOWED_ORIGINS (через запятую).
const STATIC_ORIGINS = ['https://homeresurs.github.io'];

function allowedOrigins(selfOrigin) {
  const extra = (process.env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean);
  return new Set([...STATIC_ORIGINS, selfOrigin, ...extra]);
}

function isLocalDev(origin) {
  return /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/.test(origin);
}

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-ms-authorization',
    'Access-Control-Expose-Headers': PASSTHROUGH_HEADERS.join(', '),
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
}

function jsonResponse(status, body, extraHeaders) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...extraHeaders },
  });
}

function fail(status, message, extraHeaders) {
  return jsonResponse(status, { errors: [{ error: message, proxy: true }] }, extraHeaders);
}

function validatePath(path) {
  if (!path || path[0] !== '/') return 'Не указан путь запроса (path).';
  if (path.includes('..') || path.includes('://') || path.includes('\\') || /[\x00-\x1f]/.test(path)) return 'Недопустимый путь запроса.';
  if (!ALLOWED_PREFIXES.some(p => path.startsWith(p))) return 'Этот раздел API через прокси недоступен.';
  return null;
}

function validateAuth(auth) {
  if (!auth) return 'Не передан токен или логин/пароль МойСклад.';
  if (!/^(Bearer|Basic) [A-Za-z0-9+\/=._\-]+$/.test(auth)) return 'Неверный формат авторизации.';
  return null;
}

async function forward(method, path, auth, body) {
  const headers = {
    Authorization: auth,
    Accept: 'application/json;charset=utf-8',
    'Accept-Encoding': 'gzip', // МойСклад требует gzip; fetch сам распакует
    'User-Agent': 'wb-moysklad-netlify/2.1',
  };
  if (body) headers['Content-Type'] = 'application/json';
  return fetch(MS_BASE + path, {
    method,
    headers,
    body: body || undefined,
    redirect: 'manual',
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
}

export default async (req) => {
  const url = new URL(req.url);
  const origin = req.headers.get('origin') || '';
  const cors = origin && (allowedOrigins(url.origin).has(origin) || isLocalDev(origin)) ? corsHeaders(origin) : {};

  if (origin && !Object.keys(cors).length) return fail(403, 'Запрос с чужого сайта отклонён: ' + origin);
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });

  if (url.searchParams.has('ping')) {
    return jsonResponse(200, { ok: true, proxy: 'netlify', node: process.version, region: process.env.AWS_REGION || null }, cors);
  }

  const method = req.method.toUpperCase();
  if (!['GET', 'POST', 'PUT'].includes(method)) return fail(405, 'Метод не поддерживается: ' + method, cors);

  const path = url.searchParams.get('path') || '';
  const pathError = validatePath(path);
  if (pathError) return fail(400, pathError, cors);

  const auth = req.headers.get('x-ms-authorization') || req.headers.get('authorization') || '';
  const authError = validateAuth(auth);
  if (authError) return fail(401, authError, cors);

  const body = method === 'GET' ? '' : await req.text();

  let upstream;
  try {
    upstream = await forward(method, path, auth, body);
  } catch (e) {
    return fail(502, 'Сервер не смог связаться с МойСклад: ' + (e && e.message ? e.message : e), cors);
  }

  const headers = {
    'Content-Type': upstream.headers.get('content-type') || 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...cors,
  };
  for (const h of PASSTHROUGH_HEADERS) {
    const v = upstream.headers.get(h);
    if (v) headers[h] = v;
  }
  return new Response(await upstream.text(), { status: upstream.status, headers });
};

export const config = { path: '/api/ms' };
