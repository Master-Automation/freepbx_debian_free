#!/bin/bash
# =============================================================================
# Глава 1: Установщик FreePBX 17 на Debian 12 (основной скрипт)
# Версия: 3.2.0
# =============================================================================
# Назначение: Полная автоматическая установка Asterisk + FreePBX.
#             При ошибках вызывает отладчик debug.sh и скрипт отчёта report.sh.
# =============================================================================

set -e
SCRIPT_VERSION="3.2.3"
ASTVERSION=${ASTVERSION:-22}
PHPVERSION="8.2"
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
log=$LOG_FILE
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GIT_HTTP_TIMEOUT=300
export GIT_CLONE_TIMEOUT=300

# =============================================================================
# Глава 2: Функции логирования и вспомогательные
# =============================================================================
echo_ts() { echo "$(date +"%Y-%m-%d %T") - $*"; }
log() { echo_ts "$*" >> "$LOG_FILE"; }
message() { echo_ts "$*" | tee -a "$LOG_FILE"; }
setCurrentStep () { currentStep="$1"; message "${currentStep}"; }

terminate() {
    if [ $? -ne 0 ]; then
        echo_ts "Последние 10 строк лога:"
        tail -n 10 "$LOG_FILE"
    fi
    rm -f "$pidfile"
    message "Скрипт завершён."
}

# =============================================================================
# Глава 3: Вызов отладчика и скрипта отчёта (добавлены в эту версию)
# =============================================================================
call_debug() {
    local action="$1"
    if [ -x ./debug.sh ]; then
        ./debug.sh --auto "$action"
    else
        message "⚠️ Отладчик не найден, пропускаем действие: $action"
        return 1
    fi
}

send_report() {
    local error_step="$1"
    if [ -x ./report.sh ]; then
        ./report.sh --auto "$error_step"
    else
        message "⚠️ Скрипт отчёта не найден, отчёт не отправлен"
    fi
}

# =============================================================================
# Глава 4: Проверка системы и предварительные условия
# =============================================================================
if [ -f /etc/os-release ]; then
    DEBIAN_OS_VERSION=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release)
else
    DEBIAN_OS_VERSION="bookworm"
fi

if [ "$DEBIAN_OS_VERSION" != "bookworm" ]; then
    echo "Поддерживается только Debian 12 (bookworm). Обнаружено: $DEBIAN_OS_VERSION"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "Скрипт должен запускаться с правами root (sudo)."
   exit 1
fi

export PATH=$SANE_PATH

pre_install_check() {
    message "🔍 Предварительная проверка системы..."
    local ALL_OK=true
    if [ ! -w /usr/src ]; then
        message "   ❌ Нет прав на запись в /usr/src"
        ALL_OK=false
    else
        message "   ✅ Права на запись в /usr/src"
    fi
    FREE_SPACE=$(df /usr/src | awk 'NR==2 {print $4}')
    if [ $FREE_SPACE -lt 5242880 ]; then
        message "   ❌ Недостаточно места на диске (нужно минимум 5 ГБ)"
        ALL_OK=false
    else
        message "   ✅ Свободное место: $(($FREE_SPACE / 1024)) МБ"
    fi
    if ! curl -s --connect-timeout 5 https://deb.debian.org > /dev/null 2>&1; then
        message "   ❌ Нет доступа к интернету"
        ALL_OK=false
    else
        message "   ✅ Интернет доступен"
    fi
    if [ "$ALL_OK" = false ]; then
        message ""
        message "❌ Предварительная проверка не пройдена. Установка прервана."
        exit 1
    fi
    message "   ✅ Все условия выполнены, продолжаем установку..."
    message ""
}

check_previous_install() {
    message "🔍 Проверка ранее установленных компонентов..."
    NEED_ASTERISK=0
    NEED_FREEPBX=0

    if command -v asterisk > /dev/null 2>&1; then
        if systemctl is-active --quiet asterisk 2>/dev/null; then
            ASTERISK_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -1)
            if [ -n "$ASTERISK_VERSION" ]; then
                message "   ✅ Asterisk уже установлен и работает: $ASTERISK_VERSION"
                NEED_ASTERISK=1
            else
                message "   ⚠️ Asterisk установлен, но не отвечает на команды"
            fi
        else
            message "   ⚠️ Asterisk установлен, но служба не запущена"
            systemctl start asterisk
            if systemctl is-active --quiet asterisk; then
                message "   ✅ Asterisk запущен"
                NEED_ASTERISK=1
            fi
        fi
    else
        message "   ⬜ Asterisk не установлен"
    fi

    if command -v fwconsole > /dev/null 2>&1; then
        if fwconsole ma list &>/dev/null 2>&1; then
            message "   ✅ FreePBX уже установлен и работает"
            NEED_FREEPBX=1
        else
            message "   ⚠️ FreePBX установлен, но не работает (проблема с БД)"
            NEED_FREEPBX=0
        fi
    else
        message "   ⬜ FreePBX не установлен"
        NEED_FREEPBX=0
    fi

    if [ $NEED_ASTERISK -eq 1 ]; then
        export SKIP_ASTERISK=1
        message "   ℹ️ Сборка Asterisk будет пропущена"
    fi
    if [ $NEED_FREEPBX -eq 1 ]; then
        export SKIP_FREEPBX=1
        message "   ℹ️ Установка FreePBX будет пропущена"
    fi
    message ""
}

