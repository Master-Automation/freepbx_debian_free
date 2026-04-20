#!/bin/bash
# install.sh - Автоматический установщик FreePBX (Версия: freepbx)

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Исправление DNS (чтобы GitHub всегда был доступен)
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null

echo -e "${GREEN}🚀 FreePBX 17 Optimized Installer${NC}"
echo "=================================="

# НОВЫЙ BASE_URL с коротким именем репозитория
BASE_URL="https://githubusercontent.com"

# Список компонентов: имя_файла, описание, обязательный?
COMPONENTS=(
    "russian.sh:Основной установщик:1"
    "debug.sh:Скрипт отладки:0"
    "report.sh:Скрипт отчетов:0"
)

error_exit() {
    echo -e "${RED}❌ ОШИБКА: $1${NC}"
    exit 1
}

DOWNLOADED=()

for comp in "${COMPONENTS[@]}"; do
    IFS=':' read -r filename desc required <<< "$comp"

    echo -e "${BLUE}🔍 Проверка $desc ($filename)...${NC}"

    # Скачивание основного файла
    if ! curl -sL --fail "${BASE_URL}/${filename}" -o "$filename"; then
        if [ "$required" = "1" ]; then
            error_exit "Не удалось скачать обязательный компонент $filename"
        else
            echo -e "${YELLOW}⚠️ Пропущен необязательный компонент $filename${NC}"
            continue
        fi
    fi

    # Скачивание и проверка хеша
    if curl -sL --fail "${BASE_URL}/${filename}.hash" -o "${filename}.hash" 2>/dev/null; then
        EXPECTED=$(cat "${filename}.hash" | awk '{print $1}' | tr -d ' \n\r')
        ACTUAL=$(sha256sum "$filename" | awk '{print $1}')
        
        if [ "$ACTUAL" != "$EXPECTED" ]; then
            if [ "$required" = "1" ]; then
                error_exit "Хеш $filename не совпадает!"
            else
                echo -e "${YELLOW}⚠️ Хеш $filename не совпадает, файл удален${NC}"
                rm -f "$filename"
                continue
            fi
        fi
        echo -e "${GREEN}   ✅ Проверка хеша пройдена${NC}"
        rm -f "${filename}.hash"
    fi

    chmod +x "$filename"
    DOWNLOADED+=("$filename")
done

echo -e "${GREEN}✅ Все доступные компоненты загружены${NC}"

# Запуск основного установщика
if [[ -f "./russian.sh" ]]; then
    echo -e "${BLUE}🚀 Запуск установки FreePBX...${NC}"
    sudo ./russian.sh --opensourceonly "$@"
else
    error_exit "Файл russian.sh не найден!"
fi
