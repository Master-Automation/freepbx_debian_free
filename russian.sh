#!/bin/bash
#####################################################################################
# Скрипт установки FreePBX 17 на Debian 12
# Адаптирован под условия в России
# Версия: 3.1 (Полностью рабочая)
#####################################################################################
set -e
SCRIPT_VERSION="3.1.2"
ASTVERSION=${ASTVERSION:-22}
PHPVERSION="8.2"
LOG_FOLDER="/var/log/pbx"
LOG_FILE="${LOG_FOLDER}/freepbx17-install-$(date '+%Y.%m.%d-%H.%M.%S').log"
log=$LOG_FILE
SANE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NPM_MIRROR=""
export GIT_HTTP_TIMEOUT=300
export GIT_CLONE_TIMEOUT=300


# Функции логирования
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

# Проверка ОС
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

# Парсинг параметров
while [[ $# -gt 0 ]]; do
    case $1 in
        --skipversion) skipversion=true; shift ;;
        --opensourceonly) opensourceonly=true; shift ;;
        --nochrony) nochrony=true; shift ;;
        --debianmirror) DEBIAN_MIRROR=$2; shift; shift ;;
        *) shift ;;
    esac
done

# Расширенный обработчик ошибок с подсказками
errorHandler() {
    local line=$1
    local code=$2
    local cmd=$3
    log "****** INSTALLATION FAILED *****"
    echo_ts "Ошибка на шаге: ${currentStep} (строка $line, код $code)"
    echo_ts "Последняя команда: $cmd"
    echo_ts "Подробности в логе: ${LOG_FILE}"
    
    case "${currentStep}" in
        "=== НАСТРОЙКА РЕПОЗИТОРИЕВ ===")
            echo_ts "Возможная причина: проблемы с сетью или недоступность зеркал."
            echo_ts "Что делать:"
            echo_ts "1. Проверьте интернет-соединение: ping -c 4 git.freepbx.asterisk.ru"
            echo_ts "2. Если зеркало недоступно, замените REPO_URL в скрипте на другое."
            echo_ts "3. Повторите попытку через 5-10 минут."
            ;;
        "=== УСТАНОВКА ЗАВИСИМОСТЕЙ ===")
            echo_ts "Возможная причина: отсутствуют некоторые пакеты или конфликт версий."
            echo_ts "Что делать:"
            echo_ts "1. Попробуйте выполнить вручную: apt-get update && apt-get install -f"
            echo_ts "2. Затем перезапустите скрипт: sudo ./russian.sh --skipversion --opensourceonly"
            ;;
        "=== УСТАНОВКА ASTERISK ===")
            echo_ts "Возможная причина: не хватает места на диске или отсутствуют компиляторы."
            echo_ts "Что делать:"
            echo_ts "1. Проверьте свободное место: df -h /usr/src"
            echo_ts "2. Установите компиляторы: apt-get install -y build-essential"
            echo_ts "3. Если ошибка повторяется, попробуйте собрать Asterisk вручную (см. лог)."
            ;;
        "=== УСТАНОВКА FREEPBX ===")
            echo_ts "Возможная причина: сбой при загрузке пакетов из репозитория."
            echo_ts "Что делать:"
            echo_ts "1. Проверьте репозиторий: apt-cache policy freepbx17"
            echo_ts "2. Если ключ GPG устарел, выполните: wget -O - http://git.freepbx.asterisk.ru/gpg/aptly-pubkey.asc | apt-key add -"
            ;;
        "=== ПЕРЕЗАГРУЗКА FREEPBX ===")
            echo_ts "Возможная причина: Asterisk не запущен или сокет недоступен."
            echo_ts "Что делать:"
            echo_ts "1. Проверьте статус: systemctl status asterisk"
            echo_ts "2. Запустите вручную: systemctl start asterisk && fwconsole start"
            ;;
        "=== НАСТРОЙКА APACHE ===")
            echo_ts "Возможная причина: ошибка в конфигурации или порт 80 занят."
            echo_ts "Что делать:"
            echo_ts "1. Проверьте синтаксис: apachectl configtest"
            echo_ts "2. Посмотрите логи: tail -20 /var/log/apache2/error.log"
            ;;
        *)
            echo_ts "Общие рекомендации:"
            echo_ts "1. Проверьте наличие свободного места на диске: df -h"
            echo_ts "2. Проверьте интернет-соединение: ping -c 4 ya.ru"
            echo_ts "3. Посмотрите полный лог: cat ${LOG_FILE}"
            echo_ts "4. Если ничего не помогло, обратитесь за помощью с логом."
            ;;
    esac
    exit "$code"
}
trap 'errorHandler "$LINENO" "$?" "$BASH_COMMAND"' ERR
trap "terminate" EXIT

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