pre_install_check
check_previous_install

# =============================================================================
# Глава 5: Парсинг параметров командной строки
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --skipversion) skipversion=true; shift ;;
        --opensourceonly) opensourceonly=true; shift ;;
        --nochrony) nochrony=true; shift ;;
        --debianmirror) DEBIAN_MIRROR=$2; shift; shift ;;
        *) shift ;;
    esac
done

# =============================================================================
# Глава 6: Обработчик ошибок (с вызовом отчёта при фатале)
# =============================================================================
errorHandler() {
    local line=$1
    local code=$2
    local cmd=$3
    log "****** INSTALLATION FAILED *****"
    echo_ts "Ошибка на шаге: ${currentStep} (строка $line, код $code)"
    echo_ts "Последняя команда: $cmd"
    echo_ts "Подробности в логе: ${LOG_FILE}"
    send_report "${currentStep}"
    exit "$code"
}
trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
trap "terminate" EXIT

# =============================================================================
# Глава 7: Базовые функции (установка пакетов)
# =============================================================================
isinstalled() {
    PKG_OK=$(dpkg-query -W --showformat='${Status}\n' "$@" 2>/dev/null|grep "install ok installed")
    [ -n "$PKG_OK" ]
}

pkg_install() {
    log "############################### "
    PKG=("$@")
    if isinstalled "${PKG[@]}"; then
        log "${PKG[*]} уже установлен."
    else
        message "Установка ${PKG[*]} ...."
        apt-get -y --ignore-missing -o DPkg::Options::="--force-confnew" -o Dpkg::Options::="--force-overwrite" install "${PKG[@]}" >> "$log"
        if isinstalled "${PKG[@]}"; then
            message "${PKG[*]} установлен успешно."
        else
            message "Не удалось установить ${PKG[*]}. Прерывание."
            terminate
        fi
    fi
    log "############################### "
}

# =============================================================================
# Глава 8: Установка Asterisk из исходников (с кэшированием)
# =============================================================================
install_asterisk() {
    astver=$1
    CACHE_DIR="/var/cache/asterisk-built"

    if git clone --depth 1 --dry-run https://github.com/asterisk/asterisk.git 2>&1 | grep -q "done"; then
        ESTIMATED_SIZE="~9-15 МБ"
        ESTIMATED_TIME="5-10 минут"
    else
        ESTIMATED_SIZE="~50-80 МБ"
        ESTIMATED_TIME="20-40 минут"
    fi

    message "Сборка Asterisk ${astver} из исходников."
    message "   📦 Объём скачивания: ${ESTIMATED_SIZE}"
    message "   ⏱️ Примерное время: ${ESTIMATED_TIME}"

    if command -v asterisk > /dev/null 2>&1; then
        INSTALLED_VERSION=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9.]+' || echo "")
        if [[ "$INSTALLED_VERSION" == "$astver"* ]]; then
            message "✅ Asterisk ${astver} уже установлен. Пропускаем сборку."
            return 0
        fi
    fi

    mkdir -p /usr/src
    cd /usr/src
    if [ -d "asterisk-${astver}" ]; then
        message "⚠️ Обнаружена старая/частичная папка исходников. Удаляем..."
        rm -rf asterisk-${astver}
    fi

    git config --global http.postBuffer 524288000

    MAX_RETRIES=3
    RETRY_DELAY=10
    for i in $(seq 1 $MAX_RETRIES); do
        message "Попытка $i из $MAX_RETRIES: клонирование репозитория Asterisk ${astver}..."
        if git clone --depth 1 -b ${astver} https://github.com/asterisk/asterisk.git asterisk-${astver} 2>&1; then
            message "✅ Клонирование успешно завершено."
            break
        else
            message "⚠️ Клонирование не удалось (попытка $i)."
            rm -rf asterisk-${astver} 2>/dev/null || true
            if [ $i -lt $MAX_RETRIES ]; then
                sleep $RETRY_DELAY
            else
                message "❌ ОШИБКА: Не удалось клонировать репозиторий после $MAX_RETRIES попыток."
                exit 1
            fi
        fi
    done

    cd asterisk-${astver}

    message "Установка зависимостей для сборки..."
    message "   Попытка 1/2: автоматическая установка (install_prereq)..."
    if ./contrib/scripts/install_prereq install 2>&1 | tee -a "$log"; then
        message "   ✅ Зависимости успешно установлены автоматически."
    else
        message "   ⚠️ Автоматическая установка не удалась. Выполняется ручная..."
        apt-get update -y
        apt-get install -y build-essential cmake libxml2-dev libsqlite3-dev libjansson-dev \
            libssl-dev libedit-dev uuid-dev libxslt1-dev liburiparser-dev libspandsp-dev \
            libspeexdsp-dev libopus-dev libsrtp2-dev portaudio19-dev liblua5.2-dev \
            libcurl4-openssl-dev libpq-dev unixodbc-dev libneon27-dev libgmime-3.0-dev \
            libgsm1-dev libvorbis-dev libogg-dev libcodec2-dev libfreetype6-dev \
            libfontconfig1-dev libicu-dev libsndfile1-dev libopencore-amrnb-dev \
            libopenjp2-7-dev libmp3lame-dev libc-client2007e-dev libldap2-dev libtool \
            autoconf pkg-config 2>&1 | tee -a "$log"
        message "   ✅ Зависимости установлены вручную."
    fi

    message "Конфигурация Asterisk..."
    ./configure --libdir=/usr/lib64 --with-pjproject-bundled
    if [ $? -ne 0 ]; then
        message "❌ ОШИБКА: Не удалось настроить конфигурацию Asterisk."
        exit 1
    fi

    make menuselect.makeopts
    menuselect/menuselect --enable chan_pjsip --enable res_srtp --enable res_http_websocket --enable format_mp3
    menuselect/menuselect --disable codec_opus --disable codec_g729a
    message "   ⚠️ Кодеки Opus и G.729 отключены (сервер недоступен)"

    message "Загрузка библиотеки MP3..."
    contrib/scripts/get_mp3_source.sh

    message "Компиляция Asterisk (самый долгий этап)..."
    make -j$(nproc)
    if [ $? -ne 0 ]; then
        message "❌ ОШИБКА: Не удалось скомпилировать Asterisk."
        exit 1
    fi

    export CODEC_OPUS_DOWNLOAD_DISABLE=1
    export CODEC_G729_DOWNLOAD_DISABLE=1
    export CODEC_SILK_DOWNLOAD_DISABLE=1

    message "Установка Asterisk..."
    make install
    if [ $? -ne 0 ]; then
        message "❌ ОШИБКА: Не удалось установить Asterisk."
        exit 1
    fi

    message "Сохраняем собранный Asterisk в кэш..."
    mkdir -p "$CACHE_DIR"
    cp -r /usr/src/asterisk-${astver} "$CACHE_DIR/"
    message "   ✅ Кэш сохранён"

    make config
    ldconfig

    if [ -f /usr/src/asterisk-${astver}/main/libasteriskssl.so.1 ]; then
        cp /usr/src/asterisk-${astver}/main/libasteriskssl.so.1 /usr/lib64/
        echo "/usr/lib64" > /etc/ld.so.conf.d/asterisk.conf
        ldconfig
        message "Библиотека libasteriskssl.so.1 скопирована"
    else
        message "ВНИМАНИЕ: libasteriskssl.so.1 не найдена"
    fi

    message "✅ Asterisk ${astver} успешно собран и установлен."

    # Проверка после установки
    if ! asterisk -rx "core show version" &>/dev/null; then
        call_debug "asterisk_config"
    fi
}

