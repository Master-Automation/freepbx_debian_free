#!/bin/bash
# install.sh - Автоматический установщик FreePBX (с проверкой всех скриптов)

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

ask_continue() {
    local component="$1"
    echo -e "${YELLOW}⚠️ Проблема с компонентом: $component${NC}"
    read -p "   Продолжить установку без него? (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

echo -e "${GREEN}🚀 FreePBX 17 Installer${NC}"
echo "=================================="
echo ""

BASE_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master"

# Список компонентов: имя_файла, URL, URL_хеша, описание, обязательный? (1=да, 0=нет)
COMPONENTS=(
    "russian.sh:${BASE_URL}/russian.sh:${BASE_URL}/russian.hash:основной установщик:1"
    "debug.sh:${BASE_URL}/debug.sh:${BASE_URL}/debug.hash:отладчик:0"
    "report.sh:${BASE_URL}/report.sh:${BASE_URL}/report.hash:скрипт отчёта:0"
)

# Массив для хранения имён успешно загруженных скриптов
DOWNLOADED=()

for comp in "${COMPONENTS[@]}"; do
    IFS=':' read -r filename url hash_url desc required <<< "$comp"

    echo -e "${BLUE}🔍 Проверка $desc ($filename)...${NC}"

    # Скачиваем скрипт
    if ! curl -sL --fail "$url" -o "$filename"; then
        echo -e "${RED}❌ Не удалось скачать $filename${NC}"
        if [ "$required" = "1" ]; then
            error_exit "Не удалось скачать обязательный компонент $filename"
        else
            if ask_continue "$filename"; then
                continue
            else
                error_exit "Пользователь отказался от установки"
            fi
        fi
    fi

    # Скачиваем хеш
    if ! curl -sL --fail "$hash_url" -o "${filename}.hash.tmp"; then
        echo -e "${RED}❌ Не удалось скачать хеш для $filename${NC}"
        if [ "$required" = "1" ]; then
            error_exit "Не удалось скачать хеш для обязательного компонента $filename"
        else
            if ask_continue "$filename (хеш отсутствует)"; then
                rm -f "$filename"
                continue
            else
                error_exit "Пользователь отказался от установки"
            fi
        fi
    fi

    EXPECTED=$(cat "${filename}.hash.tmp" | tr -d ' \n\r')
    ACTUAL=$(sha256sum "$filename" | awk '{print $1}')
    rm -f "${filename}.hash.tmp"

    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo -e "${RED}❌ Хеш НЕ совпадает для $filename${NC}"
        echo "   Ожидалось: $EXPECTED"
        echo "   Получено:  $ACTUAL"
        if [ "$required" = "1" ]; then
            error_exit "Несовпадение хеша для обязательного компонента $filename"
        else
            if ask_continue "$filename (несовпадение хеша)"; then
                rm -f "$filename"
                continue
            else
                error_exit "Пользователь отказался от установки"
            fi
        fi
    fi

    echo -e "${GREEN}   ✅ $desc проверен${NC}"
    chmod +x "$filename"
    DOWNLOADED+=("$filename")
done

echo ""
echo -e "${GREEN}✅ Все проверки пройдены${NC}"
echo ""

# Запуск основного установщика
if [[ ! " ${DOWNLOADED[@]} " =~ " russian.sh " ]]; then
    error_exit "Основной скрипт russian.sh не загружен или не прошёл проверку"
fi

echo -e "${BLUE}🚀 Запуск установки FreePBX...${NC}"
echo "   (это может занять 20-60 минут)"
echo ""

sudo ./russian.sh --opensourceonly "$@"

# Очистка (опционально)
# rm -f russian.sh debug.sh report.sh

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ Установка завершена!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "🌐 Откройте веб-интерфейс: http://$(hostname -I | awk '{print $1}')"
echo "📝 Логин: admin (пароль задаётся при первом входе)"
