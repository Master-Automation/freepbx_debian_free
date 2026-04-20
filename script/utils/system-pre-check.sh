#!/bin/bash
# ============================================================================
# check-system.sh – Модуль проверок системы для FreePBX 17
# Версия: 2.0.0
# ============================================================================
# ОГЛАВЛЕНИЕ:
#   1.  CHECK_OS            – проверка Debian 12 и архитектуры
#   2.  CHECK_PERMISSIONS   – права на запись в /usr/src, /tmp
#   3.  CHECK_DISK_SPACE    – свободное место в /usr/src (≥5 ГБ)
#   4.  CHECK_INTERNET      – доступ к deb.debian.org и DNS
#   5.  CHECK_PORTS         – порты 80 и 3306 свободны?
#   6.  CHECK_APT           – наличие apt-get и его работа
#   7.  CHECK_CONFLICTS     – нет уже установленных FreePBX/Asterisk/MySQL
#   8.  CHECK_HOSTNAME      – hostname не localhost и не содержит пробелов
#   9.  CHECK_RUSSIAN_MIRRORS – доступность зеркал (Яндекс, git.freepbx...)
#  10.  CHECK_FILES         – целостность russian.sh (опционально)
#  11.  RUN_ALL_CHECKS      – запуск всех проверок (интерактивный режим)
#  12.  RUN_CHECK_BY_NAME    – запуск конкретной проверки по имени (для внешних вызовов)
# ============================================================================

# Инициализация (цвета, счётчики) – аналогично предыдущей версии
# ... (код цветов и базовых функций)

# ----------------------------------------------------------------------------
# 1. CHECK_OS
# ----------------------------------------------------------------------------
check_os() {
    local name="CHECK_OS"
    log_message "${BLUE}[$name] Проверка операционной системы...${NC}"
    # ... проверка Debian 12, архитектуры
    # возвращает 0 если ок, 1 если ошибка
}

# ----------------------------------------------------------------------------
# 2. CHECK_PERMISSIONS
# ----------------------------------------------------------------------------
check_permissions() {
    local name="CHECK_PERMISSIONS"
    log_message "${BLUE}[$name] Проверка прав на запись...${NC}"
    # ...
}

# ... аналогично для остальных проверок

# ----------------------------------------------------------------------------
# 11. RUN_ALL_CHECKS – интерактивный режим
# ----------------------------------------------------------------------------
run_all_checks() {
    # вызывает все check_* по порядку, выводит итог, спрашивает продолжать
}

# ----------------------------------------------------------------------------
# 12. RUN_CHECK_BY_NAME – для внешних вызовов по имени
# ----------------------------------------------------------------------------
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
        *) echo "Неизвестная проверка: $check_name"; exit 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# MAIN: диспетчер аргументов
# ----------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    run_all_checks
elif [ "$1" = "--quiet" ]; then
    QUIET=true
    run_all_checks
elif [ "$1" = "--check" ] && [ -n "$2" ]; then
    run_check_by_name "$2"
else
    echo "Использование:"
    echo "  check-system.sh                     # интерактивный режим"
    echo "  check-system.sh --quiet             # тихий режим (без вопросов)"
    echo "  check-system.sh --check CHECK_NAME  # запустить конкретную проверку"
    exit 1
fi