#!/bin/bash
# ============================================================================
# check-system.sh – Модуль проверок системы для FreePBX 17
# Версия: 2.0.0
# ============================================================================
# ОГЛАВЛЕНИЕ:
#   1.  CHECK_OS            – Debian 12, архитектура amd64
#   2.  CHECK_PERMISSIONS   – права на запись в /usr/src, /tmp
#   3.  CHECK_DISK_SPACE    – свободное место в /usr/src (≥5 ГБ)
#   4.  CHECK_INTERNET      – доступ к deb.debian.org, DNS
#   5.  CHECK_PORTS         – порты 80 и 3306 свободны?
#   6.  CHECK_APT           – наличие apt-get и его работа
#   7.  CHECK_CONFLICTS     – нет уже установленных FreePBX/Asterisk/MySQL
#   8.  CHECK_HOSTNAME      – hostname не localhost и корректный
#   9.  CHECK_RUSSIAN_MIRRORS – доступность зеркал (Яндекс, git.freepbx...)
#  10.  CHECK_FILES         – целостность russian.sh (опционально)
#  11.  RUN_ALL_CHECKS      – запуск всех проверок (интерактивный режим)
#  12.  RUN_CHECK_BY_NAME   – запуск конкретной проверки по имени
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Параметры по умолчанию
QUIET=false
FULL_CHECK=false
error_count=0
warn_count=0

# ----------------------------------------------------------------------------
# Вспомогательные функции вывода
# ----------------------------------------------------------------------------
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
}

# ============================================================================
# 1. CHECK_OS – операционная система
# ============================================================================
check_os() {
    local name="CHECK_OS"
    log_message "${BLUE}[$name] Проверка операционной системы...${NC}"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] || [ "$VERSION_CODENAME" != "bookworm" ]; then
            log_error "Требуется Debian 12 (bookworm). Обнаружено: $PRETTY_NAME"
            return 1
        else
            log_success "ОС: $PRETTY_NAME"
        fi
    else
        log_error "Не удалось определить ОС (нет /etc/os-release)"
        return 1
    fi

    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" != "amd64" ]; then
        log_error "Архитектура $ARCH не поддерживается. Требуется amd64."
        return 1
    else
        log_success "Архитектура: amd64"
    fi
    return 0
}

# ============================================================================
# 2. CHECK_PERMISSIONS – права на запись
# ============================================================================
check_permissions() {
    local name="CHECK_PERMISSIONS"
    log_message "${BLUE}[$name] Проверка прав на запись...${NC}"
    local ok=true

    if [ ! -w /usr/src ]; then
        log_error "Нет прав на запись в /usr/src"
        ok=false
    else
        log_success "Права на запись в /usr/src"
    fi

    if [ ! -w /tmp ]; then
        log_error "Нет прав на запись в /tmp"
        ok=false
    else
        log_success "Права на запись в /tmp"
    fi

    $ok && return 0 || return 1
}

# ============================================================================
# 3. CHECK_DISK_SPACE – свободное место
# ============================================================================
check_disk_space() {
    local name="CHECK_DISK_SPACE"
    log_message "${BLUE}[$name] Проверка свободного места на диске...${NC}"
    FREE_SPACE=$(df /usr/src | awk 'NR==2 {print $4}')
    if [ $FREE_SPACE -lt 5242880 ]; then
        log_error "Недостаточно места в /usr/src: $((FREE_SPACE / 1024)) МБ (нужно ≥5 ГБ)"
        return 1
    else
        log_success "Свободное место в /usr/src: $((FREE_SPACE / 1024)) МБ"
        return 0
    fi
}

# ============================================================================
# 4. CHECK_INTERNET – доступ к интернету и DNS
# ============================================================================
check_internet() {
    local name="CHECK_INTERNET"
    log_message "${BLUE}[$name] Проверка интернета и DNS...${NC}"
    local ok=true

    if curl -s --connect-timeout 5 https://deb.debian.org > /dev/null 2>&1; then
        log_success "Интернет доступен (deb.debian.org)"
    else
        log_error "Нет доступа к deb.debian.org (проверьте сеть)"
        ok=false
    fi

    if ping -c 1 github.com > /dev/null 2>&1; then
        log_success "DNS работает (github.com разрешается)"
    else
        log_warning "GitHub может быть недоступен (проверьте DNS)"
    fi

    $ok && return 0 || return 1
}