# Установка Asterisk из исходников (с исправлением библиотеки)
install_asterisk() {
    astver=$1
    message "Сборка Asterisk ${astver} из исходников. Это займёт 20-40 минут."
    
    # Проверяем, не установлен ли уже Asterisk
    if command -v asterisk > /dev/null 2>&1; then
        INSTALLED_VERSION=$(asterisk -rx "core show version" 2>/dev/null | grep -oP 'Asterisk \K[0-9.]+' || echo "")
        if [[ "$INSTALLED_VERSION" == "$astver"* ]]; then
            message "✅ Asterisk ${astver} уже установлен. Пропускаем сборку."
            return 0
        fi
    fi
    
    mkdir -p /usr/src
    cd /usr/src
    
    # Удаляем старую/частичную папку, если есть
    if [ -d "asterisk-${astver}" ]; then
        message "⚠️ Обнаружена старая/частичная папка исходников. Удаляем..."
        rm -rf asterisk-${astver}
    fi
    
    # Увеличиваем буфер для Git
    git config --global http.postBuffer 524288000
    
    # Автоматические повторные попытки клонирования
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
                message "Повтор через $RETRY_DELAY секунд..."
                sleep $RETRY_DELAY
            else
                message "❌ ОШИБКА: Не удалось клонировать репозиторий после $MAX_RETRIES попыток."
                message "Возможные причины: проблемы с интернетом, блокировка GitHub, недостаточно места на диске."
                message "Что делать:"
                message "1. Проверьте соединение: ping -c 4 github.com"
                message "2. Попробуйте позже или вручную выполните: git clone --depth 1 -b 22 https://github.com/asterisk/asterisk.git /usr/src/asterisk-22"
                message "3. Затем перезапустите скрипт."
                exit 1
            fi
        fi
    done

       cd asterisk-${astver}

      # Установка зависимостей для сборки (с fallback и диагностикой)
    message "Установка зависимостей для сборки..."
    
    # Пытаемся выполнить автоматическую установку
    message "   Попытка 1/2: автоматическая установка (install_prereq)..."
    if ./contrib/scripts/install_prereq install 2>&1 | tee -a "$log"; then
        message "   ✅ Зависимости успешно установлены автоматически."
    else
        message "   ⚠️ Автоматическая установка не удалась."
        
        # Диагностика причин
        message ""
        message "   🔍 Диагностика причин:"
        
        # Проверка интернета
        if curl -s --connect-timeout 5 https://deb.debian.org > /dev/null 2>&1; then
            message "      ✅ Интернет доступен"
        else
            message "      ❌ Интернет НЕ доступен (проверьте соединение)"
        fi
        
        # Проверка прав
        if [ -w /tmp ]; then
            message "      ✅ Права на запись есть"
        else
            message "      ❌ Нет прав на запись в /tmp"
        fi
        
        # Проверка Python
        if command -v python3 > /dev/null 2>&1; then
            message "      ✅ Python3 установлен"
        else
            message "      ❌ Python3 НЕ установлен"
        fi
        
        # Проверка apt
        if command -v apt-get > /dev/null 2>&1; then
            message "      ✅ apt-get доступен"
        else
            message "      ❌ apt-get НЕ доступен"
        fi
        
        message ""
        message "   Попытка 2/2: ручная установка зависимостей (apt-get)..."
        
        apt-get update -y
        
        message "   Установка пакетов (это может занять 2-3 минуты)..."
        apt-get install -y \
            build-essential \
            cmake \
            libxml2-dev \
            libsqlite3-dev \
            libjansson-dev \
            libssl-dev \
            libedit-dev \
            uuid-dev \
            libxslt1-dev \
            liburiparser-dev \
            libspandsp-dev \
            libspeexdsp-dev \
            libopus-dev \
            libsrtp2-dev \
            portaudio19-dev \
            liblua5.2-dev \
            libcurl4-openssl-dev \
            libpq-dev \
            unixodbc-dev \
            libneon27-dev \
            libgmime-3.0-dev \
            libgsm1-dev \
            libvorbis-dev \
            libogg-dev \
            libcodec2-dev \
            libfreetype6-dev \
            libfontconfig1-dev \
            libicu-dev \
            libsndfile1-dev \
            libopencore-amrnb-dev \
            libopenjp2-7-dev \
            libmp3lame-dev \
            libc-client2007e-dev \
            libldap2-dev \
            libtool \
            autoconf \
            pkg-config 2>&1 | tee -a "$log"
        
        if [ $? -eq 0 ]; then
            message "   ✅ Зависимости успешно установлены вручную."
        else
            message "   ❌ ОШИБКА: Не удалось установить зависимости для сборки Asterisk."
            message ""
            message "   Что делать:"
            message "   1. Проверьте интернет: ping -c 4 deb.debian.org"
            message "   2. Обновите список пакетов: sudo apt-get update"
            message "   3. Установите вручную: sudo apt-get install -y build-essential libedit-dev uuid-dev libjansson-dev libxml2-dev libsqlite3-dev"
            message "   4. Затем перезапустите скрипт: sudo ./russian.sh --skipversion --opensourceonly"
            exit 1
        fi
    fi
    message "Конфигурация Asterisk..."
    ./configure --libdir=/usr/lib64 --with-pjproject-bundled
    if [ $? -ne 0 ]; then
        message "❌ ОШИБКА: Не удалось настроить конфигурацию Asterisk."
        exit 1
    fi
    
     make menuselect.makeopts
    # Отключаем кодеки, требующие скачивания с digium.com (сервер недоступен из РФ)
    menuselect/menuselect --enable chan_pjsip --enable res_srtp --enable res_http_websocket --enable format_mp3
    menuselect/menuselect --disable codec_opus --disable codec_g729a
    message "   ⚠️ Кодеки Opus и G.729 отключены (сервер downloads.digium.com недоступен)"
    message "   ✅ Open-source Opus будет установлен позже из репозитория Debian"

    message "Загрузка библиотеки для поддержки MP3..."
    contrib/scripts/get_mp3_source.sh

    message "Компиляция Asterisk (самый долгий этап)..."
    make -j$(nproc)
    if [ $? -ne 0 ]; then
        message "❌ ОШИБКА: Не удалось скомпилировать Asterisk."
        message "Что делать: попробуйте выполнить вручную:"
        message "cd /usr/src/asterisk-${astver} && make -j$(nproc)"
        exit 1
    fi
    
    # Отключаем автоматическое скачивание кодеков
    export CODEC_OPUS_DOWNLOAD_DISABLE=1
    export CODEC_G729_DOWNLOAD_DISABLE=1
    export CODEC_SILK_DOWNLOAD_DISABLE=1
    
    message "Установка Asterisk..."
    make install
    if [ $? -ne 0 ]; then
        message "❌ ОШИБКА: Не удалось установить Asterisk."
        exit 1
    fi
    
    # Сохраняем в кэш после успешной установки
    message "Сохраняем собранный Asterisk в кэш..."
    mkdir -p "$CACHE_DIR"
    cp -r /usr/src/asterisk-${astver} "$CACHE_DIR/"
    message "   ✅ Кэш сохранён в $CACHE_DIR/asterisk-${astver}"
    
    make config
    ldconfig

    if [ -f /usr/src/asterisk-${astver}/main/libasteriskssl.so.1 ]; then
        cp /usr/src/asterisk-${astver}/main/libasteriskssl.so.1 /usr/lib64/
        echo "/usr/lib64" > /etc/ld.so.conf.d/asterisk.conf
        ldconfig
        message "Библиотека libasteriskssl.so.1 скопирована и зарегистрирована."
    else
        message "ВНИМАНИЕ: libasteriskssl.so.1 не найдена. Возможны проблемы с запуском Asterisk."
    fi
    
    message "✅ Asterisk ${astver} успешно собран и установлен."
}


