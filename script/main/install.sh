#!/bin/bash
# =============================================================================
# check-system.sh – Расширенная предустановочная проверка для FreePBX 17
# =============================================================================
# Проверяет систему, сетевые ресурсы, репозитории и альтернативные источники.
# Запуск:
#   bash check-system.sh              # интерактивный режим
#   bash check-system.sh --quiet      # тихий режим (только код возврата)
#   bash check-system.sh --full       # полная проверка (включая целостность скриптов)
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Параметры
QUIET=false
FULL_CHECK=false
for arg in "$@"; do
    case $arg in
        --quiet) QUIET=true ;;
        --full) FULL_CHECK=true ;;
    esac
done

# Счётчики
error_count=0
warn_count=0
info_count=0

# Функции вывода
log_message() {
    if [ "$QUIET" = false ]; then
        echo -e "$1"
    fi
}

log_error() {
    log_message "   ${RED}❌ $1${NC}"
    error_count=$((error_count + 1))
}

log_warning() {
    log_message "   ${YELLOW}⚠️ $1${NC}"
    warn_count=$((warn_count + 1))
}

log_success() {
    log_message "   ${GREEN}✅ $1${NC}"
}

log_info() {
    log_message "   ${BLUE}ℹ️ $1${NC}"
    info_count=$((info_count + 1))
}

# Заголовок
log_message "${BLUE}════════════════════════════════════════════════════════════${NC}"
log_message "${GREEN}🔍 Расширенная проверка системы для FreePBX 17${NC}"
log_message "${BLUE}════════════════════════════════════════════════════════════${NC}"
log_message ""

# =============================================================================
# 1. Базовые системные проверки
# =============================================================================
log_message "${BLUE}1. Базовые системные требования${NC}"
log_message "${BLUE}────────────────────────────────────────────────────────${NC}"

# 1.1 Архитектура
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" != "amd64" ]; then
    log_error "Архитектура $ARCH не поддерживается. Требуется amd64."
else
    log_success "Архитектура: amd64"
fi

# 1.2 Права на запись в /usr/src
if [ ! -w /usr/src ]; then
    log_error "Нет прав на запись в /usr/src (нужно для сборки Asterisk)"
else
    log_success "Права на запись в /usr/src"
fi

# 1.3 Свободное место в /usr/src (минимум 5 ГБ)
FREE_SPACE=$(df /usr/src | awk 'NR==2 {print $4}')
if [ $FREE_SPACE -lt 5242880 ]; then
    log_error "Недостаточно места в /usr/src: $((FREE_SPACE / 1024)) МБ (нужно ≥5 ГБ)"
else
    log_success "Свободное место в /usr/src: $((FREE_SPACE / 1024)) МБ"
fi

# 1.4 Наличие apt-get
if command -v apt-get > /dev/null 2>&1; then
    log_success "apt-get доступен"
else
    log_error "apt-get не найден. Это не Debian/Ubuntu?"
fi

# 1.5 Проверка PATH
REQUIRED_PATH_DIRS="/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin"
for dir in $REQUIRED_PATH_DIRS; do
    if [[ ":$PATH:" != *":$dir:"* ]]; then
        log_warning "Директория $dir отсутствует в PATH"
    fi
done

# 1.6 Порт 80 и 3306
if ss -tlnp | grep -q ':80 '; then
    log_warning "Порт 80 уже занят. Возможен конфликт с веб-сервером."
else
    log_success "Порт 80 свободен"
fi
if ss -tlnp | grep -q ':3306 '; then
    log_warning "Порт 3306 уже занят. Возможен конфликт с MySQL."
else
    log_success "Порт 3306 свободен"
fi

# =============================================================================
# 2. Сетевые проверки (доступ к интернету, DNS)
# =============================================================================
log_message ""
log_message "${BLUE}2. Сетевые проверки${NC}"
log_message "${BLUE}────────────────────────────────────────────────────────${NC}"