# ============================================================================
# 5. CHECK_PORTS – свободные порты 80 и 3306
# ============================================================================
check_ports() {
    local name="CHECK_PORTS"
    log_message "${BLUE}[$name] Проверка портов...${NC}"
    local ok=true

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
    return 0  # не фатально
}

# ============================================================================
# 6. CHECK_APT – наличие apt-get
# ============================================================================
check_apt() {
    local name="CHECK_APT"
    log_message "${BLUE}[$name] Проверка apt-get...${NC}"
    if command -v apt-get > /dev/null 2>&1; then
        log_success "apt-get доступен"
        return 0
    else
        log_error "apt-get не найден. Это не Debian/Ubuntu?"
        return 1
    fi
}

# ============================================================================
# 7. CHECK_CONFLICTS – конфликтующие установки
# ============================================================================
check_conflicts() {
    local name="CHECK_CONFLICTS"
    log_message "${BLUE}[$name] Проверка конфликтующих компонентов...${NC}"
    local ok=true

    if command -v asterisk > /dev/null 2>&1; then
        log_warning "Asterisk уже установлен. Возможны конфликты."
    fi
    if command -v fwconsole > /dev/null 2>&1; then
        log_warning "FreePBX уже установлен. Возможны конфликты."
    fi
    if systemctl is-active --quiet mariadb 2>/dev/null; then
        log_warning "MySQL/MariaDB уже запущен. Возможны конфликты."
    fi
    return 0  # только предупреждения
}

# ============================================================================
# 8. CHECK_HOSTNAME – корректность hostname
# ============================================================================
check_hostname() {
    local name="CHECK_HOSTNAME"
    log_message "${BLUE}[$name] Проверка hostname...${NC}"
    HOST=$(hostname)
    if [ "$HOST" = "localhost" ] || [ "$HOST" = "localhost.localdomain" ]; then
        log_warning "Hostname установлен как localhost. Рекомендуется изменить на уникальное имя."
    elif [[ "$HOST" =~ [[:space:]] ]]; then
        log_warning "Hostname содержит пробелы или спецсимволы: '$HOST'"
    else
        log_success "Hostname: $HOST"
    fi
    return 0
}

# ============================================================================
# 9. CHECK_RUSSIAN_MIRRORS – доступность российских зеркал
# ============================================================================
check_russian_mirrors() {
    local name="CHECK_RUSSIAN_MIRRORS"
    log_message "${BLUE}[$name] Проверка российских зеркал...${NC}"
    local ok=true

    if curl -s --connect-timeout 5 https://mirror.yandex.ru/debian/ > /dev/null 2>&1; then
        log_success "Зеркало Яндекса (mirror.yandex.ru) доступно"
    else
        log_warning "Зеркало Яндекса недоступно – ваш скрипт не сможет обновить списки пакетов"
    fi

    if curl -s --connect-timeout 5 http://git.freepbx.asterisk.ru > /dev/null 2>&1; then
        log_success "Российское зеркало FreePBX (git.freepbx.asterisk.ru) доступно"
    else
        log_warning "Российское зеркало FreePBX недоступно – скрипт переключится на официальный репозиторий"
    fi
    return 0
}

# ============================================================================
# 10. CHECK_FILES – целостность russian.sh (только при --full)
# ============================================================================
check_files() {
    local name="CHECK_FILES"
    log_message "${BLUE}[$name] Проверка целостности основного скрипта...${NC}"
    BASE_URL="https://raw.githubusercontent.com/Master-Automation/freepbx_debian_free/master"
    if ! curl -s --head --fail "$BASE_URL/russian.sh" > /dev/null 2>&1; then
        log_error "russian.sh не доступен – установка невозможна"
        return 1
    fi
    if ! curl -s --head --fail "$BASE_URL/russian.hash" > /dev/null 2>&1; then
        log_warning "russian.hash не доступен – проверка целостности невозможна"
        return 0
    fi
    TMP_DIR=$(mktemp -d)
    curl -s "$BASE_URL/russian.sh" -o "$TMP_DIR/russian.sh"
    curl -s "$BASE_URL/russian.hash" -o "$TMP_DIR/russian.hash"
    EXPECTED=$(cat "$TMP_DIR/russian.hash" | tr -d ' \n\r')
    ACTUAL=$(sha256sum "$TMP_DIR/russian.sh" | awk '{print $1}')
    rm -rf "$TMP_DIR"
    if [ "$ACTUAL" = "$EXPECTED" ]; then
        log_success "Хеш russian.sh совпадает (целостность подтверждена)"
        return 0
    else
        log_error "Хеш russian.sh НЕ совпадает! Скрипт повреждён."
        return 1
    fi
}

