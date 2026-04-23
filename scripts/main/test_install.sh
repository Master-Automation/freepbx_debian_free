#!/bin/bash
# =============================================================================
# Полный скрипт для чистой установки Asterisk 22 + FreePBX 17 на Debian 12
# Автор: Master Automation
# Версия: 3.0 (с поддержкой пресетов установки)
# =============================================================================
# Внимание! Этот скрипт полностью пересоздаст систему под нужды VoIP.
# Поддерживаемые пресеты:
#   default   - Стандартная установка (официальные зеркала Debian, англ. звуки)
#   ru_fast   - Российские зеркала Яндекса, английские и русские звуки
# =============================================================================

set -e  # Остановка при любой ошибке
exec > >(tee -a /var/log/voip_full_install.log) 2>&1
echo "=== Начало установки: $(date) ==="

# -----------------------------------------------------------------------------
# 1. Глобальные настройки и переменные
# -----------------------------------------------------------------------------
AST_USER="asterisk"
AST_GROUP="asterisk"
AST_VERSION="22"              # Будет скачана актуальная 22-я версия
DB_PASS="strong_database_password_please_change"        # Измените пароль БД!
FREEPBX_DB_PASS="strong_freepbx_password_please_change" # Измените пароль FreePBX!
TIMEZONE="Europe/Moscow"

# Пресет по умолчанию (можно переопределить аргументом командной строки)
PRESET="${PRESET:-default}"

# Настройки по умолчанию (могут быть переопределены в зависимости от пресета)
APT_MIRROR_BASE="http://deb.debian.org/debian"
APT_SECURITY="http://security.debian.org/debian-security"
CORE_SOUNDS_ENABLED="CORE-SOUNDS-EN-GSM CORE-SOUNDS-EN-ALAW"
CORE_SOUNDS_DISABLED="CORE-SOUNDS-EN-WAV CORE-SOUNDS-EN-ULAW CORE-SOUNDS-RU-WAV CORE-SOUNDS-RU-ULAW CORE-SOUNDS-RU-GSM CORE-SOUNDS-RU-ALAW"

# -----------------------------------------------------------------------------
# 2. Разбор аргументов командной строки (поддержка пресетов)
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
Использование: $0 [--preset <имя>] [--help]

Доступные пресеты:
  default   - Стандартная установка (официальные зеркала Debian, английские звуки)
  ru_fast   - Установка с российскими зеркалами Яндекса, английские и русские звуки

Примеры:
  sudo $0 --preset ru_fast
  sudo $0 --preset default
  sudo PRESET=ru_fast $0
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset)
            PRESET="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            show_help
            ;;
    esac
done

# Проверка корректности пресета
case "$PRESET" in
    default|ru_fast)
        echo "Выбран пресет установки: $PRESET"
        ;;
    *)
        echo "Ошибка: неизвестный пресет '$PRESET'"
        show_help
        ;;
esac

# -----------------------------------------------------------------------------
# 3. Применение настроек в зависимости от пресета
# -----------------------------------------------------------------------------
case "$PRESET" in
    default)
        # Оставляем настройки по умолчанию
        echo "Настройка: официальные зеркала Debian, английские звуки"
        ;;
    ru_fast)
        # Замена зеркал на российские (Яндекс)
        APT_MIRROR_BASE="http://mirror.yandex.ru/debian"
        APT_SECURITY="http://mirror.yandex.ru/debian-security"
        # Добавляем русские звуки
        CORE_SOUNDS_ENABLED="$CORE_SOUNDS_ENABLED CORE-SOUNDS-RU-GSM CORE-SOUNDS-RU-ALAW"
        CORE_SOUNDS_DISABLED="CORE-SOUNDS-EN-WAV CORE-SOUNDS-EN-ULAW CORE-SOUNDS-RU-WAV CORE-SOUNDS-RU-ULAW"
        echo "Настройка: российские зеркала Яндекса, английские и русские звуки"
        ;;
esac

# -----------------------------------------------------------------------------
# 4. Предварительные проверки окружения (начало)
# -----------------------------------------------------------------------------
echo "[1/12] Проверка системы и очистка..."

# Проверка, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт должен запускаться от root (используйте sudo)."
    exit 1
fi

# -----------------------------------------------------------------------------
# 5. Очистка источников apt от дубликатов и настройка зеркал
# -----------------------------------------------------------------------------
echo "[0/12] Настройка источников APT..."

