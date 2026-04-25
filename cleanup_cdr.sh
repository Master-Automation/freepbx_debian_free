#!/bin/bash
# ======================================================================
#  Script: cleanup_cdr.sh
#  Version: 1.0
#  Created: 2026-04-25
#  Author: Master-automantion@mail.ru
#  Description:
#    Удаляет записи CDR (истории звонков) старше заданного количества дней
#    и выполняет оптимизацию таблицы cdr для повышения производительности.
#    Пароль БД извлекается из /etc/amportal.conf или /etc/freepbx.conf.
# ======================================================================
echo ""
echo "   ╔══════════════════════════════════════════════════════════╗ "
echo "   ║                 MASTER AUTOMATION 2026                   ║ "
echo "   ╚══════════════════════════════════════════════════════════╝ "
echo ""
#
# ======================================================================
#  IMPORTANT: This script will DELETE old call detail records (CDR)
#  and then OPTIMIZE the table. Make sure you have a backup before
#  running it for the first time.
# ======================================================================
#
#  Конфигурация скрипта:
DAYS=1095                # Критическая глубина архива:_____дней
SIZE_LIMIT_MB=10240      # Критический размер всей БД в МБ
RECORDS_LIMIT=2000000    # Критическое количество записей в CDR
DB_USER="freepbxuser"    # Имя пользователя БД
DB_NAME="asteriskcdrdb"  # Имя БД
TABLE_NAME="cdr"         # Имя таблицы
#
# ======================================================================

# Функция логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# --- Извлечение пароля (один раз) ---
DB_PASS=""
if [ -f /etc/freepbx.conf ]; then
    DB_PASS=$(grep 'AMPDBPASS' /etc/freepbx.conf | sed -E 's/.*"([^"]+)".*/\1/')
fi
if [ -z "$DB_PASS" ] && [ -f /etc/amportal.conf ]; then
    DB_PASS=$(grep -E "^AMPDBPASS=" /etc/amportal.conf | cut -d= -f2- | tr -d '"' | head -1)
fi

if [ -z "$DB_PASS" ]; then
    echo "ОШИБКА: Не удалось извлечь пароль БД"
    exit 1
fi

# ======================================================================
#  Вывод текущей конфигурации скрипта
# ======================================================================
echo "  Критическая глубина архива: $DAYS дней"
echo "  Критический размер всей БД в МБ: $SIZE_LIMIT_MB"
echo "  Критическое количество записей в CDR: $RECORDS_LIMIT"
echo "  Имя пользователя БД: $DB_USER"
echo "  Имя БД: $DB_NAME"
echo "  Имя таблицы: $TABLE_NAME"
echo "======================================================================"

# --- Получение текущих показателей ---
CURRENT_SIZE_MB=$(mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
SELECT ROUND(SUM(data_length + index_length)/1024/1024, 0)
FROM information_schema.tables WHERE table_schema='asteriskcdrdb';" 2>/dev/null)

CURRENT_RECORDS=$(mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
SELECT COUNT(*) FROM cdr;" 2>/dev/null)

log "Текущий размер БД: ${CURRENT_SIZE_MB} МБ (лимит: ${SIZE_LIMIT_MB} МБ)."
log "Текущее кол-во записей в CDR: ${CURRENT_RECORDS} (лимит: ${RECORDS_LIMIT})."

# --- Проверка и, при необходимости, корректировка срока хранения ---
if [ "$CURRENT_SIZE_MB" -gt "$SIZE_LIMIT_MB" ] || [ "$CURRENT_RECORDS" -gt "$RECORDS_LIMIT" ]; then
    log "ВНИМАНИЕ: Превышен лимит БД! Срочное уменьшение срока хранения."
    DAYS=$((DAYS / 2))
    log "Новый срок хранения (DAYS) установлен на: $DAYS дней."
fi

# --- Подключение к БД и отчёты ---
log "Подключение к базе данных MySQL..."

if ! mysql -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1" "$DB_NAME" &>/dev/null; then
    log "ОШИБКА: Не удалось подключиться к базе данных. Скрипт остановлен."
    exit 1
fi

log "Подключение к БД успешно"

# Функция подсчёта записей в таблице cdr
count_cdr_records() {
    local title="$1"
    local count=$(mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "SELECT COUNT(*) FROM cdr;" 2>/dev/null)
    if [ -n "$count" ]; then
        log "$title: $count записей"
    else
        log "ОШИБКА: Не удалось получить количество записей"
    fi
}

# Функция для вывода размера таблиц БД
report_db_size() {
    local title="$1"
    echo ""
    echo "=== $title ==="
    mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
    SELECT
        table_name AS 'Таблица',
        ROUND(data_length/1024/1024, 2) AS 'Данные, МБ',
        ROUND(index_length/1024/1024, 2) AS 'Индексы, МБ',
        ROUND((data_length+index_length)/1024/1024, 2) AS 'Всего, МБ'
    FROM information_schema.tables
    WHERE table_schema='asteriskcdrdb'
    ORDER BY (data_length+index_length) DESC;
    " 2>/dev/null
    echo "==========================================="
}

echo "======================================================================"
echo "  CDR Cleanup & Optimization Script v1.2"
echo "======================================================================"
echo "Конфигурация: Удалить записи старше $DAYS дней ($((DAYS / 365)) лет)"
echo ""

log "Скрипт запущен"

# Вывод статистических сведений о таблице БД.
count_cdr_records "Количество записей в CDR до очистки"
report_db_size "РАЗМЕР ТАБЛИЦ ДО ОЧИСТКИ"

log "Поиск записей старше $DAYS дней"

# --- Подсчёт старых записей ---
OLD_COUNT=$(mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "SELECT COUNT(*) FROM $TABLE_NAME WHERE calldate < DATE_SUB(NOW(), INTERVAL $DAYS DAY);")
log "Найдено $OLD_COUNT записей старше $DAYS дней (примерно $((DAYS / 365)) лет)"

# --- Удаление и оптимизация (если есть) ---
if [ "$OLD_COUNT" -gt 0 ]; then
    log "Удаляю старые записи..."
    mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "DELETE FROM $TABLE_NAME WHERE calldate < DATE_SUB(NOW(), INTERVAL $DAYS DAY);"
    if [ $? -eq 0 ]; then
        log "Удаление выполнено успешно"
        log "Оптимизирую таблицу $TABLE_NAME..."
        mysqlcheck --optimize "$DB_NAME" "$TABLE_NAME" -u"$DB_USER" -p"$DB_PASS"
        if [ $? -eq 0 ]; then
            log "Оптимизация выполнена успешно"
        else
            log "ОШИБКА при оптимизации таблицы"
        fi
    else
        log "ОШИБКА при удалении записей"
        exit 2
    fi
else
    log "Нет записей старше $DAYS дней. Очистка не требуется"
fi

# Обновляем резервную копию на втором диске (если он примонтирован)
if mountpoint -q /mnt/storage; then
    cp "$0" /mnt/storage/FreePBX-16/scripts/cleanup_cdr.sh
    log "Резервная копия скрипта обновлена на втором диске"
else
    log "Второй диск не примонтирован, резервная копия не обновлена"
fi

count_cdr_records "Количество записей в CDR после очистки"
report_db_size "РАЗМЕР ТАБЛИЦ ПОСЛЕ ОЧИСТКИ"

log "Скрипт завершён"
echo "======================================================================"
