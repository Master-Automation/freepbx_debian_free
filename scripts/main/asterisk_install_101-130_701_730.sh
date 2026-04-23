#!/bin/bash
# =============================================================================
# Скрипт чистой установки Asterisk 22 с внутренними номерами 101-130, 701-730
# Автоматическая настройка, без FreePBX.
# Телефоны: 101-130 (пароль: <номер>pbx), 701-730 (пароль: <номер>pbx)
# Преимущество: полный контроль над модулями и конфигурацией.
# =============================================================================
set -e
exec > >(tee -a /var/log/asterisk_custom_install.log) 2>&1
echo "=== Начало установки чистого Asterisk: $(date) ==="

# ---------- Переменные ----------
AST_USER="asterisk"
AST_GROUP="asterisk"
AST_VERSION="22"
TIMEZONE="Europe/Moscow"

# Пресет (можно переопределить при запуске: sudo PRESET=ru_fast ./install_asterisk_custom.sh)
PRESET="${PRESET:-default}"

# Настройки по умолчанию (зеркала, звуки)
APT_MIRROR_BASE="http://deb.debian.org/debian"
APT_SECURITY="http://security.debian.org/debian-security"
CORE_SOUNDS_ENABLED="CORE-SOUNDS-EN-GSM CORE-SOUNDS-EN-ALAW"
CORE_SOUNDS_DISABLED="CORE-SOUNDS-EN-WAV CORE-SOUNDS-EN-ULAW CORE-SOUNDS-RU-WAV CORE-SOUNDS-RU-ULAW CORE-SOUNDS-RU-GSM CORE-SOUNDS-RU-ALAW"

# Разбор аргументов (если передан --preset)
if [[ "$1" == "--preset" && -n "$2" ]]; then
    PRESET="$2"
    shift 2
fi

case "$PRESET" in
    default|ru_fast)
        echo "Выбран пресет: $PRESET"
        ;;
    *)
        echo "Неизвестный пресет '$PRESET', используется default"
        PRESET="default"
        ;;
esac

if [[ "$PRESET" == "ru_fast" ]]; then
    APT_MIRROR_BASE="http://mirror.yandex.ru/debian"
    APT_SECURITY="http://mirror.yandex.ru/debian-security"
    CORE_SOUNDS_ENABLED="$CORE_SOUNDS_ENABLED CORE-SOUNDS-RU-GSM CORE-SOUNDS-RU-ALAW"
    CORE_SOUNDS_DISABLED="CORE-SOUNDS-EN-WAV CORE-SOUNDS-EN-ULAW CORE-SOUNDS-RU-WAV CORE-SOUNDS-RU-ULAW"
fi

# ---------- 1. Проверка прав и очистка ----------
if [[ $EUID -ne 0 ]]; then echo "Запустите от root!"; exit 1; fi
echo "[1/10] Проверка системы и очистка..."
systemctl stop asterisk 2>/dev/null || true
apt-get remove --purge -y asterisk* 2>/dev/null || true
apt-get autoremove --purge -y
rm -rf /etc/asterisk /usr/lib/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/sbin/asterisk /usr/src/asterisk-*
userdel -r $AST_USER 2>/dev/null || true
groupdel $AST_GROUP 2>/dev/null || true
apt-get clean

# ---------- 2. Настройка APT и установка зависимостей ----------
echo "[2/10] Настройка APT..."
cat > /etc/apt/sources.list <<EOF
deb ${APT_MIRROR_BASE} bookworm main contrib non-free non-free-firmware
deb ${APT_MIRROR_BASE} bookworm-updates main contrib non-free non-free-firmware
deb ${APT_SECURITY} bookworm-security main contrib non-free non-free-firmware
EOF
apt-get update

echo "[3/10] Установка зависимостей..."
apt-get install -y wget curl gnupg2 git build-essential pkg-config \
    libedit-dev libjansson-dev libsqlite3-dev uuid-dev libxml2-dev libssl-dev \
    libncurses5-dev liburiparser-dev libxslt1-dev unixodbc-dev unixodbc \
    python3 python3-pip sox mpg123 net-tools sngrep

# ---------- 3. Создание пользователя ----------
echo "[4/10] Создание пользователя asterisk..."
if ! getent group "$AST_GROUP" >/dev/null; then addgroup --system "$AST_GROUP"; fi
if ! id -u "$AST_USER" >/dev/null 2>&1; then
    adduser --system --ingroup "$AST_GROUP" --home /var/lib/asterisk --no-create-home --gecos "Asterisk PBX" "$AST_USER"
fi
usermod -a -G audio,dialout "$AST_USER"

# ---------- 4. Сборка Asterisk 22 ----------
echo "[5/10] Загрузка и сборка Asterisk 22..."
mkdir -p /usr/src/asterisk
cd /usr/src/asterisk
rm -rf asterisk-*
wget -q https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
tar xf asterisk-22-current.tar.gz
rm asterisk-22-current.tar.gz
cd asterisk-22.*