# Очистка от дубликатов в /etc/apt/sources.list
if [[ -f /etc/apt/sources.list ]]; then
    mv /etc/apt/sources.list /etc/apt/sources.list.bak
    awk '!seen[$0]++' /etc/apt/sources.list.bak > /etc/apt/sources.list
fi

# Настройка основного sources.list в соответствии с выбранным пресетом
cat > /etc/apt/sources.list <<EOF
deb ${APT_MIRROR_BASE} bookworm main contrib non-free non-free-firmware
deb ${APT_MIRROR_BASE} bookworm-updates main contrib non-free non-free-firmware
deb ${APT_SECURITY} bookworm-security main contrib non-free non-free-firmware
EOF

# Настройка репозитория FreePBX (только один раз)
rm -f /etc/apt/sources.list.d/freepbx.list 2>/dev/null
echo "deb [arch=amd64] http://deb.freepbx.org/freepbx17-prod bookworm main" > /etc/apt/sources.list.d/freepbx.list

# Обновление списка пакетов
apt-get update

# -----------------------------------------------------------------------------
# 6. Дальнейшие проверки системы
# -----------------------------------------------------------------------------
# Проверка ОС
if [[ ! -f /etc/debian_version ]] || ! grep -q "bookworm" /etc/os-release; then
    echo "Ошибка: Скрипт поддерживает только Debian 12 (Bookworm)."
    exit 1
fi

# Проверка достаточности ресурсов
mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
if [[ $mem_total -lt 1800000 ]]; then
    echo "Предупреждение: Меньше 2GB ОЗУ! Установка возможна, но могут быть проблемы."
fi

disk_avail=$(df / --output=avail | tail -n1)
if [[ $disk_avail -lt 5000000 ]]; then
    echo "Ошибка: Недостаточно свободного места (нужно минимум 5GB)."
    exit 1
fi

# Полная очистка системы от следов предыдущих установок
systemctl stop asterisk mariadb mysql apache2 2>/dev/null || true
systemctl disable asterisk mariadb mysql apache2 2>/dev/null || true

# Удаление пакетов (игнорируем ошибки, если пакетов нет)
apt-get remove --purge -y asterisk* mariadb-* mysql-* apache2* php* freepbx* 2>/dev/null || true
apt-get autoremove --purge -y

# Удаление конфигурационных директорий
rm -rf /etc/asterisk /usr/lib/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/sbin/asterisk /usr/src/asterisk-*
rm -rf /var/www/html /etc/freepbx.conf /etc/amportal.conf
rm -rf /etc/mysql /var/lib/mysql /etc/my.cnf
rm -rf /etc/apache2 /var/www/html

# Удаление пользователя и группы, если они существуют (с игнорированием ошибок)
userdel -r $AST_USER 2>/dev/null || true
groupdel $AST_GROUP 2>/dev/null || true

# Очистка кэша APT
apt-get clean
apt-get update

# -----------------------------------------------------------------------------
# 7. Установка зависимостей
# -----------------------------------------------------------------------------
echo "[2/12] Установка системных зависимостей..."

# Установка необходимых пакетов для сборки Asterisk и работы FreePBX
apt-get install -y wget curl gnupg2 software-properties-common git build-essential \
    pkg-config libedit-dev libjansson-dev libsqlite3-dev uuid-dev libxml2-dev libssl-dev \
    libncurses5-dev liburiparser-dev libxslt1-dev libpq-dev unixodbc-dev unixodbc \
    python3 python3-pip nodejs npm dirmngr sox mpg123 apache2 mariadb-server mariadb-client \
    php php-curl php-cli php-pdo php-mysql php-pear php-gd php-mbstring php-intl php-bcmath \
    php-xml libapache2-mod-php php-cgi nodejs npm

# Установка дополнительных утилит для удобства
apt-get install -y net-tools htop screen tshark vim sngrep

# -----------------------------------------------------------------------------
# 8. Создание пользователя и группы Asterisk (без ошибок, если уже существуют)
# -----------------------------------------------------------------------------
echo "[3/12] Создание пользователя asterisk..."

# Создаём группу, если её нет
if ! getent group "$AST_GROUP" >/dev/null; then
    addgroup --system "$AST_GROUP"
fi

# Создаём пользователя, если его нет
if ! id -u "$AST_USER" >/dev/null 2>&1; then
    adduser --system --ingroup "$AST_GROUP" --home /var/lib/asterisk --no-create-home --gecos "Asterisk PBX" "$AST_USER"
fi

# Добавляем пользователя в нужные группы (если ещё не добавлен)
if ! groups "$AST_USER" | grep -q "$AST_GROUP"; then
    usermod -a -G "$AST_GROUP" "$AST_USER"