# Настройка репозиториев (без дублирования)
setup_repositories() {
    message "Добавление репозитория FreePBX..."
    
    # Проверяем доступность российского зеркала
    MIRROR_URL="http://git.freepbx.asterisk.ru"
    FALLBACK_URL="http://packages.freepbx.org"
    REPO_URL=""
    
    if curl -s --connect-timeout 5 "$MIRROR_URL" > /dev/null 2>&1; then
        message "   ✅ Российское зеркало доступно: $MIRROR_URL"
        REPO_URL="$MIRROR_URL"
    else
        message "   ⚠️ Российское зеркало недоступно, использую официальный репозиторий"
        message "   (это не ошибка, установка продолжится)"
        REPO_URL="$FALLBACK_URL"
    fi
    
    # Добавляем репозиторий
    if ! grep -qsF "deb [arch=amd64] ${REPO_URL}/freepbx17-prod bookworm main" /etc/apt/sources.list; then
        echo "deb [arch=amd64] ${REPO_URL}/freepbx17-prod bookworm main" | tee -a /etc/apt/sources.list >> "$log"
    fi
    
    # Скачиваем ключ (с fallback)
    if ! wget -O - "${REPO_URL}/gpg/aptly-pubkey.asc" 2>/dev/null | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg >> "$log" 2>&1; then
        message "   ⚠️ Не удалось скачать ключ из ${REPO_URL}, пробую из зеркала..."
        wget -O - "${MIRROR_URL}/gpg/aptly-pubkey.asc" 2>/dev/null | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg >> "$log" 2>&1 || \
        wget -O - "${FALLBACK_URL}/gpg/aptly-pubkey.asc" 2>/dev/null | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg >> "$log" 2>&1
    fi

    message "Замена репозиториев Debian на зеркало Яндекса (mirror.yandex.ru)..."
    # Удаляем старые строки deb и deb-src (кроме строки FreePBX)
    sed -i '/^deb /d' /etc/apt/sources.list
    sed -i '/^deb-src /d' /etc/apt/sources.list

    cat >> /etc/apt/sources.list <<EOF
deb https://mirror.yandex.ru/debian/ bookworm main contrib non-free non-free-firmware
deb-src https://mirror.yandex.ru/debian/ bookworm main contrib non-free non-free-firmware

deb https://mirror.yandex.ru/debian-security/ bookworm-security main contrib non-free non-free-firmware
deb-src https://mirror.yandex.ru/debian-security/ bookworm-security main contrib non-free non-free-firmware

deb https://mirror.yandex.ru/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src https://mirror.yandex.ru/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
    apt-get update >> "$log"
    message "Репозитории настроены."
}