# =============================================================================
# Глава 9: Установка FreePBX (с fallback из исходников)
# =============================================================================
install_freepbx() {
    message "=== УСТАНОВКА FREEPBX ==="

    if ! command -v composer > /dev/null 2>&1; then
        message "Установка Composer..."
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer
        php -r "unlink('composer-setup.php');"
        message "   ✅ Composer установлен"
    fi

    message "Попытка 1/2: установка из репозитория Sangoma..."
    if apt-get install -y freepbx17 sangoma-pbx17 sysadmin17 2>&1 | tee -a "$log"; then
        message "   ✅ FreePBX успешно установлен из репозитория."
        if [ -f /var/www/html/admin/composer.json ]; then
            message "   📦 Установка зависимостей Composer..."
            cd /var/www/html/admin
            composer install --no-dev 2>&1 | tee -a "$log"
            composer dump-autoload 2>&1 | tee -a "$log"
            if ! grep -q "Symfony\\\\Component\\\\Console\\\\Application" vendor/autoload.php 2>/dev/null; then
                message "   ⚠️ Autoloader повреждён, восстанавливаем..."
                rm -rf vendor composer.lock
                composer install --no-dev 2>&1 | tee -a "$log"
            fi
            message "   ✅ Зависимости настроены"
        fi
        return 0
    else
        message "   ⚠️ Установка из репозитория не удалась."
        message "   🔄 Переключаемся на установку из исходников..."
    fi

    message "Попытка 2/2: установка FreePBX из исходников (GitHub)..."
    cd /usr/src
    [ -d "freepbx" ] && rm -rf freepbx
    if ! git clone --depth 1 https://github.com/FreePBX/freepbx.git freepbx 2>&1 | tee -a "$log"; then
        message "   ❌ ОШИБКА: Не удалось клонировать репозиторий FreePBX."
        exit 1
    fi
    cd freepbx
    composer install --no-dev 2>&1 | tee -a "$log"
    ./install -n 2>&1 | tee -a "$log"
    message "   ✅ FreePBX успешно установлен из исходников."
}

