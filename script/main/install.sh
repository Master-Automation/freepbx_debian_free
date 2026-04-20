#!/bin/bash
# install.sh - Автоматический установщик FreePBX (Версия: freepbx)

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 1. Исправление DNS (чтобы GitHub всегда был доступен)
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null

echo -e "${GREEN}🚀 FreePBX 17 Optimized Installer (Master-Automation)${NC}"
echo "=================================================="

# 2. ПРАВИЛЬНЫЙ BASE_URL (указывает на папку со скриптами)
BASE_URL="https://githubusercontent.com"

# 3. Список компонентов: имя_файла, описание, обязательный? (1-да, 0-нет)
COMPONENTS=(
    "russian.sh:Основной установщик:1"
    "system-pre-check.sh:Предварительная проверка системы:0"
    "debug.sh:Скрипт отладки:0"
    "report.sh:Скрипт отчетов:0"
)

error_exit() {
    echo -e "${RED}❌ ОШИБКА: $1${NC}"
    exit 1
}

DOWNLOADED=()

# 4. Цикл загрузки и проверки компонентов
for comp in "${COMPONENTS[@]}"; do
    IFS=':' read -r filename desc required <<< "$comp"

    echo -e "${BLUE}🔍 Проверка $desc ($filename)...${NC}"

    # Скачивание файла
    if ! curl -sL --fail "${BASE_URL}/${filename}" -o "$filename"; then
        if [ "$required" = "1" ]; then
            error_exit "Не удалось скачать обязательный компонент $filename по адресу ${BASE_URL}/${filename}"
        else
            echo -e "${YELLOW}⚠️ Пропущен необязательный компонент $filename${NC}"
            continue
        fi
    fi

    # Скачивание и проверка хеша (если он есть на GitHub)
    if curl -sL --fail "${BASE_URL}/${filename}.hash" -o "${filename}.hash" 2>/dev/null; then
        EXPECTED=$(cat "${filename}.hash" | awk '{print $1}' | tr -d ' \n\r')
        ACTUAL=$(sha256sum "$filename" | awk '{print $1}')
        
        if [ "$ACTUAL" != "$EXPECTED" ]; then
            if [ "$required" = "1" ]; then
                error_exit "Хеш обязательного файла $filename не совпадает!"
            else
                echo -e "${YELLOW}⚠️ Хеш $filename не совпадает, файл удален${NC}"
                rm -f "$filename" "${filename}.hash"
                continue
            fi
        fi
        echo -e "${GREEN}   ✅ Проверка хеша пройдена${NC}"
        rm -f "${filename}.hash"
    else
        echo -e "${YELLOW}   ℹ️ Хеш-файл не найден, скачивание без проверки${NC}"
    fi

    chmod +x "$filename"
    DOWNLOADED+=("$filename")
done

echo -e "${GREEN}✅ Все доступные компоненты загружены.${NC}"
echo ""

# 5. ЗАПУСК ПРЕДВАРИТЕЛЬНОЙ ПРОВЕРКИ (если скачана)
if [[ -f "./system-pre-check.sh" ]]; then
    echo -e "${BLUE}📋 Запуск предварительной проверки системы...${NC}"
    ./system-pre-check.sh || echo -e "${YELLOW}⚠️ Проверка выдала предупреждения, но продолжаем...${NC}"
fi

# 6. ЗАПУСК ОСНОВНОГО УСТАНОВЩИКА
if [[ -f "./russian.sh" ]]; then
    echo -e "${BLUE}🚀 Запуск установки FreePBX (это займет время)...${NC}"
    sudo ./russian.sh --opensourceonly "$@"
else
    error_exit "Критическая ошибка: файл russian.sh не найден!"
fi

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ Установка через install.sh завершена!${NC}"
echo -e "${GREEN}======================================${NC}"