# 2.1 Доступ к интернету (deb.debian.org)
if curl -s --connect-timeout 5 https://deb.debian.org > /dev/null 2>&1; then
    log_success "Интернет доступен (deb.debian.org)"
else
    log_error "Нет доступа к deb.debian.org (проверьте сеть)"
fi

# 2.2 DNS (разрешение github.com)
if ping -c 1 github.com > /dev/null 2>&1; then
    log_success "DNS работает (github.com разрешается)"
else
    log_warning "GitHub может быть недоступен (проверьте DNS)"
fi

# 2.3 Обнаружение контейнера (не критично)
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    log_warning "Обнаружен контейнер (Docker/LXC). Некоторые функции могут не работать."
fi

# =============================================================================
# 3. Проверка репозиториев для вашего скрипта (российские зеркала)
# =============================================================================
log_message ""
log_message "${BLUE}3. Проверка репозиториев для вашего скрипта (российские зеркала)${NC}"
log_message "${BLUE}────────────────────────────────────────────────────────${NC}"

# 3.1 Зеркало Яндекса (Debian)
if curl -s --connect-timeout 5 https://mirror.yandex.ru/debian/ > /dev/null 2>&1; then
    log_success "Зеркало Яндекса (mirror.yandex.ru) доступно"
    YANDEX_OK=true
else
    log_error "Зеркало Яндекса недоступно – ваш скрипт не сможет обновить списки пакетов"
    YANDEX_OK=false
fi

# 3.2 Российское зеркало FreePBX (git.freepbx.asterisk.ru)
if curl -s --connect-timeout 5 http://git.freepbx.asterisk.ru > /dev/null 2>&1; then
    log_success "Российское зеркало FreePBX (git.freepbx.asterisk.ru) доступно"
    RUS_MIRROR_OK=true
else
    log_warning "Российское зеркало FreePBX недоступно – ваш скрипт переключится на официальный репозиторий"
    RUS_MIRROR_OK=false
fi

# 3.3 Доступность ваших скриптов на GitHub (raw)
BASE_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master"
if curl -s --head --fail "$BASE_URL/russian.sh" > /dev/null 2>&1; then
    log_success "Ваш основной скрипт (russian.sh) доступен"
    SCRIPT_AVAILABLE=true
else
    log_error "Ваш основной скрипт (russian.sh) недоступен – установка невозможна"
    SCRIPT_AVAILABLE=false
fi

if [ "$FULL_CHECK" = true ] && [ "$SCRIPT_AVAILABLE" = true ]; then
    # проверка хеша
    if curl -s --head --fail "$BASE_URL/russian.hash" > /dev/null 2>&1; then
        TMP_DIR=$(mktemp -d)
        curl -s "$BASE_URL/russian.sh" -o "$TMP_DIR/russian.sh"
        curl -s "$BASE_URL/russian.hash" -o "$TMP_DIR/russian.hash"
        EXPECTED=$(cat "$TMP_DIR/russian.hash" | tr -d ' \n\r')
        ACTUAL=$(sha256sum "$TMP_DIR/russian.sh" | awk '{print $1}')
        if [ "$ACTUAL" = "$EXPECTED" ]; then
            log_success "Хеш russian.sh совпадает (целостность подтверждена)"
        else
            log_error "Хеш russian.sh НЕ совпадает! Скрипт повреждён."
        fi
        rm -rf "$TMP_DIR"
    else
        log_warning "russian.hash не доступен – проверка целостности невозможна"
    fi
fi

# =============================================================================
# 4. Проверка альтернативных источников (для других скриптов)
# =============================================================================
log_message ""
log_message "${BLUE}4. Проверка альтернативных источников (официальные, IN1CLICK)${NC}"
log_message "${BLUE}────────────────────────────────────────────────────────${NC}"

# 4.1 Официальный репозиторий FreePBX (packages.freepbx.org)
if curl -s --connect-timeout 5 http://packages.freepbx.org > /dev/null 2>&1; then
    log_success "Официальный репозиторий FreePBX (packages.freepbx.org) доступен"
    OFFICIAL_REPO_OK=true