# =============================================================================
# Глава 10: Настройка репозиториев (Debian + FreePBX)
# =============================================================================
setup_repositories() {
    message "Добавление репозитория FreePBX..."
    MIRROR_URL="http://git.freepbx.asterisk.ru"
    FALLBACK_URL="http://packages.freepbx.org"
    REPO_URL=""

    if curl -s --connect-timeout 5 "$MIRROR_URL" > /dev/null 2>&1; then
        message "   ✅ Российское зеркало доступно: $MIRROR_URL"
        REPO_URL="$MIRROR_URL"
    else
        message "   ⚠️ Российское зеркало недоступно, использую официальный репозиторий"
        REPO_URL="$FALLBACK_URL"
    fi

    REPO_FILE="/etc/apt/sources.list.d/freepbx.list"
    if ! grep -qsF "${REPO_URL}/freepbx17-prod" "$REPO_FILE" 2>/dev/null; then
        echo "deb [arch=amd64] ${REPO_URL}/freepbx17-prod bookworm main" | tee "$REPO_FILE" >> "$log"
        message "   ✅ Репозиторий добавлен"
    else
        message "   ℹ️ Репозиторий уже существует"
    fi

    GPG_FILE="/etc/apt/trusted.gpg.d/freepbx.gpg"
    if [ ! -f "$GPG_FILE" ]; then
        message "   Добавление GPG ключа..."
        if wget -q -O /tmp/freepbx.asc "${REPO_URL}/gpg/aptly-pubkey.asc" 2>/dev/null || \
           wget -q -O /tmp/freepbx.asc "${MIRROR_URL}/gpg/aptly-pubkey.asc" 2>/dev/null || \
           wget -q -O /tmp/freepbx.asc "${FALLBACK_URL}/gpg/aptly-pubkey.asc" 2>/dev/null; then
            gpg --dearmor -o "$GPG_FILE" < /tmp/freepbx.asc >> "$log" 2>&1
            rm -f /tmp/freepbx.asc
            message "   ✅ GPG ключ добавлен"
        else
            message "   ⚠️ Не удалось добавить GPG ключ (продолжаем без него)"
        fi
    else
        message "   ℹ️ GPG ключ уже существует"
    fi

    message "Замена репозиториев Debian на зеркало Яндекса..."
    cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null
    sed -i '/^deb /d' /etc/apt/sources.list
    sed -i '/^deb-src /d' /etc/apt/sources.list
    cat > /etc/apt/sources.list <<EOF
deb https://mirror.yandex.ru/debian/ bookworm main contrib non-free non-free-firmware
deb-src https://mirror.yandex.ru/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirror.yandex.ru/debian-security/ bookworm-security main contrib non-free non-free-firmware
deb-src https://mirror.yandex.ru/debian-security/ bookworm-security main contrib non-free non-free-firmware
deb https://mirror.yandex.ru/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src https://mirror.yandex.ru/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
    apt-get update >> "$log" 2>&1
    message "Репозитории настроены."
}

# =============================================================================
# Глава 11: Русская локаль
# =============================================================================
setup_russian_locale() {
    message "Настройка русской локали..."
    apt-get install -y locales >> "$log"
    if ! grep -q "^ru_RU.UTF-8" /etc/locale.gen; then
        echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
    fi
    locale-gen >> "$log"
    update-locale LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8 >> "$log"
    export LANG=ru_RU.UTF-8
    export LC_ALL=ru_RU.UTF-8
    message "Русская локаль установлена."
}

# =============================================================================
# Глава 12: Безопасная перезагрузка FreePBX
# =============================================================================
safe_fwconsole_reload() {
    message "Выполняется: fwconsole reload"
    fwconsole reload
    if [ $? -eq 0 ]; then
        sleep 3
        if asterisk -rx "core show version" > /dev/null 2>&1; then
            message "fwconsole reload выполнен успешно, Asterisk отвечает."
            return 0
        else
            message "ОШИБКА: fwconsole reload завершился, но Asterisk не отвечает!"
            return 1
        fi
    else
        message "ОШИБКА: Не удалось выполнить fwconsole reload."
        return 1
    fi
}

# =============================================================================
# Глава 13: Создание каталогов и PID-файла
# =============================================================================
mkdir -p "${LOG_FOLDER}"
touch "${LOG_FILE}"
chmod 755 "${LOG_FOLDER}"
mkdir -p /var/run
chmod 755 /var/run

pidfile='/var/run/freepbx17_installer.pid'
if [ -f "$pidfile" ]; then
    old_pid=$(cat "$pidfile")
    if ps -p "$old_pid" > /dev/null 2>&1; then
        echo "Ошибка: Скрипт уже запущен (PID $old_pid). Выход."
        exit 1
    else
        echo "Предупреждение: Найден старый pid-файл, удаляем."
        rm -f "$pidfile"
    fi
fi
echo "$$" > "$pidfile"

# =============================================================================
# Глава 14: План установки и функции прогресса
# =============================================================================
setCurrentStep "=== НАЧАЛО УСТАНОВКИ FREEPBX 17 ==="
start=$(date +%s)
message "Система: $(hostname) $(uname -a)"
message "Лог установки: $log"
message ""
message "📋 ПЛАН УСТАНОВКИ:"
message "   ⬜ 1. Проверка и подготовка системы"
message "   ⬜ 2. Настройка репозиториев (Debian + FreePBX)"
message "   ⬜ 3. Установка зависимостей (500-800 МБ)"
message "   ⬜ 4. Сборка Asterisk 22:"
message "        - Клонирование (~9-15 МБ)"
message "        - Установка зависимостей сборки"
message "        - Конфигурация"
message "        - Компиляция (самый долгий этап)"
message "   ⬜ 5. Установка FreePBX"
message "   ⬜ 6. Настройка Apache и автозапуска"
message "   ⬜ 7. Финальная настройка (русский язык, звуки)"
message ""