contrib/scripts/install_prereq install

./configure --with-pjproject-bundled --with-jansson-bundle --libdir=/usr/lib/x86_64-linux-gnu

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

# Включаем/отключаем звуки согласно пресету
for sound in $CORE_SOUNDS_ENABLED; do
    menuselect/menuselect --enable "$sound" menuselect.makeopts 2>/dev/null || true
done
for sound in $CORE_SOUNDS_DISABLED; do
    menuselect/menuselect --disable "$sound" menuselect.makeopts 2>/dev/null || true
done

make -j$(nproc)
make install
make install-core-sounds
make config
make samples

# ---------- 5. Конфигурация Asterisk ----------
echo "[6/10] Генерация конфигурационных файлов..."

# Создаём необходимые папки
mkdir -p /var/run/asterisk /var/lib/asterisk/sounds /var/lib/asterisk/recordings
chown $AST_USER:$AST_GROUP /var/run/asterisk /var/lib/asterisk /var/log/asterisk

# ---- PJSIP: транспорт и все учётные записи ----
echo "[*] Создание pjsip.conf..."
cat > /etc/asterisk/pjsip.conf <<EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

; -----------------------------------------------
EOF

# Генерируем диапазон 101-130
for i in $(seq 101 130); do
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
auth=${i}-auth
aors=${i}-aor

[${i}-auth]
type=auth
auth_type=userpass
username=$i
password=${i}pbx

[${i}-aor]
type=aor
max_contacts=1

EOF
done

# Генерируем диапазон 701-730
for i in $(seq 701 730); do
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
auth=${i}-auth
aors=${i}-aor

[${i}-auth]
type=auth
auth_type=userpass
username=$i
password=${i}pbx

[${i}-aor]
type=aor
max_contacts=1

EOF
done

# ---- Extensions.conf: диалплан для внутренних звонков ----
echo "[*] Создание extensions.conf..."
cat > /etc/asterisk/extensions.conf <<EOF
[general]
static=yes
writeprotect=no

[internal]
; Диапазон 101-109
exten => _10[1-9],1,Dial(PJSIP/\${EXTEN},30)
exten => _10[1-9],n,Hangup()

; 110-119
exten => _11[0-9],1,Dial(PJSIP/\${EXTEN},30)
exten => _11[0-9],n,Hangup()

; 120-129
exten => _12[0-9],1,Dial(PJSIP/\${EXTEN},30)
exten => _12[0-9],n,Hangup()

; 130 (отдельно, так как не входит в шаблон)
exten => 130,1,Dial(PJSIP/130,30)
exten => 130,n,Hangup()

; Диапазон 701-709
exten => _70[1-9],1,Dial(PJSIP/\${EXTEN},30)
exten => _70[1-9],n,Hangup()

; 710-719
exten => _71[0-9],1,Dial(PJSIP/\${EXTEN},30)
exten => _71[0-9],n,Hangup()

; 720-729
exten => _72[0-9],1,Dial(PJSIP/\${EXTEN},30)
exten => _72[0-9],n,Hangup()

; 730
exten => 730,1,Dial(PJSIP/730,30)
exten => 730,n,Hangup()

; Если набрали что-то другое – сообщение о неверном номере
exten => _X.,1,NoOp(Invalid extension \${EXTEN})
exten => _X.,n,Playback(invalid)
exten => _X.,n,Hangup()
EOF

# Дополнительные конфиги для стабильности
[ ! -f /etc/asterisk/modules.conf ] && echo -e "[modules]\nautoload=yes" > /etc/asterisk/modules.conf
[ ! -f /etc/asterisk/stasis.conf ] && echo -e "[stasis]\nminimum_size = 1" > /etc/asterisk/stasis.conf
[ ! -f /etc/asterisk/logger.conf ] && cat > /etc/asterisk/logger.conf <<EOF
[general]
dateformat=%F %T
[logfiles]
console => notice,warning,error
full => notice,warning,error,debug,verbose
EOF

# ---------- 6. systemd сервис ----------
echo "[7/10] Настройка systemd..."
cat > /etc/systemd/system/asterisk.service <<EOF
[Unit]
Description=Asterisk PBX
After=network.target

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

# ---------- 7. Права и запуск ----------
echo "[8/10] Установка прав..."
chown -R $AST_USER:$AST_GROUP /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk
chmod -R 755 /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk

echo "[9/10] Запуск Asterisk..."
systemctl start asterisk
sleep 3

# Проверка
echo "[10/10] Проверка состояния..."
asterisk -rx "core show version"
asterisk -rx "pjsip show endpoints" | head -5
echo "=== Установка завершена! ==="
echo "Телефоны можно регистрировать на IP-адрес сервера, порт 5060 (UDP)."
echo "Пример для номера 115: логин 115, пароль 115pbx."
echo "Для проверки наберите другой внутренний номер, например 101."
