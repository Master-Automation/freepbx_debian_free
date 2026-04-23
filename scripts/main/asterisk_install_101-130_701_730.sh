cat > asterisk_full.sh << 'SCRIPT_EOF'
#!/bin/bash
set -e
exec > >(tee -a /var/log/asterisk_install.log) 2>&1
echo "=== Начало установки чистого Asterisk: $(date) ==="

AST_USER="asterisk"
AST_GROUP="asterisk"

echo "[1/10] Очистка и проверка..."
if [[ $EUID -ne 0 ]]; then echo "Запустите от root"; exit 1; fi
systemctl stop asterisk 2>/dev/null || true
rm -rf /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk /usr/sbin/asterisk

# Удаляем оставшийся файл репозитория FreePBX
rm -f /etc/apt/sources.list.d/freepbx.list 2>/dev/null

# Убираем дубликаты из основного sources.list (если они там есть)
if [ -f /etc/apt/sources.list ]; then
    awk '!seen[$0]++' /etc/apt/sources.list > /etc/apt/sources.list.clean \
        && mv /etc/apt/sources.list.clean /etc/apt/sources.list
fi


echo "[2/10] Установка зависимостей..."
apt-get update
apt-get install -y wget curl git build-essential pkg-config libedit-dev libjansson-dev libsqlite3-dev uuid-dev libxml2-dev libssl-dev libncurses5-dev unixodbc-dev unixodbc python3 python3-pip sox mpg123

echo "[3/10] Создание пользователя..."
if ! getent group "$AST_GROUP" >/dev/null; then addgroup --system "$AST_GROUP"; fi
if ! id -u "$AST_USER" >/dev/null 2>&1; then adduser --system --ingroup "$AST_GROUP" --home /var/lib/asterisk --no-create-home --gecos "Asterisk PBX" "$AST_USER"; fi

echo "[4/10] Сборка Asterisk 22..."
mkdir -p /usr/src/asterisk
cd /usr/src/asterisk
rm -rf asterisk-*
wget -q https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz
tar xf asterisk-22-current.tar.gz
rm asterisk-22-current.tar.gz
cd asterisk-22.*
contrib/scripts/install_prereq install
./configure --with-pjproject-bundled --with-jansson-bundle --libdir=/usr/lib/x86_64-linux-gnu
make menuselect.makeopts
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts
menuselect/menuselect --disable chan_ooh323 menuselect.makeopts
menuselect/menuselect --disable chan_mgcp menuselect.makeopts
make -j$(nproc)
make install
make install-core-sounds
make config
make samples

echo "[5/10] Конфигурация pjsip.conf..."
cat > /etc/asterisk/pjsip.conf <<EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
EOF

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

echo "[6/10] Конфигурация extensions.conf..."
cat > /etc/asterisk/extensions.conf <<'EOF'
[general]
static=yes
writeprotect=no

[internal]
exten => _10[1-9],1,Dial(PJSIP/${EXTEN},30)
exten => _10[1-9],n,Hangup()
exten => _11[0-9],1,Dial(PJSIP/${EXTEN},30)
exten => _11[0-9],n,Hangup()
exten => _12[0-9],1,Dial(PJSIP/${EXTEN},30)
exten => _12[0-9],n,Hangup()
exten => 130,1,Dial(PJSIP/130,30)
exten => 130,n,Hangup()
exten => _70[1-9],1,Dial(PJSIP/${EXTEN},30)
exten => _70[1-9],n,Hangup()
exten => _71[0-9],1,Dial(PJSIP/${EXTEN},30)
exten => _71[0-9],n,Hangup()
exten => _72[0-9],1,Dial(PJSIP/${EXTEN},30)
exten => _72[0-9],n,Hangup()
exten => 730,1,Dial(PJSIP/730,30)
exten => 730,n,Hangup()
exten => _X.,1,Playback(invalid)
exten => _X.,n,Hangup()
EOF

echo "[7/10] Дополнительные конфиги..."
[ ! -f /etc/asterisk/modules.conf ] && echo -e "[modules]\nautoload=yes" > /etc/asterisk/modules.conf
[ ! -f /etc/asterisk/logger.conf ] && cat > /etc/asterisk/logger.conf <<EOF
[general]
dateformat=%F %T
[logfiles]
console => notice,warning,error
full => notice,warning,error,debug,verbose
EOF
mkdir -p /var/run/asterisk
chown $AST_USER:$AST_GROUP /var/run/asterisk

echo "[8/10] Настройка systemd..."
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
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable asterisk

echo "[9/10] Права и запуск..."
chown -R $AST_USER:$AST_GROUP /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk
chmod -R 755 /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk
systemctl start asterisk
sleep 3

echo "[10/10] Проверка..."
asterisk -rx "core show version"
asterisk -rx "pjsip show endpoints" | head -20

# ===============================
# ПРЕДЛОЖЕНИЕ СОЗДАТЬ БЭКАП
# ===============================
echo ""
echo "=============================================="
echo " Установка Asterisk завершена успешно!"
echo "=============================================="
echo " Для быстрого восстановления системы в офлайн-режиме"
echo " вы можете создать полный образ (снапшот) виртуальной машины"
echo " и/или архив конфигурационных файлов."
echo ""
echo " Чтобы создать архив конфигураций (лёгкий бэкап):"
echo "   sudo tar czf /root/asterisk_backup_$(date +%Y%m%d).tar.gz \\"
echo "     /etc/asterisk /var/lib/asterisk /usr/lib/asterisk /var/log/asterisk"
echo ""
echo " Для полного образа системы (если вы в виртуальной среде):"
echo "   - В каталоге вашей виртуализации сделайте клон/снапшот ВМ."
echo "   - Или создайте образ диска с помощью Clonezilla/dd."
echo ""
echo " Рекомендуется также сохранить этот скрипт для повторной установки."
echo "=============================================="

echo "=== Установка завершена! ==="

SCRIPT_EOF

chmod +x asterisk_full.sh
sudo ./asterisk_full.sh
