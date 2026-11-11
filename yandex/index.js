// Yandex Cloud Function: обёртка над общей логикой прокси (netlify/functions/ms.mjs).
// Серверы в РФ, бесплатно до 1 млн вызовов в месяц, провайдеры не режут.
// Адрес вызова: https://functions.yandexcloud.net/<id функции>?path=/entity/...
// Сборка и деплой — см. README, раздел «Прокси — Yandex Cloud Functions».

let handlePromise = null;
function loadHandle() {
  if (!handlePromise) handlePromise = import('./ms.mjs').then(m => m.handle);
  return handlePromise;
}

function toRequest(event) {
  const query = new URLSearchParams();
  const params = event.queryStringParameters || {};
  for (const key of Object.keys(params)) query.append(key, params[key]);
  const qs = query.toString();
  const url = 'https://functions.yandexcloud.net/' + (event.functionId || 'fn') + (qs ? '?' + qs : '');

  const method = (event.httpMethod || 'GET').toUpperCase();
  const headers = new Headers();
  for (const [k, v] of Object.entries(event.headers || {})) {
    if (typeof v === 'string') headers.set(k, v);
  }
  let body;
  if (method !== 'GET' && method !== 'HEAD' && event.body) {
    body = event.isBase64Encoded ? Buffer.from(event.body, 'base64') : event.body;
  }
  return new Request(url, { method, headers, body });
}

module.exports.handler = async function handler(event) {
  const handle = await loadHandle();
  const res = await handle(toRequest(event), { ...process.env, PROXY_NAME: 'yandex', CF_REGION: 'ru-central1' });
  const headers = {};
  res.headers.forEach((value, key) => { headers[key] = value; });
  return { statusCode: res.status, headers, body: await res.text(), isBase64Encoded: false };
};
