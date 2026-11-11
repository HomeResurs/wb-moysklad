#!/usr/bin/env bash
# Деплой прокси в Yandex Cloud Functions. Нужен настроенный yc (`yc init`).
# Запуск из корня репозитория: bash yandex/deploy.sh
set -euo pipefail

NAME="wb-moysklad-proxy"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

cp "$ROOT/yandex/index.js" "$BUILD/index.js"
cp "$ROOT/netlify/functions/ms.mjs" "$BUILD/ms.mjs"
(cd "$BUILD" && python3 -c "import zipfile; z=zipfile.ZipFile('fn.zip','w',zipfile.ZIP_DEFLATED); z.write('index.js'); z.write('ms.mjs'); z.close()" 2>/dev/null \
  || py -c "import zipfile; z=zipfile.ZipFile('fn.zip','w',zipfile.ZIP_DEFLATED); z.write('index.js'); z.write('ms.mjs'); z.close()")

if ! yc serverless function get --name "$NAME" >/dev/null 2>&1; then
  yc serverless function create --name "$NAME" --description "Прокси МойСклад для homeresurs.github.io/wb-moysklad"
fi
yc serverless function allow-unauthenticated-invoke --name "$NAME" >/dev/null

yc serverless function version create \
  --function-name "$NAME" \
  --runtime nodejs22 \
  --entrypoint index.handler \
  --memory 128m \
  --execution-timeout 30s \
  --source-path "$BUILD/fn.zip"

ID="$(yc serverless function get --name "$NAME" --format json | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null \
  || yc serverless function get --name "$NAME" --format json | py -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
echo
echo "Адрес прокси: https://functions.yandexcloud.net/$ID"
echo "Проверка:     https://functions.yandexcloud.net/$ID?ping=1"