else
    log_warning "Официальный репозиторий FreePBX недоступен – установка через официальный скрипт Sangoma может не работать"
    OFFICIAL_REPO_OK=false
fi

# 4.2 Официальный скрипт Sangoma
SANGOMA_URL="https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh"
if curl -s --head --fail "$SANGOMA_URL" > /dev/null 2>&1; then
    log_success "Официальный скрипт Sangoma доступен"
    SANGOMA_SCRIPT_OK=true
else
    log_warning "Официальный скрипт Sangoma недоступен"
    SANGOMA_SCRIPT_OK=false
fi

# 4.3 Скрипт IN1CLICK (20tele.com) – предполагаемый URL (уточните при необходимости)
IN1CLICK_URL="https://raw.githubusercontent.com/20tele/IN1CLICK/master/in1click.sh"
if curl -s --head --fail "$IN1CLICK_URL" > /dev/null 2>&1; then
    log_success "Скрипт IN1CLICK доступен"
    IN1CLICK_OK=true
else
    log_warning "Скрипт IN1CLICK недоступен (возможно, URL изменился)"
    IN1CLICK_OK=false
fi

# =============================================================================
# 5. Итог и рекомендации
# =============================================================================
log_message ""
log_message "${BLUE}════════════════════════════════════════════════════════════${NC}"
log_message "${GREEN}📊 Результаты проверки${NC}"
log_message "${BLUE}════════════════════════════════════════════════════════════${NC}"

if [ $error_count -gt 0 ]; then
    log_message "${RED}❌ Критических ошибок: $error_count${NC}"
    log_message "${RED}Установка вашего скрипта невозможна. Устраните проблемы и повторите проверку.${NC}"
    # Даже если есть ошибки, возможно, альтернативные скрипты сработают?
    if [ "$OFFICIAL_REPO_OK" = true ] && [ "$SANGOMA_SCRIPT_OK" = true ]; then
        log_message "${YELLOW}⚠️ Однако официальный репозиторий и скрипт Sangoma доступны. Вы можете попробовать установить FreePBX через официальный скрипт:${NC}"
        log_message "   bash <(curl -sL https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh)"
    fi
    if [ "$IN1CLICK_OK" = true ]; then
        log_message "   Или через IN1CLICK: bash <(curl -sL https://raw.githubusercontent.com/20tele/IN1CLICK/master/in1click.sh)"
    fi
    exit 1
elif [ $warn_count -gt 0 ]; then
    log_message "${YELLOW}⚠️ Предупреждений: $warn_count${NC}"
    if [ "$SCRIPT_AVAILABLE" = true ] && [ "$YANDEX_OK" = true ]; then
        log_message "${GREEN}✅ Ваш скрипт должен работать, несмотря на предупреждения.${NC}"
        log_message "   Рекомендуется запустить установку: bash <(curl -sL https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/install.sh)"
    else
        log_message "${YELLOW}⚠️ Ваш скрипт может не работать из-за недоступности некоторых ресурсов.${NC}"
        if [ "$OFFICIAL_REPO_OK" = true ] && [ "$SANGOMA_SCRIPT_OK" = true ]; then
            log_message "   Попробуйте официальный скрипт Sangoma:"
            log_message "   bash <(curl -sL https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh)"
        fi
        if [ "$IN1CLICK_OK" = true ]; then
            log_message "   Или IN1CLICK: bash <(curl -sL https://raw.githubusercontent.com/20tele/IN1CLICK/master/in1click.sh)"
        fi
    fi
    if [ "$QUIET" = false ]; then
        read -p "Продолжить установку вашим скриптом? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Установка отменена."
            exit 1
        fi
    fi
else
    log_message "${GREEN}✅ Все проверки пройдены успешно. Система полностью готова к установке вашим скриптом.${NC}"
    log_message "   Запустите установку: bash <(curl -sL https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master/install.sh)"
    exit 0
fi