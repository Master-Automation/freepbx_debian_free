#!/bin/bash
# =============================================================================
# install.sh – Главный установщик FreePBX 17
# Версия: 1.0.0
# =============================================================================
# Загружает и проверяет целостность:
#   - russian.sh (основной установщик)
#   - debug.sh (отладчик)
#   - report.sh (скрипт отправки отчёта)
# При несовпадении хеша предлагает продолжить или отказаться.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master"

# Список компонентов: имя_файла, URL, файл_хеша, описание
COMPONENTS=(
    "russian.sh:${BASE_URL}/russian.sh:${BASE_URL}/version.hash:основной установщик"
    "debug.sh:${BASE_URL}/debug.sh:${BASE_URL}/debug.hash:отладчик"
    "report.sh:${BASE_URL}/report.sh:${BASE_URL}/report.hash:скрипт отправки отчёта"
)

# Функция проверки одного компонента
check_component() {
    local filename="$1"
    local url="$2"
    local hash_url="$3"
    local desc="$4"

    echo -e "${BLUE}🔍 Проверка $desc ($filename)...${NC}"
    curl -sL --fail "$url" -o "$filename" || {
        echo -e "${RED}❌ Не удалось скачать $filename${NC}"
        return 1
    }
    local expected_hash=$(curl -sL "$hash_url" | tr -d ' \n\r')
    local actual_hash=$(sha256sum "$filename" | awk '{print $1}')
    if [ "$actual_hash" = "$expected_hash" ]; then
        echo -e "${GREEN}   ✅ Хеш совпадает${NC}"
        return 0
    else
        echo -e "${YELLOW}   ⚠️ Хеш НЕ совпадает!${NC}"
        echo "      Ожидалось: $expected_hash"
        echo "      Получено:  $actual_hash"
        read -p "   Продолжить использование этого компонента? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "   ⚠️ Используется непроверенный компонент"
            return 0
        else
            echo "   ❌ Отказ от компонента"
            return 1
        fi
    fi
}

# Проверяем все компоненты
ALL_OK=true
for comp in "${COMPONENTS[@]}"; do
    IFS=':' read -r filename url hash_url desc <<< "$comp"
    if ! check_component "$filename" "$url" "$hash_url" "$desc"; then
        ALL_OK=false
    fi
done

if [ "$ALL_OK" = false ]; then
    echo -e "${RED}❌ Критические компоненты не прошли проверку. Установка невозможна.${NC}"
    exit 1
fi

# Делаем скрипты исполняемыми
chmod +x russian.sh debug.sh report.sh

# Запуск основного установщика
echo -e "${GREEN}🚀 Запуск основного установщика...${NC}"
sudo ./russian.sh --opensourceonly "$@"

# Очистка (опционально)
# rm -f russian.sh debug.sh report.sh

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ Установка завершена${NC}"
echo -e "${GREEN}======================================${NC}"