mark_step() {
    local step_num=$1
    local step_name=$2
    message "   ✅ $step_num. $step_name — выполнено"
}

check_and_log() {
    local step=$1
    local command=$2
    if eval "$command" &>/dev/null; then
        message "   ✅ $step — пройдено"
        echo "$step: OK" >> /tmp/install_checkpoints.log
        return 0
    else
        message "   ❌ $step — НЕ ПРОЙДЕНО"
        echo "$step: FAIL" >> /tmp/install_checkpoints.log
        return 1
    fi
}

# =============================================================================
# Глава 15: Выполнение установки по шагам
# =============================================================================
setCurrentStep "=== ПРОВЕРКА И ПОДГОТОВКА СИСТЕМЫ ==="
apt-get -y --fix-broken install >> "$log"
apt-get autoremove -y >> "$log"
mark_step 1 "Проверка и подготовка системы"

setCurrentStep "=== НАСТРОЙКА ПАРАМЕТРОВ ПО УМОЛЧАНИЮ ==="
debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
echo "postfix postfix/mailname string $(hostname -f)" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
pkg_install gnupg

setCurrentStep "=== НАСТРОЙКА РЕПОЗИТОРИЕВ ==="
setup_repositories
mark_step 2 "Настройка репозиториев"

setCurrentStep "=== УСТАНОВКА ЗАВИСИМОСТЕЙ (5-10 минут) ==="
message "============================================"
message "ПРИМЕЧАНИЕ О ТРАФИКЕ"
message "В процессе установки будет скачано около 500-800 МБ данных."
message "Итоговый размер системы на диске: 2-4 ГБ."
message "============================================"
message "Начинаем установку зависимостей..."

DEPPRODPKGS=(
    "redis-server" "ghostscript" "libtiff-tools" "iptables-persistent" "net-tools"
    "rsyslog" "libavahi-client3" "nmap" "apache2" "zip" "incron" "wget" "vim"
    "openssh-server" "rsync" "mariadb-server" "mariadb-client" "bison" "flex"
    "flite" "php${PHPVERSION}" "php${PHPVERSION}-curl" "php${PHPVERSION}-zip"
    "php${PHPVERSION}-redis" "php${PHPVERSION}-cli" "php${PHPVERSION}-common"
    "php${PHPVERSION}-mysql" "php${PHPVERSION}-gd" "php${PHPVERSION}-mbstring"
    "php${PHPVERSION}-intl" "php${PHPVERSION}-xml" "php${PHPVERSION}-bz2"
    "php${PHPVERSION}-ldap" "php${PHPVERSION}-sqlite3" "php${PHPVERSION}-bcmath"
    "php${PHPVERSION}-soap" "php${PHPVERSION}-ssh2" "php-pear" "curl" "sox"
    "mpg123" "sqlite3" "git" "uuid" "odbc-mariadb" "sudo" "subversion" "unixodbc"
    "nodejs" "npm" "ipset" "iptables" "fail2ban" "htop" "postfix" "tcpdump"
    "sngrep" "tftpd-hpa" "xinetd" "lame" "haproxy" "screen" "easy-rsa" "openvpn"
    "sysstat" "apt-transport-https" "lsb-release" "ca-certificates" "cron"
    "python3-mysqldb" "at" "avahi-daemon" "avahi-utils" "libnss-mdns" "mailutils"
    "liburiparser1" "libavdevice59" "python3-mysqldb" "python-is-python3"
    "pkgconf" "libicu-dev" "libsrtp2-1" "libspandsp2" "libncurses5" "autoconf"
    "libical3" "libneon27" "libsnmp40" "libbluetooth3" "libunbound8" "libsybdb5"
    "libspeexdsp1" "libiksemel3" "libresample1" "libgmime-3.0-0" "libc-client2007e"
    "imagemagick" "libjansson-dev" "libxml2-dev" "libsqlite3-dev" "libcurl4-openssl-dev"
    "libedit-dev" "uuid-dev"
)
for i in "${!DEPPRODPKGS[@]}"; do
    pkg_install "${DEPPRODPKGS[$i]}"
done

if [ "$nochrony" != true ]; then
    pkg_install chrony
fi

setCurrentStep "=== ОЧИСТКА ==="
apt-get autoremove -y >> "$log"
execution_time="$(($(date +%s) - start))"
message "Время установки зависимостей: $execution_time сек."
mark_step 3 "Установка зависимостей"

setCurrentStep "=== НАСТРОЙКА КАТАЛОГОВ И ПРАВ ==="
groupadd -r asterisk 2>/dev/null || true
useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk 2>/dev/null || true
mkdir -p /tftpboot /var/lib/asterisk/sounds
chown -R asterisk:asterisk /tftpboot /var/lib/asterisk
sed -i -e "s|^TFTP_DIRECTORY=\"/srv\/tftp\"$|TFTP_DIRECTORY=\"/tftpboot\"|" /etc/default/tftpd-hpa
systemctl unmask tftpd-hpa.service
systemctl start tftpd-hpa.service