# ============================================================================
# 11. RUN_ALL_CHECKS – запуск всех проверок
# ============================================================================
run_all_checks() {
    log_message "${BLUE}════════════════════════════════════════════════════════════${NC}"
    log_message "${GREEN}🔍 Расширенная проверка системы для FreePBX 17${NC}"
    log_message "${BLUE}════════════════════════════════════════════════════════════${NC}"
    log_message ""

    check_os
    check_permissions
    check_disk_space
    check_internet
    check_ports
    check_apt
    check_conflicts
    check_hostname
    check_russian_mirrors
    if [ "$FULL_CHECK" = true ]; then
        check_files
    fi

    log_message ""
    log_message "${BLUE}════════════════════════════════════════════════════════════${NC}"
    if [ $error_count -gt 0 ]; then
        log_message "${RED}❌ Критических ошибок: $error_count. Установка невозможна.${NC}"
        exit 1
    elif [ $warn_count -gt 0 ]; then
        log_message "${YELLOW}⚠️ Предупреждений: $warn_count. Установка возможна, но могут быть проблемы.${NC}"
        if [ "$QUIET" = false ]; then
            read -p "Продолжить установку? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Установка отменена."
                exit 1
            fi
        fi
    else
        log_message "${GREEN}✅ Все проверки пройдены успешно. Система готова к установке.${NC}"
    fi
    exit 0
}

# ============================================================================
# 12. RUN_CHECK_BY_NAME – запуск конкретной проверки по имени
# ============================================================================
run_check_by_name() {
    local check_name=$1
    case "$check_name" in
        CHECK_OS)                check_os ;;
        CHECK_PERMISSIONS)       check_permissions ;;
        CHECK_DISK_SPACE)        check_disk_space ;;
        CHECK_INTERNET)          check_internet ;;
        CHECK_PORTS)             check_ports ;;
        CHECK_APT)               check_apt ;;
        CHECK_CONFLICTS)         check_conflicts ;;
        CHECK_HOSTNAME)          check_hostname ;;
        CHECK_RUSSIAN_MIRRORS)   check_russian_mirrors ;;
        CHECK_FILES)             check_files ;;
        RUN_ALL_CHECKS)          run_all_checks ;;
        *)
            echo "Неизвестная проверка: $check_name"
            echo "Доступные: CHECK_OS, CHECK_PERMISSIONS, CHECK_DISK_SPACE, CHECK_INTERNET, CHECK_PORTS, CHECK_APT, CHECK_CONFLICTS, CHECK_HOSTNAME, CHECK_RUSSIAN_MIRRORS, CHECK_FILES, RUN_ALL_CHECKS"
            exit 1
            ;;
    esac
    # После выполнения одиночной проверки выводим итог и код возврата
    if [ $error_count -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

# ============================================================================
# MAIN: диспетчер аргументов
# ============================================================================
for arg in "$@"; do
    case $arg in
        --quiet) QUIET=true ;;
        --full) FULL_CHECK=true ;;
    esac
done

# Убираем флаги из аргументов для дальнейшей обработки
ARGS=()
for arg in "$@"; do
    if [[ "$arg" != "--quiet" && "$arg" != "--full" ]]; then
        ARGS+=("$arg")
    fi
done

if [ ${#ARGS[@]} -eq 0 ]; then
    run_all_checks
elif [ ${#ARGS[@]} -eq 1 ] && [ "${ARGS[0]}" = "--check" ]; then
    echo "Ошибка: после --check нужно указать имя проверки"
    exit 1
elif [ ${#ARGS[@]} -eq 2 ] && [ "${ARGS[0]}" = "--check" ]; then
    run_check_by_name "${ARGS[1]}"
else
    echo "Использование:"
    echo "  check-system.sh [--quiet] [--full]               # все проверки"
    echo "  check-system.sh --quiet --check ИМЯ_ПРОВЕРКИ     # одна проверка"
    echo "  check-system.sh --check ИМЯ_ПРОВЕРКИ             # одна проверка (с выводом)"
    exit 1
fi