fi
if ! groups "$AST_USER" | grep -qE "(audio|dialout)"; then
    usermod -a -G audio,dialout "$AST_USER"
fi

# -----------------------------------------------------------------------------
# 9. Настройка часового пояса
# -----------------------------------------------------------------------------
timedatectl set-timezone $TIMEZONE

# -----------------------------------------------------------------------------
# 10. Сборка Asterisk из исходников
# -----------------------------------------------------------------------------
echo "[4/12] Загрузка и сборка Asterisk ${AST_VERSION}..."

mkdir -p /usr/src/asterisk
cd /usr/src/asterisk

# Удаляем старые исходники, чтобы избежать конфликтов прав
rm -rf /usr/src/asterisk/asterisk-*

# Загрузка последней версии Asterisk 22
wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
tar xvf asterisk-22-current.tar.gz
rm asterisk-22-current.tar.gz
cd asterisk-22.* 2>/dev/null || cd asterisk-22

# Принудительное исправление прав на исходники
chown -R root:root .
chmod -R u+w .

# Установка всех зависимостей сборки через штатный скрипт
contrib/scripts/install_prereq install

# Конфигурация с использованием встроенных библиотек для избежания конфликтов
./configure --with-pjproject-bundled --with-jansson-bundle --libdir=/usr/lib/x86_64-linux-gnu

# Меню выбора модулей: отключаем потенциально проблемные и ненужные модули
make menuselect.makeopts

# Отключение модулей, которые могут быть проблемными (базовый список)
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable chan_ooh323 menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable chan_mgcp menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable app_skel menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_events menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_bridges menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_channels menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_device_states menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_endpoints menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_playbacks menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_recordings menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_ari_sounds menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_stasis_playback menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_stasis_recording menuselect.makeopts 2>/dev/null || true
menuselect/menuselect --disable res_config_sqlite3 menuselect.makeopts 2>/dev/null || true

# Включаем выбранные звуки (в зависимости от пресета)
for sound in $CORE_SOUNDS_ENABLED; do
    menuselect/menuselect --enable "$sound" menuselect.makeopts
done

# Отключаем ненужные форматы звуков
for sound in $CORE_SOUNDS_DISABLED; do
    menuselect/menuselect --disable "$sound" menuselect.makeopts
done

# Компиляция и установка
make -j$(nproc)
make install
make install-core-sounds
make config
make samples

# Создание пустого modules.conf, чтобы избежать ошибки при запуске
if [ ! -f /etc/asterisk/modules.conf ]; then
    touch /etc/asterisk/modules.conf
fi

# -----------------------------------------------------------------------------
# 11. Настройка systemd сервиса Asterisk
# -----------------------------------------------------------------------------
echo "[5/12] Настройка systemd сервиса Asterisk..."

# Удаляем старый init-скрипт, чтобы systemd использовал наш юнит
update-rc.d asterisk remove 2>/dev/null || true
rm -f /etc/init.d/asterisk

# Создаем корректный systemd unit файл
cat > /etc/systemd/system/asterisk.service <<EOF
[Unit]
Description=Asterisk PBX and telephony daemon
After=network.target mariadb.service

[Service]
Type=simple
User=$AST_USER
Group=$AST_GROUP
WorkingDirectory=/var/lib/asterisk
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
ExecReload=/usr/sbin/asterisk -rx 'core reload'
ExecStop=/usr/sbin/asterisk -rx 'core stop now'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable asterisk
systemctl start asterisk

# -----------------------------------------------------------------------------
# 12. Базовая настройка Asterisk (транспорт, 30 экстеншенов, диалплан)
# -----------------------------------------------------------------------------
echo "[6/12] Настройка Asterisk (транспорт, 30 экстеншенов, простой диалплан)..."

mkdir -p /var/lib/asterisk/{sounds,recordings,monitor}

# Настройка pjsip.conf: создаем транспорт и 30 экстеншенов (с 6001 по 6030)
cat > /etc/asterisk/pjsip.conf <<EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

EOF

for i in $(seq 6001 6030); do
    cat >> /etc/asterisk/pjsip.conf <<EOF
[$i]
type=endpoint
context=internal
disallow=all
allow=ulaw
allow=alaw
allow=gsm
allow=g722
transport=transport-udp
auth=$i-auth
aors=$i-aor

[$i-auth]
type=auth
auth_type=userpass
username=$i
password=${i}pbx

[$i-aor]
type=aor
max_contacts=1

EOF
done

