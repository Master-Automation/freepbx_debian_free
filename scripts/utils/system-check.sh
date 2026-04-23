#!/bin/bash
# ======================================================================================
# Скрипт: system-check.sh
# Описание: Проверка системы перед установкой Asterisk/FreePBX
# Версия: 2.0
# Дата: 2026-04-23
# Автор: Master Automation
# ======================================================================================
#
# Содержание:
#   1.  check_os               - Проверка версии ОС (Debian 12)
#   2.  check_ram              - Проверка оперативной памяти (минимум 2 ГБ)
#   3.  check_swap             - Проверка наличия и активности swap
#   4.  check_selinux          - Проверка, отключён ли SELinux
#   5.  check_apache_mod_rewrite - Проверка доступности модуля Apache mod_rewrite
#   6.  check_filesystem       - Проверка типа файловой системы (рекомендуется ext4/xfs)
#   7.  check_kernel_version   - Проверка версии ядра (нужно >= 2.6.25)
#   8.  check_internet         - Проверка доступа в интернет
#   9.  check_ports            - Проверка занятости портов (5060, 80, 443, 3306)
#   10. check_pkg_conflicts    - Проверка конфликтующих пакетов
#  11. check_disk_space       - Проверка свободного места на диске (>= 5 ГБ)
#  12. check_write_permissions - Проверка прав на запись в каталоги
#  13. check_hostname         - Проверка корректности hostname
#  14. check_time_sync        - Проверка синхронизации времени (NTP)
#  15. check_static_ip        - Проверка статического IP-адреса
#  16. check_locale           - Проверка системной локали
#  17. check_system_updates    - Проверка наличия обновлений системы
#  18. check_all              - Групповая проверка (запуск всех вышеперечисленных)
#
# Использование:
#   ./system-check.sh            - вывод справки
#   ./system-check.sh check_all  - запустить все проверки
#   ./system-check.sh check_ram  - запустить только проверку RAM
# ======================================================================================

set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_fail()  { echo -e "${RED}[FAIL]${NC} $1"; }

# --------------------------------------------------------------------------------------
# 1. Проверка версии ОС (Debian 12)
check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "debian" && "$VERSION_ID" == "12" ]]; then
            print_ok "ОС: Debian 12 (Bookworm)"
            return 0
        fi
    fi
    print_fail "Требуется Debian 12 (Bookworm). Текущая ОС: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    return 1
}

