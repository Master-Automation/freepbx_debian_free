#!/bin/bash
# install.sh - Автоматический установщик FreePBX (простая версия)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error_exit() {
    echo -e "${RED}❌ ОШИБКА: $1${NC}"
    echo "Установка прервана."
    exit 1
}

echo -e "${GREEN}🚀 FreePBX 17 Installer${NC}"
echo "=================================="
echo ""

# URL скрипта и хеша
SCRIPT_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/russian.sh"
HASH_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/version.hash"

# Шаг 1: Скачивание скрипта
echo -e "${BLUE}📥 Шаг 1/4: Скачивание скрипта...${NC}"
curl -sL --fail "$SCRIPT_URL" -o russian.sh || error_exit "Не удалось скачать russian.sh"
echo -e "${GREEN}   ✅ Скрипт скачан${NC}"
echo ""

# Шаг 2: Скачивание хеша
echo -e "${BLUE}🔑 Шаг 2/4: Скачивание хеша...${NC}"
curl -sL --fail "$HASH_URL" -o version.hash.tmp || error_exit "Не удалось скачать version.hash"
EXPECTED=$(cat version.hash.tmp | tr -d ' \n\r')
rm -f version.hash.tmp
echo -e "${GREEN}   ✅ Хеш получен: ${EXPECTED:0:16}...${NC}"
echo ""

# Шаг 3: Проверка подлинности
echo -e "${BLUE}🔒 Шаг 3/4: Проверка подлинности скрипта...${NC}"
ACTUAL=$(sha256sum russian.sh | awk '{print $1}')
echo "   Ожидаемый хеш: ${EXPECTED:0:16}..."
echo "   Фактический хеш: ${ACTUAL:0:16}..."

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo -e "${RED}❌ Контрольная сумма НЕ совпадает!${NC}"
    echo "   Скрипт мог быть повреждён или подменён."
    rm -f russian.sh
    error_exit "Проверка подлинности не пройдена"
fi

echo -e "${GREEN}   ✅ Контрольная сумма совпадает!${NC}"
echo -e "${GREEN}   ✅ Скрипт подлинный${NC}"
echo ""

# Шаг 4: Запуск установки
echo -e "${BLUE}🚀 Шаг 4/4: Запуск установки FreePBX...${NC}"
echo "   (это может занять 20-60 минут)"
echo ""

chmod +x russian.sh
sudo ./russian.sh --opensourceonly "$@"

# Очистка
rm -f russian.sh

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ Установка завершена!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "🌐 Откройте веб-интерфейс: http://$(hostname -I | awk '{print $1}')"
echo "📝 Логин: admin (пароль задаётся при первом входе)"