# Настройка extensions.conf для маршрутизации между 30 номерами
cat > /etc/asterisk/extensions.conf <<EOF
[general]
static=yes
writeprotect=no

[globals]

[internal]
exten => _600X,1,Dial(PJSIP/\${EXTEN},30)
exten => _600X,n,Hangup()

exten => _60[1-3]X,1,Dial(PJSIP/\${EXTEN},30)
exten => _60[1-3]X,n,Hangup()

exten => _[1-9]XX,1,Verbose(2, Unknow extension, perhaps outside line)
exten => _[1-9]XX,n,Playback(invalid)
exten => _[1-9]XX,n,Hangup()
EOF

# -----------------------------------------------------------------------------
# 13. Настройка прав доступа к файлам Asterisk
# -----------------------------------------------------------------------------
chown -R $AST_USER:$AST_GROUP /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk
chmod -R 755 /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk

# Перезапуск Asterisk для применения конфигурации
systemctl restart asterisk

# -----------------------------------------------------------------------------
# 14. Установка FreePBX 17 из официального репозитория GitHub
# -----------------------------------------------------------------------------
echo "[7/12] Установка FreePBX 17..."

cd /tmp
wget https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh
chmod +x sng_freepbx_debian_install.sh

# Важно: Используем флаг --opensourceonly
bash ./sng_freepbx_debian_install.sh --opensourceonly

# После установки FreePBX некоторые файлы могли перезаписаться. Переустанавливаем права.
chown -R $AST_USER:$AST_GROUP /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk

# -----------------------------------------------------------------------------
# 15. Конфигурация базы данных для FreePBX
# -----------------------------------------------------------------------------
echo "[8/12] Тонкая настройка базы данных MariaDB..."

mysql <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS asterisk;
CREATE DATABASE IF NOT EXISTS asteriskcdrdb;
GRANT ALL PRIVILEGES ON asterisk.* TO 'freepbxuser'@'localhost' IDENTIFIED BY '${FREEPBX_DB_PASS}';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'freepbxuser'@'localhost';
FLUSH PRIVILEGES;
EOF

# Настройка подключения FreePBX к базе данных
cat > /etc/freepbx.conf <<EOF
<?php
\$amp_conf['AMPDBUSER'] = 'freepbxuser';
\$amp_conf['AMPDBPASS'] = '${FREEPBX_DB_PASS}';
\$amp_conf['AMPDBHOST'] = 'localhost';
\$amp_conf['AMPDBNAME'] = 'asterisk';
\$amp_conf['AMPDBENGINE'] = 'mysql';
?>
EOF

# -----------------------------------------------------------------------------
# 16. Финальные настройки
# -----------------------------------------------------------------------------
echo "[9/12] Финальная настройка сервисов..."

# Настройка веб-сервера Apache для FreePBX
a2enmod rewrite
systemctl restart apache2

# Настройка прав на директории для веб-интерфейса
mkdir -p /var/www/html
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# Выполнение начальной настройки FreePBX через консоль
sudo -u $AST_USER fwconsole ma downloadinstall userman
sudo -u $AST_USER fwconsole reload

# Финальная перезагрузка всех сервисов
systemctl restart mariadb
systemctl restart asterisk
systemctl restart apache2

# -----------------------------------------------------------------------------
# 17. Заключительная информация
# -----------------------------------------------------------------------------
echo "================================================================"
echo "Установка успешно завершена!"
echo "================================================================"
echo "Asterisk и FreePBX 17 установлены и настроены."
echo "База данных:"
echo "  - Имя БД: asterisk, asteriskcdrdb"
echo "  - Пользователь: freepbxuser"
echo "  - Пароль: ${FREEPBX_DB_PASS}"
echo "================================================================"
echo "Для доступа к веб-интерфейсу FreePBX откройте в браузере:"
echo "http://$(hostname -I | awk '{print $1}')"
echo "================================================================"
echo "Для подключения SIP-телефонов используйте:"
echo "  - Сервер: IP этого сервера"
echo "  - Порт: 5060 (UDP)"
echo "  - Диапазон номеров: 6001 - 6030"
echo "  - Пароль для номера XXXX: XXXXpbx (например, для 6001 пароль 6001pbx)"
echo "================================================================"
echo "Для начала работы с FreePBX выполните первичную настройку:"
echo "# fwconsole ma downloadinstall userman"
echo "# fwconsole ma downloadinstall certman"
echo "# fwconsole reload"
echo "================================================================"
echo "Логи установки: /var/log/voip_full_install.log"
echo "=== Установка закончена: $(date) ==="
