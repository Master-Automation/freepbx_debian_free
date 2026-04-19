#!/bin/bash
# install.sh - Автоматический установщик FreePBX

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}🚀 FreePBX 17 Installer${NC}"
echo "=================================="
echo ""

# URL скрипта и хеша
SCRIPT_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/russian.sh"
HASH_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/version.hash"

# Шаг 1: Скачивание скрипта
echo -e "${BLUE}📥 Шаг 1/3: Скачивание скрипта...${NC}"
curl -sL "$SCRIPT_URL" -o russian.sh
echo -e "${GREEN}   ✅ Скрипт скачан: russian.sh${NC}"
echo ""

# Шаг 2: Проверка подлинности
echo -e "${BLUE}🔑 Шаг 2/3: Проверка подлинности скрипта...${NC}"
EXPECTED=$(curl -sL "$HASH_URL")
ACTUAL=$(sha256sum russian.sh | awk '{print $1}')

echo "   Ожидаемый хеш: ${EXPECTED:0:16}..."
echo "   Фактический хеш: ${ACTUAL:0:16}..."

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo ""
    echo -e "${RED}❌ ОШИБКА: Контрольная сумма не совпадает!${NC}"
    echo "   Скрипт мог быть повреждён или подменён."
    echo "   Установка прервана в целях безопасности."
    echo ""
    echo "   Что делать?"
    echo "   1. Проверьте подключение к интернету"
    echo "   2. Попробуйте запустить установку позже"
    echo "   3. Свяжитесь с автором скрипта"
    rm -f russian.sh
    exit 1
fi

echo -e "${GREEN}   ✅ Контрольная сумма совпадает!${NC}"
echo -e "${GREEN}   ✅ Скрипт подлинный и не был изменён${NC}"
echo ""

# Шаг 3: Запуск установки
echo -e "${BLUE}🚀 Шаг 3/3: Запуск установки FreePBX...${NC}"
echo "   (это может занять 20-60 минут)"
echo ""

# Делаем скрипт исполняемым
chmod +x russian.sh

# Запускаем установку
sudo ./russian.sh --opensourceonly "$@"

# Очистка
rm -f russian.sh

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ Установка успешно завершена!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "🌐 Откройте веб-интерфейс: http://$(hostname -I | awk '{print $1}')"
echo "📝 Логин: admin (пароль задаётся при первом входе)"
echo ""
