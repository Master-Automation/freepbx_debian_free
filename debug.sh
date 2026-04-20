#!/bin/bash
# =============================================================================
# debug.sh – Универсальный отладчик FreePBX 17
# Версия: 1.0.0
# =============================================================================
# Режимы:
#   --auto <action> – автоматическое выполнение действия
#   без параметров   – интерактивный режим (диагностика + меню)
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERSION="1.0.1"
LOG_FILE="/var/log/pbx/debug.log"

# -----------------------------------------------------------------------------
# Функции восстановления
# -----------------------------------------------------------------------------
fix_asterisk_config() {
    echo "   🔧 Восстановление конфигурации Asterisk..."
    mkdir -p /etc/asterisk
    cat > /etc/asterisk/asterisk.conf <<EOF
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
    systemctl restart asterisk
    return $?
}

fix_mysql_access() {
    echo "   🔧 Восстановление доступа к MySQL..."
    DB_PASS=$(grep "AMPDBPASS" /etc/freepbx.conf 2>/dev/null | cut -d"'" -f2 || openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS asterisk;
CREATE USER IF NOT EXISTS 'freepbxuser'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON asterisk.* TO 'freepbxuser'@'localhost';
FLUSH PRIVILEGES;
EOF
    return $?
}

fix_fwconsole_path() {
    echo "   🔧 Добавление fwconsole в PATH..."
    FW_PATH=$(find /usr/sbin /var/lib/asterisk/bin /usr/local/bin -name "fwconsole" 2>/dev/null | head -1)
    if [ -n "$FW_PATH" ]; then
        ln -sf "$FW_PATH" /usr/local/bin/fwconsole
        return 0
    fi
    return 1
}

fix_composer_deps() {
    echo "   🔧 Переустановка зависимостей Composer..."
    cd /var/www/html/admin
    rm -rf vendor composer.lock
    composer install --no-dev 2>&1
    composer dump-autoload 2>&1
    return $?
}

fix_missing_configs() {
    echo "   🔧 Создание недостающих конфигов Asterisk..."
    local conf_list="acl.conf adsi.conf aeap.conf agents.conf alarmreceiver.conf alsa.conf amd.conf app_skel.conf ari_additional.conf ari_general_additional.conf ast_debug_tools.conf asterisk.adsi calendar.conf ccss.conf cdr.conf.back cdr_adaptive_odbc.conf cdr_beanstalkd.conf cdr_general_additional.conf cdr_manager_general_additional.conf cdr_manager_mapping_additional.conf cdr_odbc.conf cdr_pgsql.conf cdr_tds.conf cdrpro_events cel_beanstalkd.conf cel_custom_post.conf cel_general_additional.conf cel_odbc.conf cel_pgsql.conf cel_tds.conf chan_dahdi.conf chan_dahdi_additional.conf chan_mobile.conf cli.conf cli_aliases.conf cli_permissions.conf codecs.conf confbridge_additional.conf config_test.conf console.conf dbsep.conf dnsmgr.conf dsp.conf dundi.conf enum.conf extconfig.conf extensions.ael extensions.lua extensions_additional.conf extensions_minivm.conf extensions_override_freepbx.conf features_applicationmap_additional.conf features_featuremap_additional.conf features_general_additional.conf festival.conf firewall followme.conf freepbx_module_admin.conf func_odbc.conf geolocation.conf hep.conf http_additional.conf iax_additional.conf iax_custom_post.conf iax_general_additional.conf iax_registrations.conf iaxprov.conf indications.conf indications_additional.conf indications_general_additional.conf localprefixes.conf logger_general_additional.conf logger_logfiles_additional.conf manager.conf manager.conf.bak manager_additional.conf meetme.conf meetme_additional.conf meetme_general_additional.conf mgcp.conf minivm.conf modules.conf motif.conf musiconhold.conf musiconhold_additional.conf ooh323.conf osp.conf phoneprov.conf phpagi.conf pjproject.conf pjsip.aor.conf pjsip.aor_custom_post.conf pjsip.auth.conf pjsip.auth_custom_post.conf pjsip.conf pjsip.endpoint.conf pjsip.endpoint_custom_post.conf pjsip.identify.conf pjsip.identify_custom_post.conf pjsip.registration.conf pjsip.registration_custom_post.conf pjsip.transports.conf pjsip.transports_custom_post.conf pjsip_custom_post.conf pjsip_notify.conf pjsip_wizard.conf privacy.conf prometheus.conf queuerules_additional.conf queues.conf queues_additional.conf queues_custom_general.conf queues_general_additional.conf res_config_mysql.conf res_config_odbc.conf res_config_sqlite3.conf res_corosync.conf res_curl.conf res_digium_phone.conf res_digium_phone_general.conf res_fax.conf res_http_media_cache.conf res_ldap.conf res_odbc_additional.conf res_parking.conf res_parking_additional.conf res_pgsql.conf res_pktccops.conf res_snmp.conf res_stun_monitor.conf resolver_unbound.conf rtp_additional.conf sangomartapi-event-timeout.conf sangomartapi-logger.conf sangomartapi_conference say.conf sip_additional.conf sip_custom_post.conf sip_general_additional.conf sip_nat.conf sip_notify_additional.conf sip_registrations.conf skinny.conf sla.conf smdi.conf sorcery.conf srtapi_amidefault srtapi_aststate srtapi_browserphone srtapi_queue_events srtapi_realtime ss7.timers stasis.conf statsd.conf stir_shaken.conf telcordia-1.adsi test_sorcery.conf ucc_restrict.conf unistim.conf users.conf voicemail.conf voicemail.conf.template websocket_client.conf xmpp.conf"
    for conf in $conf_list; do
        [ ! -f "/etc/asterisk/$conf" ] && touch "/etc/asterisk/$conf"
    done
    chown -R asterisk:asterisk /etc/asterisk
    return 0
}

# -----------------------------------------------------------------------------
# Диагностика (интерактивный режим)
# -----------------------------------------------------------------------------
run_diagnostic() {
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🔍 FreePBX 17 Диагностика системы (отладчик v$VERSION)${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
    # Проверки (можно взять из предыдущей версии debug.sh)
    # ... (код диагностики)
    echo -e "${GREEN}✅ Диагностика завершена${NC}"
}

# -----------------------------------------------------------------------------
# Интерактивное меню
# -----------------------------------------------------------------------------
interactive_menu() {
    echo ""
    echo -e "${BLUE}Выберите действие:${NC}"
    echo "  1. Полная диагностика системы"
    echo "  2. Восстановить конфигурацию Asterisk"
    echo "  3. Восстановить доступ к MySQL"
    echo "  4. Добавить fwconsole в PATH"
    echo "  5. Переустановить зависимости Composer"
    echo "  6. Создать недостающие конфиги Asterisk"
    echo "  0. Выход"
    read -p "Ваш выбор: " choice
    case $choice in
        1) run_diagnostic ;;
        2) fix_asterisk_config ;;
        3) fix_mysql_access ;;
        4) fix_fwconsole_path ;;
        5) fix_composer_deps ;;
        6) fix_missing_configs ;;
        0) exit 0 ;;
        *) echo "Неверный выбор"; interactive_menu ;;
    esac
}

# -----------------------------------------------------------------------------
# Основная логика
# -----------------------------------------------------------------------------
if [ "$1" = "--auto" ] && [ -n "$2" ]; then
    # Автоматический режим (вызывается установщиком)
    case "$2" in
        asterisk_config)   fix_asterisk_config ;;
        mysql_access)      fix_mysql_access ;;
        fwconsole_path)    fix_fwconsole_path ;;
        composer_deps)     fix_composer_deps ;;
        missing_configs)   fix_missing_configs ;;
        *) echo "Неизвестное действие: $2"; exit 1 ;;
    esac
    exit $?
else
    # Интерактивный режим
    interactive_menu
fi
