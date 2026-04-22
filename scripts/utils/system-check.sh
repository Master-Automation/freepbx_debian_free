#!/bin/bash

# =============================================================================
# check-system.sh – Диагност и разведчик для FreePBX 17
# Версия: 7.0.0
# =============================================================================

# =============================================================================
# ОГЛАВЛЕНИЕ:
#   1.  check_os               – Debian 12, архитектура amd64
#   2.  check_permissions      – права на запись в /usr/src, /tmp
#   3.  check_disk_space       – свободное место в /usr/src (≥5 ГБ)
#   4.  check_internet         – доступ к deb.debian.org, DNS
#   5.  check_ports            – порты 80 и 3306 свободны?
#   6.  check_apt              – наличие apt-get и его работа
#   7.  check_conflicts        – нет уже установленных FreePBX/Asterisk/MySQL
#   8.  check_hostname         – hostname не localhost и корректный
#   9.  check_russian_mirrors  – доступность зеркала Яндекса
#  10.  check_repo_sangoma     – доступность репозитория Sangoma (бинарный Asterisk)
#  11.  check_freepbx_binary   – доступность бинарного пакета FreePBX (deb) на GitHub
#  12.  check_freepbx_source   – доступность исходного кода FreePBX core на GitHub
#  13.  check_asterisk_source  – доступность исходного кода Asterisk на GitHub
#  14.  check_php_ioncube      – проверка PHP 8.2 и ionCube (для FreePBX)
#  15.  check_freepbx_readiness – комбинация проверок для FreePBX
#  16.  RUN_CRITICAL           – набор критических проверок (1-4,6)
#  17.  RUN_NETWORK            – набор сетевых проверок (4)
#  18.  RUN_REPOSITORIES       – набор проверок репозиториев (9,10)
#  19.  RUN_BINARIES_READY     – доступность бинарного пакета FreePBX (11)
#  20.  RUN_SOURCES_READY      – доступность исходников FreePBX и Asterisk (12,13)
#  21.  RUN_PREFLIGHT          – комбинация CRITICAL+NETWORK+REPOSITORIES+SOURCES_READY
#  22.  RUN_CHECK_BY_NAME      – диспетчер для вызова отдельных проверок
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Переменные и настройки
# -----------------------------------------------------------------------------
SCRIPT_VERSION="7.0.0"
QUIET=false
error_count=0
warn_count=0

# Версии для проверки (меняйте здесь)
FREEPBX_CORE_VERSION="17.0.18.45"
ASTERISK_VERSION="22.9.0"

# URL для проверок
FREEPBX_DEB_URL="https://github.com/FreePBX/deb-repository/releases/download/${FREEPBX_CORE_VERSION}/freepbx_${FREEPBX_CORE_VERSION}_amd64.deb"
FREEPBX_SOURCE_URL="https://github.com/FreePBX/core/archive/refs/tags/release/${FREEPBX_CORE_VERSION}.tar.gz"
ASTERISK_SOURCE_URL="https://github.com/asterisk/asterisk/releases/download/${ASTERISK_VERSION}/asterisk-${ASTERISK_VERSION}.tar.gz"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Вспомогательные функции вывода
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Универсальный запуск проверки с выводом текущего шага
# -----------------------------------------------------------------------------
run_check() {
    local name="$1"
    local func="$2"
    log_message "   ${BLUE}▶ ${name}${NC}"
    "$func"
    local code=$?
    if [ $code -ne 0 ]; then
        log_message "   ${RED}✗ ${name} завершилась с ошибкой (код $code)${NC}"
    fi
    return $code
}

# -----------------------------------------------------------------------------
# 1. Проверка операционной системы
# -----------------------------------------------------------------------------
check_os() {
    if [ ! -f /etc/os-release ]; then
        log_error "Не найден /etc/os-release"
        return 1
    fi
    . /etc/os-release
    if [ "$ID" != "debian" ] || [ "$VERSION_CODENAME" != "bookworm" ]; then
        log_error "Требуется Debian 12 (bookworm). Обнаружено: $PRETTY_NAME"
        return 1
    fi
    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" != "amd64" ]; then
        log_error "Архитектура $ARCH не поддерживается. Требуется amd64."
        return 1
    fi
    log_success "ОС: $PRETTY_NAME, архитектура: amd64"
    return 0
}

