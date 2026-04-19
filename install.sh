#!/bin/bash
# install.sh - Автоматический установщик FreePBX

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🚀 FreePBX 17 Installer${NC}"
echo "=================================="

# URL скрипта и хеша
SCRIPT_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/russian.sh"
HASH_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/version.hash"

# Скачиваем скрипт
echo "📥 Скачивание скрипта..."
curl -sL "$SCRIPT_URL" -o russian.sh

# Скачиваем ожидаемый хеш
echo "🔑 Проверка подлинности..."
EXPECTED=$(curl -sL "$HASH_URL")
ACTUAL=$(sha256sum russian.sh | awk '{print $1}')

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo -e "${RED}❌ ОШИБКА: Контрольная сумма не совпадает!${NC}"
    echo "Скрипт мог быть повреждён или подменён."
    echo "Ожидалось: $EXPECTED"
    echo "Получено:  $ACTUAL"
    exit 1
fi

echo -e "${GREEN}✅ Контрольная сумма совпадает${NC}"

# Делаем скрипт исполняемым
chmod +x russian.sh

# Запускаем установку
echo "🚀 Запуск установки..."
sudo ./russian.sh --opensourceonly "$@"

# Очистка
rm -f russian.sh

echo -e "${GREEN}✅ Установка завершена!${NC}"
