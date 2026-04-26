cat > /tmp/freepbx_check.sh << 'SCRIPT_EOF'
#!/bin/bash

# === Цвета для вывода ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

OK="${GREEN}[  OK  ]${NC}"
WARN="${YELLOW}[ WARN ]${NC}"
FAIL="${RED}[ FAIL ]${NC}"
INFO="[ INFO ]"

echo "============================================="
echo " Диагностика FreePBX / Asterisk"
echo " Дата: $(date)"
echo "============================================="
echo ""

# ------------------------------
# 1. Состояние сервисов
# ------------------------------
echo ">>> 1. Службы"
for srv in httpd asterisk mariadb; do
    if systemctl is-active --quiet $srv; then
        echo -e "${OK} $srv активен"
    else
        echo -e "${FAIL} $srv остановлен!"
    fi
done
echo ""

# ------------------------------
# 2. Порты
# ------------------------------
echo ">>> 2. Прослушиваемые порты"
for port in 80 443 5060 5160 8088; do
    if ss -tlnp | grep -q ":$port "; then
        echo -e "${OK} порт $port слушается"
    else
        echo -e "${WARN} порт $port не слушается (возможно, не используется)"
    fi
done
echo ""

# ------------------------------
# 3. Firewall статус
# ------------------------------
echo ">>> 3. Responsive Firewall"
fwconsole firewall status 2>/dev/null | head -1
echo ""

# ------------------------------
# 4. Кастомные контексты
# ------------------------------
echo ">>> 4. Контексты в extensions_custom.conf"
CUSTOM="/etc/asterisk/extensions_custom.conf"
if [ -f "$CUSTOM" ]; then
    for ctx in handler_registration from-internal-message; do
        if grep -q "^\[$ctx\]" "$CUSTOM"; then
            echo -e "${OK} Контекст [$ctx] присутствует"
        else
            echo -e "${FAIL} Контекст [$ctx] отсутствует!"
        fi
    done
    # Проверка синтаксиса при загрузке диалплана
    SYNTAX=$(asterisk -rx "dialplan reload" 2>&1)
    if echo "$SYNTAX" | grep -q "Error"; then
        echo -e "${FAIL} Ошибка загрузки диалплана:"
        echo "$SYNTAX" | grep -i error | tail -5
    else
        echo -e "${OK} Загрузка диалплана без ошибок"
    fi
else
    echo -e "${WARN} Файл extensions_custom.conf не найден"
fi
echo ""

# ------------------------------
# 5. AstDB: типы устройств и флаги
# ------------------------------
echo ">>> 5. AstDB: DEVICE_TYPE и MSG_ENABLED"
for key in DEVICE_TYPE MSG_ENABLED; do
    COUNT=$(asterisk -rx "database show $key" | grep -c "/$key/")
    echo -e "${INFO} Найдено $COUNT записей для $key"
    if [ "$COUNT" -gt 0 ]; then
        asterisk -rx "database show $key" | grep "/$key/" | while read -r line; do
            echo "    $line"
        done
    fi
done
echo ""

# ------------------------------
# 6. Последние ошибки в логах
# ------------------------------
echo ">>> 6. Последние ошибки в логах (последние 5 строк)"
for log in /var/log/asterisk/full /var/log/httpd/error_log /var/log/asterisk/freepbx.log; do
    if [ -f "$log" ]; then
        ERRORS=$(tail -100 "$log" | grep -i -E "error|fail|warn" | tail -5)
        if [ -n "$ERRORS" ]; then
            echo -e "${WARN} Ошибки в $log:"
            echo "$ERRORS"
        else
            echo -e "${OK} $log — без ошибок"
        fi
    else
        echo -e "${INFO} $log не существует"
    fi
done
echo ""

# ------------------------------
# 7. Место на диске
# ------------------------------
echo ">>> 7. Дисковое пространство"
df -h / /var/spool/asterisk/monitor 2>/dev/null | tail -2 | while read -r line; do
    USE=$(echo "$line" | awk '{print $5}' | sed 's/%//')
    if [ "$USE" -gt 90 ]; then
        echo -e "${FAIL} $line (заполнение >90%)"
    elif [ "$USE" -gt 75 ]; then
        echo -e "${WARN} $line (заполнение >75%)"
    else
        echo -e "${OK} $line"
    fi
done
echo ""

# ------------------------------
# 8. Нагрузка CPU и память
# ------------------------------
echo ">>> 8. Нагрузка"
LOAD=$(uptime | awk -F'load average:' '{print $2}')
echo -e "${INFO} Load average: $LOAD"
free -h | grep -E "^Mem|^Swap" | while read -r line; do
    echo "    $line"
done
echo ""

# ------------------------------
# 9. Обновления модулей
# ------------------------------
echo ">>> 9. Обновления модулей"
OUT=$(fwconsole ma check 2>&1)
if echo "$OUT" | grep -q "No repos"; then
    echo -e "${WARN} Не удалось проверить обновления (нет интернета?)"
else
    UPD=$(echo "$OUT" | grep -c "Upgrade")
    echo -e "${INFO} Доступно обновлений: $UPD"
fi
echo ""

# ------------------------------
# 10. Регистрации PJSIP
# ------------------------------
echo ">>> 10. Активные регистрации (PJSIP)"
CONTACTS=$(asterisk -rx "pjsip show contacts" 2>/dev/null | grep -v "Contact:" | grep -E "^\s+[0-9]")
if [ -n "$CONTACTS" ]; then
    echo "$CONTACTS"
    ONLINE=$(echo "$CONTACTS" | grep -c "Avail")
    echo -e "${INFO} Онлайн регистраций: $ONLINE"
else
    echo -e "${WARN} Нет активных регистраций"
fi
echo ""

# ------------------------------
# Итог
# ------------------------------
echo "============================================="
echo " Диагностика завершена."
echo " Проверьте строки, помеченные ${FAIL} или ${WARN}."
echo "============================================="
SCRIPT_EOF

chmod +x /tmp/freepbx_check.sh
/tmp/freepbx_check.sh
