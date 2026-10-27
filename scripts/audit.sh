#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no"  "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no"  "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
# Проверка 1 (TODO 1): значение параметра port отлично от 22
SSH_PORT="$(sudo sshd -T | awk '/^port /{print $2}' | head -n 1)"
check "Порт SSH отличен от 22 (port $SSH_PORT)" "yes" \
    "$([[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]] && echo yes || echo no)"
# Проверка 2 (TODO 2): значение параметра maxauthtries равно 3
check "Число попыток аутентификации MaxAuthTries равно 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# Проверка 3 (TODO 3): политика по умолчанию для входящего трафика равна deny
#   источник данных: sudo ufw status verbose | grep Default
check "Политика по умолчанию для входящего трафика deny" "deny" \
    "$(sudo ufw status verbose | grep '^Default:' | sed -E 's/^Default: ([a-z]+) \(incoming\).*/\1/')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
SITE_DIR="/var/www/devops-site"
CERT="/etc/ssl/certs/devops.crt"
KEY="/etc/ssl/private/devops.key"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"      # порог можно задать извне: CERT_MIN_DAYS=400 ./audit.sh
# а) служба nginx активна
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
# б) конфигурация nginx синтаксически корректна (код возврата nginx -t)
check "Конфигурация nginx корректна (nginx -t)" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
# в) сертификат истекает не ранее чем через CERT_MIN_DAYS дней (код возврата openssl x509 -checkend)
check "Сертификат действителен ещё не менее ${CERT_MIN_DAYS} дн." "0" \
    "$(openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout -in "$CERT" >/dev/null 2>&1; echo $?)"
# г) в каталоге ресурса нет файлов, доступных для записи всем, права ключа равны 600
WW_FILES="$(find "$SITE_DIR" -perm -o+w | wc -l | tr -d ' ')"
KEY_MODE="$(sudo stat -c '%a' "$KEY")"
check "Нет файлов с записью для всех, права ключа 600 (файлов: $WW_FILES, ключ: $KEY_MODE)" \
    "0 600" "$WW_FILES $KEY_MODE"

echo "[5] Контейнеризация"
APP_DIR="${HOME}/app"
# а) служба docker активна
check "Служба docker активна" "active" "$(systemctl is-active docker)"
# б) контейнер СУБД находится в состоянии healthy
check "Контейнер СУБД app-db-1 в состоянии healthy" "healthy" \
    "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
# в) порты 5000 и 5432 не прослушиваются ни на одном адресе, кроме 127.0.0.1
EXPOSED="$(ss -tlnH | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:' | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "Порты 5000 и 5432 прослушиваются только на 127.0.0.1 (лишние сокеты: ${EXPOSED:-нет})" \
    "" "$EXPOSED"
# г) права файла ~/app/.env равны 600
check "Права файла ${APP_DIR}/.env равны 600" "600" "$(stat -c '%a' "${APP_DIR}/.env" 2>/dev/null)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