# Генерация русской локали в системе
setup_russian_locale() {
    message "Настройка русской локали в системе..."
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

# Безопасная перезагрузка FreePBX с проверкой
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

# Создание необходимых каталогов
mkdir -p "${LOG_FOLDER}"
touch "${LOG_FILE}"
chmod 755 "${LOG_FOLDER}"

# Создание каталога для PID-файла
mkdir -p /var/run
chmod 755 /var/run

# ===========================
# Основной процесс установки
# ===========================
pidfile='/var/run/freepbx17_installer.pid'
# Проверка, не запущен ли уже другой экземпляр скрипта
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

setCurrentStep "=== НАЧАЛО УСТАНОВКИ FREEPBX 17 ==="
start=$(date +%s)
message "Система: $(hostname) $(uname -a)"
message "Лог установки: $log"

setCurrentStep "=== ПРОВЕРКА И ПОДГОТОВКА СИСТЕМЫ ==="
apt-get -y --fix-broken install >> "$log"
apt-get autoremove -y >> "$log"

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
message "Время установки зависимостей: $execution_time с"

setCurrentStep "=== НАСТРОЙКА КАТАЛОГОВ И ПРАВ ==="
groupadd -r asterisk 2>/dev/null || true
useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk 2>/dev/null || true
mkdir -p /tftpboot /var/lib/asterisk/sounds
chown -R asterisk:asterisk /tftpboot /var/lib/asterisk
sed -i -e "s|^TFTP_DIRECTORY=\"/srv\/tftp\"$|TFTP_DIRECTORY=\"/tftpboot\"|" /etc/default/tftpd-hpa
systemctl unmask tftpd-hpa.service
systemctl start tftpd-hpa.service

# Установка Asterisk
if [ -z "$noast" ]; then
    setCurrentStep "=== УСТАНОВКА ASTERISK (20-40 минут) ==="
    message "Будет скачано ~50 МБ (исходный код Asterisk с GitHub)."
    install_asterisk $ASTVERSION
fi

setCurrentStep "=== УСТАНОВКА ПАКЕТОВ FREEPBX ==="
pkg_install sysadmin17 sangoma-pbx17 ffmpeg

setCurrentStep "=== НАСТРОЙКА PHP И МОДУЛЕЙ ==="
phpenmod freepbx
mkdir -p /var/lib/php/session

setCurrentStep "=== УСТАНОВКА FREEPBX ==="
message "Будет скачано ~100-200 МБ (пакеты FreePBX)."
pkg_install ioncube-loader-82
pkg_install freepbx17

# Удаление коммерческих модулей (оставляем только нужные)
if [ "$opensourceonly" ]; then
    setCurrentStep "=== УДАЛЕНИЕ КОММЕРЧЕСКИХ МОДУЛЕЙ (оставляем sysadmin, firewall, customcontexts) ==="
    keep_modules="sysadmin|firewall|customcontexts"
    modules_to_remove=$(fwconsole ma list | awk '/Commercial/ {print $2}' | grep -vE "$keep_modules" || true)
    if [ -n "$modules_to_remove" ]; then
        echo "$modules_to_remove" | xargs -t -I {} fwconsole ma -f remove {} >> "$log" 2>&1
        message "Ненужные коммерческие модули удалены. Модули Sysadmin, Firewall и Custom Contexts оставлены."
    else
        message "Коммерческие модули для удаления не найдены (или все уже удалены)."
    fi
fi

setCurrentStep "=== ПЕРЕЗАГРУЗКА FREEPBX ==="
safe_fwconsole_reload

# Настройка Apache
setCurrentStep "=== НАСТРОЙКА APACHE ==="
# Создаём конфигурационный файл виртуального хоста
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
    message "Посмотрите логи: journalctl -u apache2 -n 20"
    exit 1
fi

# Настройка автозапуска
setCurrentStep "=== НАСТРОЙКА АВТОЗАПУСКА ==="
systemctl enable asterisk
systemctl start asterisk
systemctl enable freepbx

# Исправление порядка запуска служб
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

# Блокировка обновлений пакетов
apt-mark hold sangoma-pbx17 nodejs node-* freepbx17 >> "$log"

# ========== ДОПОЛНИТЕЛЬНЫЕ УЛУЧШЕНИЯ ==========
setCurrentStep "=== ФИНАЛЬНАЯ НАСТРОЙКА (русский язык, обновления) ==="

# Обновление подписей (исправляет статус "Unknown/повреждён")
fwconsole ma refreshsignatures >> "$log" 2>&1 || message "Не удалось обновить подписи (возможно, проблема с сетью)."

# Генерация русской локали в ОС
setup_russian_locale

# Установка русского языка для FreePBX
fwconsole setting set LANG ru_RU >> "$log" 2>&1
fwconsole setting set LANGUAGE ru_RU >> "$log" 2>&1

# Установка русских звуковых файлов (если доступны)
if ! fwconsole ma downloadinstall soundlang --tag=ru_RU >> "$log" 2>&1; then
    message "Не удалось установить русские звуки. Будут использованы английские."
fi

# Обновление всех модулей до актуальных версий
message "Проверка и обновление модулей FreePBX (это может занять несколько минут)..."
fwconsole ma upgradeall >> "$log" 2>&1 || message "Некоторые модули не обновились (возможно, из-за отсутствия лицензий)."

# Перезагрузка конфигурации и прав
fwconsole reload >> "$log"
fwconsole chown >> "$log"

# Финальное сообщение
execution_time="$(($(date +%s) - start))"

# ========== КРИТИЧЕСКАЯ ПРОВЕРКА ==========
# Проверка, что Asterisk действительно установлен
if ! command -v asterisk > /dev/null 2>&1; then
    message "❌ ОШИБКА: Asterisk не был установлен!"
    message "   Установка прервана или завершилась с ошибкой."
    message "   Лог установки: ${LOG_FILE}"
    exit 1
fi

# Проверка, что FreePBX установлен
if ! command -v fwconsole > /dev/null 2>&1; then
    message "❌ ОШИБКА: FreePBX не был установлен!"
    message "   Установка прервана или завершилась с ошибкой."
    message "   Лог установки: ${LOG_FILE}"
    exit 1
fi

# Проверка версии Asterisk
ASTERISK_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -1)
if [ -z "$ASTERISK_VERSION" ]; then
    message "❌ ОШИБКА: Asterisk установлен, но не отвечает!"
    message "   Проверьте статус: systemctl status asterisk"
    exit 1
