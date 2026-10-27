#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                      # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
# корень репозитория определяется от расположения сценария, а не от текущего каталога
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

err() { echo "deploy: $*" >&2; }

# 1. Разбор аргумента --dry-run
DRY_RUN=0
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN=1 ;;
    *)         err "неизвестный аргумент: $1 (допустимо: --dry-run)"; exit 1 ;;
esac

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    err "файл site/index.html отсутствует, доставка отменена"
    exit 1
fi
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    err "в репозитории есть незафиксированные изменения, доставка отменена:"
    git -C "$REPO_ROOT" status --short >&2
    exit 1
fi
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR}
#    одно SSH-соединение за запуск; BatchMode исключает интерактивный запрос пароля
RSYNC_OPTS=(-avz --delete --chmod=D755,F644
            -e "ssh -o BatchMode=yes -o ConnectTimeout=5")
[[ $DRY_RUN -eq 1 ]] && RSYNC_OPTS+=(--dry-run)
if ! rsync "${RSYNC_OPTS[@]}" "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"; then
    err "ошибка синхронизации (rsync)"
    exit 1
fi

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ $DRY_RUN -eq 1 ]]; then
    echo "deploy: пробный запуск, изменения на сервер не вносились (коммит ${COMMIT})"
    exit 0
fi

# 5. Проверка доступности ${SITE_URL} и завершение с корректным кодом возврата
if ! curl -fsS --max-time 10 --cacert "$CA_CERT" -o /dev/null "$SITE_URL"; then
    err "ресурс ${SITE_URL} недоступен после доставки"
    exit 1
fi
echo "deploy: доставлен коммит ${COMMIT}, ресурс ${SITE_URL} доступен"