# --------------------------------------------------------------------------------------
# 2. Проверка оперативной памяти (минимум 2 ГБ)
check_ram() {
    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_total_gb=$((mem_total_kb / 1024 / 1024))
    if [[ $mem_total_gb -ge 2 ]]; then
        print_ok "Оперативная память: ${mem_total_gb} ГБ (минимум 2 ГБ)"
        if [[ $mem_total_gb -lt 4 ]]; then
            print_warn "Рекомендуется 4 ГБ и более для стабильной работы FreePBX"
        fi
        return 0
    else
        print_fail "Оперативная память: ${mem_total_gb} ГБ (требуется не менее 2 ГБ)"
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 3. Проверка наличия и активности swap
check_swap() {
    local swap_total=$(swapon --show --noheadings | wc -l)
    local swap_size=$(free -m | awk '/Swap:/ {print $2}')
    if [[ $swap_total -gt 0 && $swap_size -gt 0 ]]; then
        print_ok "Swap включён, размер: ${swap_size} МБ"
        return 0
    else
        print_fail "Swap не найден или не активен. Рекомендуется создать swap (например, 2 ГБ)"
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 4. Проверка, отключён ли SELinux
check_selinux() {
    if command -v getenforce &>/dev/null; then
        local selinux_status=$(getenforce)
        if [[ "$selinux_status" == "Disabled" ]]; then
            print_ok "SELinux отключён"
            return 0
        else
            print_fail "SELinux включён (статус: $selinux_status). Отключите SELinux перед установкой."
            return 1
        fi
    else
        # SELinux не установлен, считаем OK
        print_ok "SELinux не установлен (или не используется)"
        return 0
    fi
}

# --------------------------------------------------------------------------------------
# 5. Проверка доступности модуля Apache mod_rewrite
check_apache_mod_rewrite() {
    if ! command -v apache2ctl &>/dev/null; then
        print_warn "Apache не установлен, проверка mod_rewrite пропущена"
        return 0
    fi
    if apache2ctl -M 2>/dev/null | grep -q rewrite_module; then
        print_ok "Apache mod_rewrite включён"
        return 0
    else
        print_fail "Apache mod_rewrite не включён. Выполните: sudo a2enmod rewrite && sudo systemctl restart apache2"
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 6. Проверка типа файловой системы (рекомендуется ext4/xfs)
check_filesystem() {
    # Проверяем точку монтирования, где находится /var/lib/asterisk (или /)
    local mount_point="/"
    if [[ -d "/var/lib/asterisk" ]]; then
        mount_point="/var/lib/asterisk"
    fi
    local fstype=$(df -T "$mount_point" | awk 'NR==2 {print $2}')
    if [[ "$fstype" == "ext4" || "$fstype" == "xfs" ]]; then
        print_ok "Файловая система для $mount_point: $fstype (рекомендуется)"
    else
        print_warn "Файловая система для $mount_point: $fstype. Рекомендуется ext4 или xfs для лучшей производительности"
    fi
    return 0
}

# --------------------------------------------------------------------------------------
# 7. Проверка версии ядра Linux (минимальная 2.6.25)
check_kernel_version() {
    local kernel_version=$(uname -r | cut -d- -f1)
    local major=$(echo "$kernel_version" | cut -d. -f1)
    local minor=$(echo "$kernel_version" | cut -d. -f2)
    local patch=$(echo "$kernel_version" | cut -d. -f3 | sed 's/[^0-9].*//')
    # Сравниваем с 2.6.25
    if [[ $major -gt 2 ]] || \
       [[ $major -eq 2 && $minor -gt 6 ]] || \
       [[ $major -eq 2 && $minor -eq 6 && $patch -ge 25 ]]; then
        print_ok "Версия ядра: $kernel_version (>= 2.6.25)"
        return 0
    else
        print_fail "Версия ядра: $kernel_version (требуется 2.6.25 или новее)"
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 8. Проверка доступа в интернет
check_internet() {
    if ping -c 1 8.8.8.8 &>/dev/null; then
        print_ok "Есть доступ в интернет"
        return 0
    else
        print_fail "Нет доступа в интернет (не пингуется 8.8.8.8)"
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 9. Проверка занятости портов (5060, 80, 443, 3306)
check_ports() {
    local ports=(5060 80 443 3306)
    local occupied=()
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            occupied+=($port)
        fi
    done
    if [[ ${#occupied[@]} -eq 0 ]]; then
        print_ok "Все необходимые порты свободны (5060,80,443,3306)"
        return 0
    else
        print_fail "Заняты порты: ${occupied[*]}. Освободите их перед установкой."
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 10. Проверка конфликтующих пакетов
check_pkg_conflicts() {
    local conflict_pkgs=(asterisk freepbx mariadb-server mysql-server apache2 php5)
    local found=()
    for pkg in "${conflict_pkgs[@]}"; do
        if dpkg -l | grep -qw "^ii.*$pkg"; then
            found+=($pkg)
        fi
    done
    if [[ ${#found[@]} -eq 0 ]]; then
        print_ok "Конфликтующие пакеты не обнаружены"
        return 0
    else
        print_fail "Обнаружены конфликтующие пакеты: ${found[*]}. Удалите их."
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 11. Проверка свободного места на диске (>= 5 ГБ)
check_disk_space() {
    local avail_kb=$(df / --output=avail | tail -n1)
    local avail_gb=$((avail_kb / 1024 / 1024))
    if [[ $avail_gb -ge 5 ]]; then
        print_ok "Свободного места на диске: ${avail_gb} ГБ (минимум 5 ГБ)"
        return 0
    else
        print_fail "Свободного места на диске: ${avail_gb} ГБ (требуется минимум 5 ГБ)"
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# 12. Проверка прав на запись в каталоги
check_write_permissions() {
    local dirs=("/etc/asterisk" "/var/lib/asterisk" "/var/log/asterisk" "/var/run/asterisk")
    local ok=true
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            if [[ -w "$dir" ]]; then
                print_ok "Права на запись в $dir есть"
            else
                print_fail "Нет прав на запись в $dir"
                ok=false
            fi
        else
            # Каталог не существует - проверяем родительский
            local parent=$(dirname "$dir")
            if [[ -w "$parent" ]]; then
                print_ok "Каталог $dir будет создан (родитель $parent доступен)"
            else
                print_fail "Нет прав на создание $dir (родитель $parent недоступен)"
                ok=false
            fi
        fi
    done
    $ok && return 0 || return 1
}

# --------------------------------------------------------------------------------------
# 13. Проверка корректности hostname
check_hostname() {
    local host=$(hostname -f 2>/dev/null || hostname)
    if [[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] && [[ ! "$host" =~ localhost$ ]]; then
        print_ok "Hostname: $host"
        return 0
    else
        print_warn "Hostname = $host. Рекомендуется использовать FQDN (не localhost)"
        return 0
    fi
}

# --------------------------------------------------------------------------------------
# 14. Проверка синхронизации времени (NTP)
check_time_sync() {
    if timedatectl status 2>/dev/null | grep -q "System clock synchronized: yes"; then
        print_ok "Время синхронизировано (NTP работает)"
        return 0
    elif command -v chronyc &>/dev/null && chronyc tracking &>/dev/null; then
        print_ok "Время синхронизировано (chrony)"
        return 0
    elif command -v ntpq &>/dev/null && ntpq -p &>/dev/null; then
        print_ok "Время синхронизировано (ntpd)"
        return 0
    else
        print_warn "Время не синхронизировано. Установите NTP (chrony) для корректной работы SIP"
        return 0
    fi
}

# --------------------------------------------------------------------------------------
# 15. Проверка статического IP-адреса
check_static_ip() {
    # Проверяем, что интерфейс не использует DHCP (упрощённо)
    if ip route | grep -q "default via" && ! systemctl is-active --quiet networking; then
        # Если networking не активен, возможно systemd-networkd
        print_warn "Проверка статического IP: рекомендуется статический IP, убедитесь вручную"
        return 0
    else
        # Более точная проверка: смотрим конфиги
        if grep -rq "dhcp" /etc/network/interfaces* 2>/dev/null; then
            print_warn "Обнаружена настройка DHCP. Рекомендуется использовать статический IP."
        else
            print_ok "Скорее всего, статический IP настроен"
        fi
        return 0
    fi
}

# --------------------------------------------------------------------------------------
# 16. Проверка системной локали
check_locale() {
    if locale -a | grep -q "ru_RU.utf8\|en_US.utf8" && locale | grep -q "UTF-8"; then
        print_ok "Локаль UTF-8 настроена"
        return 0
    else
        print_warn "Локаль может быть некорректной. Рекомендуется: sudo locale-gen ru_RU.UTF-8 en_US.UTF-8 && sudo update-locale"
        return 0
    fi
}

# --------------------------------------------------------------------------------------
# 17. Проверка наличия обновлений системы
check_system_updates() {
    apt-get update 2>&1 | grep -v "W:" >/dev/null
    local updates=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0)
    if [[ $updates -eq 0 ]]; then
        print_ok "Система обновлена"
        return 0
    else
        print_warn "Доступно $updates обновлений. Рекомендуется выполнить apt upgrade перед установкой"
        return 0
    fi
}

# --------------------------------------------------------------------------------------
# 18. Групповая проверка (запуск всех)
check_all() {
    local failed=0
    local tests=(
        check_os
        check_ram
        check_swap
        check_selinux
        check_apache_mod_rewrite
        check_filesystem
        check_kernel_version
        check_internet
        check_ports
        check_pkg_conflicts
        check_disk_space
        check_write_permissions
        check_hostname
        check_time_sync
        check_static_ip
        check_locale
        check_system_updates
    )
    for test in "${tests[@]}"; do
        if ! $test; then
            ((failed++))
        fi
        echo "--------------------------------------------------"
    done

    if [[ $failed -eq 0 ]]; then
        echo -e "\n${GREEN}Все проверки пройдены успешно. Система готова к установке.${NC}"
        return 0
    else
        echo -e "\n${RED}Количество неудачных проверок: $failed. Исправьте ошибки перед установкой.${NC}"
        return 1
    fi
}

# --------------------------------------------------------------------------------------
# Основной блок: разбор аргументов
if [[ $# -eq 0 ]]; then
    echo "Использование: $0 {check_all|check_os|check_ram|...}"
    echo "Доступные проверки:"
    grep -E "^check_[a-z_]+\(\)" "$0" | sed 's/()//' | sed 's/check_/  check_/'
    exit 0
fi

command=$1
if declare -f "$command" > /dev/null; then
    "$command"
else
    echo "Ошибка: неизвестная проверка '$command'"
    exit 1
fi
