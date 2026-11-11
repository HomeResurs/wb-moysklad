# Импорт заказов WB → МойСклад

Инструмент в одном HTML-файле: загружаете выгрузку заказов Wildberries (Excel),
он находит товары в МойСклад по артикулу/штрихкоду и создаёт заказы покупателя.

**Сайт:** https://homeresurs.github.io/wb-moysklad/

## Как это устроено

```
браузер → GitHub Pages (index.html, статика)
        → https://wb-moysklad-proxy.netlify.app/api/ms (Netlify Function, прокси)
        → https://api.moysklad.ru
```

`api.moysklad.ru` не отдаёт CORS-заголовки, поэтому напрямую из браузера к нему
обратиться нельзя. GitHub Pages умеет только статику, поэтому прокси живёт
отдельно, на бесплатном тарифе Netlify. Токен МойСклад хранится только в
браузере пользователя, прокси его не сохраняет и не логирует.

| Файл | Зачем |
|---|---|
| `index.html` | сам инструмент |
| `vendor/xlsx.full.min.js` | чтение Excel (локально, без CDN) |
| `netlify/functions/ms.mjs` | прокси к API МойСклад (Netlify Function, путь `/api/ms`) |
| `netlify.toml` | настройки Netlify: папка функций, заголовки |
| `alt-proxy/` | запасные варианты прокси: `ms-proxy.php` (PHP-хостинг), `nginx.conf.example` |
| `.nojekyll` | GitHub Pages отдаёт файлы как есть, без Jekyll |

## Публикация

### Статика — GitHub Pages

Settings → Pages → Source: *Deploy from a branch*, ветка `main`, папка `/ (root)`.
Каждый push в `main` обновляет сайт за минуту-две.

### Прокси — Netlify

Один раз, из папки репозитория (нужен `netlify-cli` и вход в аккаунт):

```bash
netlify sites:create --name wb-moysklad-proxy --disable-linking
```

Затем после каждого изменения `netlify/functions/ms.mjs`:

```bash
netlify deploy --prod --site wb-moysklad-proxy
```

Проверка: `https://wb-moysklad-proxy.netlify.app/api/ms?ping=1` должен вернуть
`{"ok":true,"proxy":"netlify",...}`.

Прокси принимает запросы из браузера только с `https://homeresurs.github.io`,
с самого Netlify-сайта и с `localhost`. Другие адреса — переменная окружения
`ALLOWED_ORIGINS` на Netlify (через запятую).

Так как `netlify deploy` выкладывает и статику, инструмент открывается и по
адресу `https://wb-moysklad-proxy.netlify.app/` — там прокси на том же домене.

## Если прокси на Netlify перестал работать

В инструменте откройте «Адрес прокси» под кнопкой «Подключиться» и укажите
другой:

- `ms-proxy.php` рядом с `index.html` на любом PHP-хостинге (файл в `alt-proxy/`);
- `/ms-api` на своём nginx (`alt-proxy/nginx.conf.example`).

Пустое поле возвращает адрес по умолчанию.

## Настройки в index.html (блок CONFIG)

- `PROXY_URL` — адрес прокси по умолчанию
- `DEFAULT_AGENT` — контрагент по умолчанию (`ВАЙЛДБЕРРИЗ`)
- `DEFAULT_STORE` — склад по умолчанию (`WB наш склад`)
- `QTY_ATTRIBUTE_NAME` — доп. поле заказа для суммарного количества (`Кол-во`)
- `DEFAULT_COLUMNS` — колонки, если в файле нет заголовков (G — артикул, I — баркод)