# -----------------------------------------------------------------------------
# 2. Проверка прав на запись
# -----------------------------------------------------------------------------
check_permissions() {
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
    $ok && return 0 || return 2
}

# -----------------------------------------------------------------------------
# 3. Проверка свободного места
# -----------------------------------------------------------------------------
check_disk_space() {
    FREE_SPACE=$(df /usr/src | awk 'NR==2 {print $4}')
    if [ $FREE_SPACE -lt 5242880 ]; then
        log_error "Недостаточно места в /usr/src: $((FREE_SPACE / 1024)) МБ (нужно ≥5 ГБ)"
        return 3
    else
        log_success "Свободное место в /usr/src: $((FREE_SPACE / 1024)) МБ"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# 4. Проверка интернета и DNS
# -----------------------------------------------------------------------------
check_internet() {
    if curl -s --connect-timeout 5 https://deb.debian.org > /dev/null 2>&1; then
        log_success "Интернет доступен (deb.debian.org)"
    else
        log_error "Нет доступа к deb.debian.org (проверьте сеть)"
        return 10
    fi
    if ping -c 1 github.com > /dev/null 2>&1; then
        log_success "DNS работает (github.com разрешается)"
    else
        log_warning "GitHub может быть недоступен (проверьте DNS)"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 5. Проверка портов 80 и 3306
# -----------------------------------------------------------------------------
check_ports() {
    local problem=false
    if ss -tlnp | grep -q ':80 '; then
        log_warning "Порт 80 уже занят. Возможен конфликт с веб-сервером."
        problem=true
    else
        log_success "Порт 80 свободен"
    fi
    if ss -tlnp | grep -q ':3306 '; then
        log_warning "Порт 3306 уже занят. Возможен конфликт с MySQL."
        problem=true
    else
        log_success "Порт 3306 свободен"
    fi
    $problem && return 40 || return 0
}

# -----------------------------------------------------------------------------
# 6. Проверка apt
# -----------------------------------------------------------------------------
check_apt() {
    if ! command -v apt-get > /dev/null 2>&1; then
        log_error "apt-get не найден. Это не Debian/Ubuntu?"
        return 30
    fi
    if ! apt-get update --dry-run > /dev/null 2>&1; then
        log_warning "apt-get update --dry-run не удался (возможно, проблемы с сетью или репозиториями)"
    fi
    log_success "apt-get доступен"
    return 0
}

# -----------------------------------------------------------------------------
# 7. Проверка конфликтующих компонентов
# -----------------------------------------------------------------------------
check_conflicts() {
    local problem=false
    if command -v asterisk > /dev/null 2>&1; then
        log_warning "Asterisk уже установлен. Возможны конфликты."
        problem=true
    fi
    if command -v fwconsole > /dev/null 2>&1; then
        log_warning "FreePBX уже установлен. Возможны конфликты."
        problem=true
    fi
    if systemctl is-active --quiet mariadb 2>/dev/null; then
        log_warning "MySQL/MariaDB уже запущен. Возможны конфликты."
        problem=true
    fi
    $problem && return 31 || return 0
}

# -----------------------------------------------------------------------------
# 8. Проверка hostname
# -----------------------------------------------------------------------------
check_hostname() {
    HOST=$(hostname)
    if [ "$HOST" = "localhost" ] || [ "$HOST" = "localhost.localdomain" ]; then
        log_warning "Hostname установлен как localhost. Рекомендуется изменить на уникальное имя."
        return 9
    elif [[ "$HOST" =~ [[:space:]] ]]; then
        log_warning "Hostname содержит пробелы или спецсимволы: '$HOST'"
        return 9
    else
        log_success "Hostname: $HOST"
        return 0
    fi
}

# -----------------------------------------------------------------------------
# 9. Проверка российских зеркал
# -----------------------------------------------------------------------------
check_russian_mirrors() {
    if curl -s --connect-timeout 5 https://mirror.yandex.ru/debian/ > /dev/null 2>&1; then
        log_success "Зеркало Яндекса (mirror.yandex.ru) доступно"
        return 0
    else
        log_warning "Зеркало Яндекса недоступно – скрипт переключится на официальные репозитории"
        return 20
    fi
}

# -----------------------------------------------------------------------------
# 10. Проверка доступности репозитория Sangoma (бинарный Asterisk)
# -----------------------------------------------------------------------------
check_repo_sangoma() {
    if curl -s --connect-timeout 5 http://deb.freepbx.org > /dev/null 2>&1; then
        log_success "Репозиторий Sangoma (deb.freepbx.org) доступен"
        return 0
    else
        log_warning "Репозиторий Sangoma недоступен – установка бинарного Asterisk невозможна"
        return 21
    fi
}

# -----------------------------------------------------------------------------
# 11. Проверка доступности бинарного пакета FreePBX (deb) на GitHub
# -----------------------------------------------------------------------------
check_freepbx_binary() {
    local http_code
    http_code=$(curl -s --head --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "$FREEPBX_DEB_URL")
    if [ "$http_code" = "200" ]; then
        log_success "Бинарный пакет FreePBX $FREEPBX_CORE_VERSION доступен (deb)"
        return 0
    else
        log_warning "Бинарный пакет FreePBX недоступен (HTTP $http_code)"
        return 25
    fi
}

# -----------------------------------------------------------------------------
# 12. Проверка доступности исходного кода FreePBX core на GitHub
# -----------------------------------------------------------------------------
check_freepbx_source() {
    local http_code
    http_code=$(curl -s --head --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "$FREEPBX_SOURCE_URL")
    if [ "$http_code" = "200" ]; then
        log_success "Исходный код FreePBX core $FREEPBX_CORE_VERSION доступен"
        return 0
    else
        log_error "Исходный код FreePBX core недоступен (HTTP $http_code)"
        return 24
    fi
}

# -----------------------------------------------------------------------------
# 13. Проверка доступности исходного кода Asterisk на GitHub
# -----------------------------------------------------------------------------
check_asterisk_source() {
    local http_code
    http_code=$(curl -s --head --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" "$ASTERISK_SOURCE_URL")
    if [ "$http_code" = "200" ]; then
        log_success "Исходный код Asterisk $ASTERISK_VERSION доступен"
        return 0
    else
        log_error "Исходный код Asterisk недоступен (HTTP $http_code)"
        return 27
    fi
}

# -----------------------------------------------------------------------------
# 14. Проверка PHP 8.2 и ionCube (для FreePBX)
# -----------------------------------------------------------------------------
check_php_ioncube() {
    local ok=true
    if ! command -v php > /dev/null 2>&1; then
        log_error "PHP не установлен"
        ok=false
    else
        PHP_VERSION=$(php -v | head -1 | grep -oP 'PHP \K[0-9.]+')
        if [[ "$PHP_VERSION" != 8.2* ]]; then
            log_error "PHP версия $PHP_VERSION, требуется 8.2.x"
            ok=false
        else
            log_success "PHP версия $PHP_VERSION"
        fi
    fi
    log_warning "ionCube Loader не проверяется (требуется только для коммерческих модулей)"
    $ok && return 0 || return 70
}

# -----------------------------------------------------------------------------
# 15. Комплексная проверка готовности к установке FreePBX
# -----------------------------------------------------------------------------
check_freepbx_readiness() {
    run_check "CHECK_REPO_SANGOMA"     check_repo_sangoma     || return $?
    run_check "CHECK_FREEPBX_BINARY"   check_freepbx_binary   || true
    run_check "CHECK_FREEPBX_SOURCE"   check_freepbx_source   || return $?
    run_check "CHECK_ASTERISK_SOURCE"  check_asterisk_source  || return $?
    run_check "CHECK_PHP_IONCUBE"      check_php_ioncube      || return $?
    run_check "CHECK_APT"              check_apt              || return $?
    run_check "CHECK_INTERNET"         check_internet         || return $?
    return 0
}

# -----------------------------------------------------------------------------
# Наборы проверок (мега-функции)
# -----------------------------------------------------------------------------
RUN_CRITICAL() {
    run_check "CHECK_OS"            check_os            || return $?
    run_check "CHECK_PERMISSIONS"   check_permissions   || return $?
    run_check "CHECK_DISK_SPACE"    check_disk_space    || return $?
    run_check "CHECK_INTERNET"      check_internet      || return $?
    run_check "CHECK_APT"           check_apt           || return $?
    return 0
}

RUN_NETWORK() {
    run_check "CHECK_INTERNET" check_internet || return $?
    return 0
}

RUN_REPOSITORIES() {
    run_check "CHECK_RUSSIAN_MIRRORS" check_russian_mirrors || return $?
    run_check "CHECK_REPO_SANGOMA"    check_repo_sangoma    || return $?
    return 0
}

RUN_BINARIES_READY() {
    run_check "CHECK_FREEPBX_BINARY" check_freepbx_binary || return $?
    return 0
}

RUN_SOURCES_READY() {
    run_check "CHECK_FREEPBX_SOURCE"  check_freepbx_source  || return $?
    run_check "CHECK_ASTERISK_SOURCE" check_asterisk_source || return $?
    return 0
}

RUN_PREFLIGHT() {
    RUN_CRITICAL      || return $?
    RUN_NETWORK       || return $?
    RUN_REPOSITORIES  || return $?
    RUN_SOURCES_READY || return $?
    return 0
}

# -----------------------------------------------------------------------------
# Диспетчер: вызов конкретной проверки по имени
# -----------------------------------------------------------------------------
run_check_by_name() {
    local name="$1"
    case "$name" in
        CHECK_OS)                   check_os ;;
        CHECK_PERMISSIONS)          check_permissions ;;
        CHECK_DISK_SPACE)           check_disk_space ;;
        CHECK_INTERNET)             check_internet ;;
        CHECK_PORTS)                check_ports ;;
        CHECK_APT)                  check_apt ;;
        CHECK_CONFLICTS)            check_conflicts ;;
        CHECK_HOSTNAME)             check_hostname ;;
        CHECK_RUSSIAN_MIRRORS)      check_russian_mirrors ;;
        CHECK_REPO_SANGOMA)         check_repo_sangoma ;;
        CHECK_FREEPBX_BINARY)       check_freepbx_binary ;;
        CHECK_FREEPBX_SOURCE)       check_freepbx_source ;;
        CHECK_ASTERISK_SOURCE)      check_asterisk_source ;;
        CHECK_PHP_IONCUBE)          check_php_ioncube ;;
        CHECK_FREEPBX_READINESS)    check_freepbx_readiness ;;
        RUN_CRITICAL)               RUN_CRITICAL ;;
        RUN_NETWORK)                RUN_NETWORK ;;
        RUN_REPOSITORIES)           RUN_REPOSITORIES ;;
        RUN_BINARIES_READY)         RUN_BINARIES_READY ;;
        RUN_SOURCES_READY)          RUN_SOURCES_READY ;;
        RUN_PREFLIGHT)              RUN_PREFLIGHT ;;
        *)
            echo "Неизвестная проверка: $name"
            exit 0
            ;;
    esac
    local code=$?
    exit $code
}

# -----------------------------------------------------------------------------
# MAIN: обработка аргументов
# -----------------------------------------------------------------------------
for arg in "$@"; do
    case $arg in
        --quiet) QUIET=true ;;
    esac
done

ARGS=()
for arg in "$@"; do
    if [[ "$arg" != "--quiet" ]]; then
        ARGS+=("$arg")
    fi
done

if [ ${#ARGS[@]} -eq 0 ]; then
    RUN_PREFLIGHT
    exit $?
elif [ ${#ARGS[@]} -eq 1 ] && [ "${ARGS[0]}" = "--check" ]; then
    echo "Ошибка: после --check нужно указать имя проверки"
    exit 0
elif [ ${#ARGS[@]} -eq 2 ] && [ "${ARGS[0]}" = "--check" ]; then
    run_check_by_name "${ARGS[1]}"
else
    echo "Использование: check-system.sh [--quiet] [--check ИМЯ]"
    exit 0
fi
