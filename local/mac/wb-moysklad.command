#!/bin/bash
# Импорт заказов WB -> МойСклад: запуск на Mac.
# Первый раз — в Терминале (так macOS не блокирует файл):
#   curl -fsSL https://homeresurs.github.io/wb-moysklad/local/mac/wb-moysklad.command -o ~/wb-moysklad.command && chmod +x ~/wb-moysklad.command && ~/wb-moysklad.command
# Дальше — двойной щелчок по wb-moysklad.command в папке пользователя (Finder → Переход → Личное).

SCRIPT_URL="${WBMS_SCRIPT_URL:-https://homeresurs.github.io/wb-moysklad/local/mac/wb-moysklad.pl}"
DIR="$HOME/Library/Application Support/wb-moysklad"
SCRIPT="$DIR/wb-moysklad.pl"

finish() {
  echo
  read -r -p "Нажмите Enter, чтобы закрыть окно." _
  exit "${1:-0}"
}

mkdir -p "$DIR" || finish 1

# Каждый запуск берём свежую версию скрипта; без интернета — сохранённую.
if curl -fsSL --max-time 60 -o "$SCRIPT.part" "$SCRIPT_URL"; then
  mv "$SCRIPT.part" "$SCRIPT"
else
  rm -f "$SCRIPT.part"
  if [ ! -f "$SCRIPT" ]; then
    echo "Не удалось скачать $SCRIPT_URL. Проверьте интернет и запустите ещё раз."
    finish 1
  fi
  echo "Не удалось обновить скрипт, запускаю сохранённую версию."
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "На этом Mac не найден perl, а он нужен для запуска."
  echo "Установите инструменты командной строки: в Терминале выполните  xcode-select --install"
  finish 1
fi

perl "$SCRIPT"
echo "Инструмент остановлен."
finish 0