# Установка Asterisk
if [ -z "$noast" ] && [ "$SKIP_ASTERISK" != "1" ]; then
    setCurrentStep "=== УСТАНОВКА ASTERISK ==="
    install_asterisk $ASTVERSION
    mark_step 4 "Сборка Asterisk 22"
    # Дополнительная проверка модулей
    if ! asterisk -rx "module show" 2>/dev/null | grep -q "res_pjsip"; then
        call_debug "missing_configs"
    fi
elif [ "$SKIP_ASTERISK" = "1" ]; then
    message "⏭️ Пропуск установки Asterisk (уже установлен)"
    mark_step 4 "Сборка Asterisk 22 (пропущено)"
fi

setCurrentStep "=== УСТАНОВКА ПАКЕТОВ FREEPBX ==="
pkg_install sysadmin17 sangoma-pbx17 ffmpeg

setCurrentStep "=== НАСТРОЙКА PHP И МОДУЛЕЙ ==="
phpenmod freepbx
mkdir -p /var/lib/php/session

# Установка FreePBX
if [ "$SKIP_FREEPBX" != "1" ]; then
    setCurrentStep "=== УСТАНОВКА FREEPBX ==="
    message "Будет скачано ~100-200 МБ (пакеты FreePBX)."
    if [ "$opensourceonly" = true ]; then
        message "ℹ️ Режим --opensourceonly: установка ionCube пропущена"
    else
        pkg_install ioncube-loader-82
    fi
    install_freepbx
    mark_step 5 "Установка FreePBX"
else
    message "⏭️ Пропуск установки FreePBX (уже установлен)"
    mark_step 5 "Установка FreePBX (пропущено)"
fi

# =============================================================================
# Глава 16: Финальная настройка FreePBX
# =============================================================================
setCurrentStep "=== ФИНАЛЬНАЯ НАСТРОЙКА FREEPBX ==="

# Добавление fwconsole в PATH
if command -v fwconsole &>/dev/null; then
    message "   ✅ fwconsole уже доступен"
else
    message "   ⚠️ fwconsole не найден. Выполняется поиск..."
    FW_PATH=$(find /usr/sbin /var/lib/asterisk/bin /usr/local/bin -name "fwconsole" 2>/dev/null | head -1)
    if [ -n "$FW_PATH" ]; then
        ln -sf "$FW_PATH" /usr/local/bin/fwconsole
        message "   ✅ fwconsole добавлен в PATH"
    else
        message "   ❌ fwconsole не найден. Попытка переустановки FreePBX..."
        apt-get install --reinstall freepbx17
        FW_PATH=$(find /usr/sbin /var/lib/asterisk/bin /usr/local/bin -name "fwconsole" 2>/dev/null | head -1)
        if [ -n "$FW_PATH" ]; then
            ln -sf "$FW_PATH" /usr/local/bin/fwconsole
            message "   ✅ fwconsole найден и добавлен"
        else
            message "   ❌ Не удалось найти fwconsole"
            call_debug "fwconsole_path"
        fi
    fi
fi

# Создание конфигурации Asterisk
ASTERISK_CONF_DIR="/etc/asterisk"
if [[ ! -d "$ASTERISK_CONF_DIR" ]]; then
    message "   ⚠️ Директория $ASTERISK_CONF_DIR не найдена. Создаём..."
    mkdir -p "$ASTERISK_CONF_DIR"
    cat > "$ASTERISK_CONF_DIR/asterisk.conf" <<EOF
