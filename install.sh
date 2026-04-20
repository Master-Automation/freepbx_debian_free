#!/bin/bash
set -e

# Цвета для вывода
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🚀 FreePBX 17 Multi-Component Installer${NC}"

# 1. Исправляем DNS перед началом (критично для скачивания)
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null

# 2. Базовый URL (RAW)
BASE_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master"

# 3. Список компонентов (Имя_файла:Описание)
# Обязательно создай на GitHub файлы .hash для каждого скрипта!
COMPONENTS=(
    "russian.sh:Основной установщик"
    "debug.sh:Скрипт отладки"
    "report.sh:Скрипт отчетов"
)

for comp in "${COMPONENTS[@]}"; do
    filename="${comp%%:*}"
    description="${comp#*:}"

    echo -e "${BLUE}🔍 Обработка $description ($filename)...${NC}"

    # Скачивание основного файла
    if ! curl -sL --fail "${BASE_URL}/${filename}" -o "$filename"; then
        echo -e "${RED}❌ Не удалось скачать $filename. Пропускаем...${NC}"
        continue
    fi

    # Скачивание хеша
    if ! curl -sL --fail "${BASE_URL}/${filename}.hash" -o "${filename}.hash"; then
        echo -e "${RED}⚠️ Хеш для $filename не найден. Проверка пропущена.${NC}"
    else
        EXPECTED=$(cat "${filename}.hash" | awk '{print $1}' | tr -d ' \n\r')
        ACTUAL=$(sha256sum "$filename" | awk '{print $1}')
        
        if [ "$ACTUAL" != "$EXPECTED" ]; then
            echo -e "${RED}❌ ОШИБКА: Хеш $filename не совпадает! Удаление файла.${NC}"
            rm -f "$filename" "${filename}.hash"
            continue
        fi
        echo -e "${GREEN}   ✅ Хеш совпадает${NC}"
        rm -f "${filename}.hash"
    fi

    chmod +x "$filename"
done

# 4. Запуск основного процесса
if [ -f "./russian.sh" ]; then
    echo -e "${BLUE}🚀 Запуск основного процесса установки...${NC}"
    sudo ./russian.sh --opensourceonly "$@"
else
    echo -e "${RED}❌ Критическая ошибка: russian.sh не найден!${NC}"
    exit 1
fi
