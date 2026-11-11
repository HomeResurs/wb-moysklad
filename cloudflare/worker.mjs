// Cloudflare Worker: та же логика прокси, что и в Netlify Function.
// Деплой: `wrangler deploy` из корня репозитория (см. wrangler.toml).
import { handle } from '../netlify/functions/ms.mjs';

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/api/ms') {
      return new Response('wb-moysklad proxy: используйте /api/ms', { status: 404, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    }
    return handle(request, { PROXY_NAME: 'cloudflare', CF_REGION: request.cf && request.cf.colo, ...env });
  },
};