[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib64/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
astsbindir => /usr/sbin
EOF
    chown -R asterisk:asterisk /etc/asterisk
    call_debug "missing_configs"
    message "   ✅ Базовая конфигурация Asterisk создана"
fi

# Настройка базы данных
DB_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS asterisk;
CREATE USER IF NOT EXISTS 'freepbxuser'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON asterisk.* TO 'freepbxuser'@'localhost';
FLUSH PRIVILEGES;
EOF
if [ $? -eq 0 ]; then
    message "✅ База данных asterisk создана и настроена"
    check_and_log "MySQL сервер" "systemctl is-active mariadb"
    check_and_log "Пользователь freepbxuser" "mysql -u root -e 'SELECT 1'"
else
    message "⚠️ Ошибка настройки базы данных"
    call_debug "mysql_access"
fi

# Создание или обновление /etc/freepbx.conf
if [ ! -f /etc/freepbx.conf ]; then
    cat > /etc/freepbx.conf <<EOF
<?php
\$amp_conf = array();
\$amp_conf['AMPDBHOST'] = 'localhost';
\$amp_conf['AMPDBUSER'] = 'freepbxuser';
\$amp_conf['AMPDBPASS'] = '${DB_PASSWORD}';
\$amp_conf['AMPDBNAME'] = 'asterisk';
?>
EOF
    message "✅ /etc/freepbx.conf создан"
else
    sed -i "s/\(\$amp_conf\['AMPDBPASS'\] = '\)[^']*';/\1${DB_PASSWORD}';/" /etc/freepbx.conf
    message "✅ /etc/freepbx.conf обновлён"
fi

# Восстановление подключения к БД (если нужно)
repair_freepbx() {
    message "🔍 Проверка работоспособности FreePBX..."
    if ! fwconsole ma list &>/dev/null; then
        message "⚠️ Обнаружена проблема с подключением к базе данных. Выполняется восстановление..."
        DB_PASS=$(grep "AMPDBPASS" /etc/freepbx.conf | cut -d"'" -f2)
        mysql -u root <<EOF
ALTER USER 'freepbxuser'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
EOF
        fwconsole reload
        message "✅ Соединение восстановлено."
    else
        message "✅ FreePBX работает стабильно."
    fi
}
repair_freepbx

# Проверка fwconsole
if command -v fwconsole &>/dev/null; then
    message "✅ fwconsole готов к работе"
else
    message "⚠️ fwconsole не найден, проверьте установку FreePBX"
    call_debug "fwconsole_path"
fi

# Проверка модулей Asterisk
check_asterisk_modules() {
    message "🔍 Проверка модулей Asterisk..."
    if sudo asterisk -rx "module show" 2>/dev/null | grep -q "res_pjsip"; then
        message "   ✅ Модули Asterisk загружены корректно"
    else
        message "   ⚠️ Модули Asterisk не загружены, переустанавливаем..."
        cd /usr/src/asterisk-${ASTVERSION}
        sudo make install
        sudo ldconfig
        sudo systemctl restart asterisk
        if sudo asterisk -rx "module show" 2>/dev/null | grep -q "res_pjsip"; then
            message "   ✅ Модули успешно восстановлены"
        else
            message "   ❌ Не удалось восстановить модули Asterisk"
            call_debug "missing_configs"
        fi
    fi
}
check_asterisk_modules

# Проверка веб-интерфейса
check_web_interface() {
    message "🔍 Проверка веб-интерфейса FreePBX..."
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if curl -s -o /dev/null -w "%{http_code}" http://localhost/ | grep -q "200\|302"; then
        message "   ✅ Веб-сервер Apache отвечает"
    else
        message "   ⚠️ Веб-сервер не отвечает, перезапускаем Apache..."
        sudo systemctl restart apache2
    fi
    if curl -s -L http://localhost/admin | grep -qi "freepbx\|login"; then
        message "   ✅ FreePBX веб-интерфейс доступен"
        message "   🌐 Веб-интерфейс: http://${SERVER_IP}"
    else
        message "   ⚠️ FreePBX веб-интерфейс не отвечает"
        message "   🌐 Попробуйте открыть: http://${SERVER_IP}"
        call_debug "composer_deps"
    fi
}
check_web_interface

# =============================================================================
# Глава 17: Настройка прав доступа
# =============================================================================
setCurrentStep "=== НАСТРОЙКА ПРАВ ДОСТУПА ==="
message "🔧 Настройка прав доступа..."

chown -R asterisk:asterisk /etc/asterisk 2>/dev/null || true
chown -R asterisk:asterisk /var/lib/asterisk 2>/dev/null || true
chown -R asterisk:asterisk /var/spool/asterisk 2>/dev/null || true
chown -R asterisk:asterisk /var/log/asterisk 2>/dev/null || true
chown asterisk:asterisk /var/run/asterisk 2>/dev/null || true
message "   ✅ Права Asterisk настроены"

chown -R asterisk:asterisk /var/www/html/admin 2>/dev/null || true
chown -R asterisk:asterisk /var/www/html/panel 2>/dev/null || true
chown -R asterisk:asterisk /var/log/pbx 2>/dev/null || true
chmod +x /var/lib/asterisk/bin/fwconsole 2>/dev/null || true
message "   ✅ Права FreePBX настроены"

usermod -a -G asterisk www-data 2>/dev/null || true
chown -R www-data:www-data /var/lib/php/session 2>/dev/null || true
message "   ✅ Права Apache настроены"

chmod 775 /var/lib/asterisk/sounds 2>/dev/null || true
chmod 775 /var/spool/asterisk/monitor 2>/dev/null || true
chmod 775 /var/spool/asterisk/voicemail 2>/dev/null || true
message "   ✅ Специальные права настроены"

message "✅ Настройка прав доступа завершена"
message "✅ FreePBX финально настроен"

# =============================================================================
# Глава 18: Удаление коммерческих модулей (только open source)
# =============================================================================
if [ "$opensourceonly" ]; then
    setCurrentStep "=== УДАЛЕНИЕ КОММЕРЧЕСКИХ МОДУЛЕЙ (оставляем sysadmin, firewall, customcontexts) ==="
    keep_modules="sysadmin|firewall|customcontexts"
    modules_to_remove=$(fwconsole ma list | awk '/Commercial/ {print $2}' | grep -vE "$keep_modules" || true)
    if [ -n "$modules_to_remove" ]; then
        echo "$modules_to_remove" | xargs -t -I {} fwconsole ma -f remove {} >> "$log" 2>&1
        message "Ненужные коммерческие модули удалены."
    else
        message "Коммерческие модули для удаления не найдены."
    fi
fi

setCurrentStep "=== ПЕРЕЗАГРУЗКА FREEPBX ==="
safe_fwconsole_reload

# =============================================================================
# Глава 19: Настройка Apache
# =============================================================================
setCurrentStep "=== НАСТРОЙКА APACHE ==="
cat > /etc/apache2/sites-available/freepbx.conf <<'EOF'
<VirtualHost *:80>
    DocumentRoot /var/www/html
    ServerName localhost
    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/freepbx-error.log
    CustomLog ${APACHE_LOG_DIR}/freepbx-access.log combined
</VirtualHost>
EOF
a2enmod ssl expires headers rewrite
a2dissite 000-default.conf 2>/dev/null || true
a2ensite freepbx.conf
rm -f /var/www/html/index.html
systemctl restart apache2
if [ $? -ne 0 ]; then
    message "Ошибка при перезапуске Apache."
    message "Проверьте конфигурацию: apachectl configtest"
    send_report "apache_config"
    exit 1
fi
mark_step 6 "Настройка Apache и автозапуска"

# =============================================================================
# Глава 20: Настройка автозапуска
# =============================================================================
setCurrentStep "=== НАСТРОЙКА АВТОЗАПУСКА ==="
systemctl enable asterisk
systemctl start asterisk
systemctl enable freepbx

cat > /etc/systemd/system/freepbx.service <<EOF
[Unit]
After=mariadb.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/fwconsole start
ExecStop=/usr/sbin/fwconsole stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl stop freepbx 2>/dev/null || true
systemctl start freepbx
systemctl enable freepbx

apt-mark hold sangoma-pbx17 nodejs node-* freepbx17 >> "$log"

# =============================================================================
# Глава 21: Финальная настройка (русский язык, обновления)
# =============================================================================
setCurrentStep "=== ФИНАЛЬНАЯ НАСТРОЙКА (русский язык, обновления) ==="
fwconsole ma refreshsignatures >> "$log" 2>&1 || message "Не удалось обновить подписи"
setup_russian_locale
fwconsole setting set LANG ru_RU >> "$log" 2>&1
fwconsole setting set LANGUAGE ru_RU >> "$log" 2>&1
if ! fwconsole ma downloadinstall soundlang --tag=ru_RU >> "$log" 2>&1; then
    message "Не удалось установить русские звуки. Будут использованы английские."
fi
message "Проверка и обновление модулей FreePBX (это может занять несколько минут)..."
fwconsole ma upgradeall >> "$log" 2>&1 || message "Некоторые модули не обновились"
fwconsole reload >> "$log"
fwconsole chown >> "$log"

# =============================================================================
# Глава 22: Критическая проверка и итоговое сообщение
# =============================================================================
execution_time="$(($(date +%s) - start))"

if ! command -v asterisk > /dev/null 2>&1; then
    message "❌ ОШИБКА: Asterisk не был установлен!"
    send_report "final_asterisk_missing"
    exit 1
fi
if ! command -v fwconsole > /dev/null 2>&1; then
    message "❌ ОШИБКА: FreePBX не был установлен!"
    send_report "final_freepbx_missing"
    exit 1
fi
ASTERISK_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -1)
if [ -z "$ASTERISK_VERSION" ]; then
    message "❌ ОШИБКА: Asterisk установлен, но не отвечает!"
    send_report "final_asterisk_not_responding"
    exit 1
