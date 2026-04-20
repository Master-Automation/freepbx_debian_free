# =============================================================================
# Предустановочная проверка системы (pre-flight check)
# =============================================================================
pre_install_check() {
    message "🔍 Выполняется предустановочная проверка системы..."
    local error_count=0
    local warn_count=0

    # 1. Проверка архитектуры
    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" != "amd64" ]; then
        message "   ❌ Архитектура $ARCH не поддерживается. Требуется amd64."
        error_count=$((error_count + 1))
    else
        message "   ✅ Архитектура: amd64"
    fi

    # 2. Проверка прав на запись в /usr/src (нужно для сборки Asterisk)
    if [ ! -w /usr/src ]; then
        message "   ❌ Нет прав на запись в /usr/src"
        error_count=$((error_count + 1))
    else
        message "   ✅ Права на запись в /usr/src"
    fi

    # 3. Свободное место в /usr/src (минимум 5 ГБ)
    FREE_SPACE=$(df /usr/src | awk 'NR==2 {print $4}')
    if [ $FREE_SPACE -lt 5242880 ]; then
        message "   ❌ Недостаточно места на диске в /usr/src: $((FREE_SPACE / 1024)) МБ (нужно минимум 5 ГБ)"
        error_count=$((error_count + 1))
    else
        message "   ✅ Свободное место в /usr/src: $((FREE_SPACE / 1024)) МБ"
    fi

    # 4. Проверка интернета (доступ к deb.debian.org)
    if curl -s --connect-timeout 5 https://deb.debian.org > /dev/null 2>&1; then
        message "   ✅ Интернет доступен (deb.debian.org)"
    else
        message "   ❌ Нет доступа к deb.debian.org (проверьте сеть)"
        error_count=$((error_count + 1))
    fi

    # 5. Проверка DNS (разрешение github.com)
    if ping -c 1 github.com > /dev/null 2>&1; then
        message "   ✅ DNS работает (github.com разрешается)"
    else
        message "   ⚠️ GitHub может быть недоступен (проверьте DNS)"
        warn_count=$((warn_count + 1))
    fi

    # 6. Проверка, что система не в chroot/контейнере (не критично, но предупредим)
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
        message "   ⚠️ Обнаружен контейнер (Docker/LXC). Некоторые функции могут не работать."
        warn_count=$((warn_count + 1))
    fi

    # 7. Проверка доступности порта 80 (Apache) – если уже занят, предупредим
    if ss -tlnp | grep -q ':80 '; then
        message "   ⚠️ Порт 80 уже занят. Возможен конфликт с существующим веб-сервером."
        warn_count=$((warn_count + 1))
    else
        message "   ✅ Порт 80 свободен"
    fi

    # 8. Проверка доступности порта 3306 (MySQL) – если занят, предупредим
    if ss -tlnp | grep -q ':3306 '; then
        message "   ⚠️ Порт 3306 уже занят. Возможен конфликт с существующим MySQL."
        warn_count=$((warn_count + 1))
    else
        message "   ✅ Порт 3306 свободен"
    fi

    # 9. Проверка, что система не заблокирована на уровне пакетов (наличие apt)
    if command -v apt-get > /dev/null 2>&1; then
        message "   ✅ apt-get доступен"
    else
        message "   ❌ apt-get не найден. Это не Debian/Ubuntu?"
        error_count=$((error_count + 1))
    fi

    # 10. Проверка переменной PATH (наличие стандартных директорий)
    REQUIRED_PATH_DIRS="/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin"
    for dir in $REQUIRED_PATH_DIRS; do
        if [[ ":$PATH:" != *":$dir:"* ]]; then
            message "   ⚠️ Директория $dir отсутствует в PATH"
            warn_count=$((warn_count + 1))
        fi
    done

    # Итог
    if [ $error_count -gt 0 ]; then
        message ""
        message "❌ Предустановочная проверка выявила $error_count критических ошибок."
        message "   Установка невозможна. Устраните проблемы и запустите скрипт снова."
        exit 1
    elif [ $warn_count -gt 0 ]; then
        message ""
        message "⚠️ Предустановочная проверка выявила $warn_count предупреждений."
        message "   Установка может продолжиться, но некоторые функции могут работать нестабильно."
        read -p "   Продолжить? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            message "Установка отменена пользователем."
            exit 1
        fi
    else
        message "   ✅ Все проверки пройдены успешно."
    fi
    message ""
}

# Вызов функции после проверки ОС и прав
pre_install_check