fi
# ==========================================

message "============================================"
message "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! Время: $execution_time с"
message "Веб-интерфейс FreePBX доступен по адресу: http://$(hostname -I | awk '{print $1}')"
message "Логин: admin, пароль задаётся при первом входе."
message "============================================"
fwconsole motd

# Функция отправки статистики
send_stats() {

    # Проверяем, хочет ли пользователь отправить статистику
    echo ""
    echo "❓ Отправить анонимную статистику об успешной установке?"
    echo "   (это поможет улучшить скрипт)"
    read -p "   Отправить? (y/n): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Получаем версию из скрипта
        VERSION=$(grep -oP 'SCRIPT_VERSION="\K[0-9.]+' "$0" || echo "unknown")
        
        # Отправляем счётчик для конкретной версии
        curl -s "https://api.countapi.xyz/hit/master-automation/freepbx_install/version_${VERSION}" > /dev/null
        
        # Отправляем общий счётчик
        curl -s "https://api.countapi.xyz/hit/master-automation/freepbx_install/total" > /dev/null
        
        echo "✅ Спасибо! Статистика отправлена."
        echo "   Всего установок версии ${VERSION}: $(curl -s https://api.countapi.xyz/get/master-automation/freepbx_install/version_${VERSION} | grep -oP '"value":\K\d+')"
    else
        echo "ℹ️ Статистика не отправлена."
    fi
}

# Вызываем функцию в конце успешной установки
send_stats