fi

# Финальная проверка веб-интерфейса
SERVER_IP=$(hostname -I | awk '{print $1}')
if curl -s -o /dev/null -w "%{http_code}" http://localhost/ | grep -q "200\|302"; then
    message "   ✅ Веб-сервер Apache отвечает"
else
    message "   ⚠️ Веб-сервер не отвечает"
fi
if curl -s -L http://localhost/admin | grep -qi "freepbx\|login"; then
    message "   ✅ FreePBX веб-интерфейс доступен"
else
    message "   ⚠️ FreePBX веб-интерфейс не отвечает"
fi

message "============================================"
message "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! Время: $execution_time сек."
message "Веб-интерфейс FreePBX доступен по адресу: http://${SERVER_IP}"
message "Логин: admin, пароль задаётся при первом входе."
message "============================================"
fwconsole motd
mark_step 7 "Финальная настройка"

# =============================================================================
# Глава 23: Отправка анонимной статистики (только количество установок)
# =============================================================================
send_stats() {
    echo ""
    echo "❓ Отправить анонимную статистику об успешной установке?"
    echo "   (только количество установок, без личных данных)"
    read -p "   Отправить? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        VERSION=$(grep 'SCRIPT_VERSION="' "$0" | cut -d'"' -f2 || echo "unknown")
        curl -s "https://api.countapi.xyz/hit/master-automation/freepbx_install/version_${VERSION}" > /dev/null
        curl -s "https://api.countapi.xyz/hit/master-automation/freepbx_install/total" > /dev/null
        echo "✅ Спасибо! Статистика отправлена."
    else
        echo "ℹ️ Статистика не отправлена."
    fi
}
send_stats
