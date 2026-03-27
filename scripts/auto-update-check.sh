#!/bin/bash
# Verificação periódica de atualizações no GitHub (pull-based).
# Fluxo: fetch -> compara HEAD local com origin/<branch> -> se diferente, roda update_app.sh.

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-raspberry-pi-manager}"
ENV_FILE="/etc/default/${SERVICE_NAME}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
fi

if [ "${PI_MANAGER_AUTO_UPDATE_ENABLED:-1}" != "1" ]; then
    exit 0
fi

APP_ROOT="${APP_INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
BRANCH="${PI_MANAGER_AUTO_UPDATE_BRANCH:-main}"
REMOTE="${PI_MANAGER_AUTO_UPDATE_REMOTE:-origin}"
LOCK_FILE="${PI_MANAGER_AUTO_UPDATE_LOCK_FILE:-/run/pi-manager-auto-update.lock}"
LOGFILE="${APP_ROOT}/update_auto.log"

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true

{
    echo "[$(date -Iseconds)] auto-update: start (root=$APP_ROOT remote=$REMOTE branch=$BRANCH)"

    if [ ! -d "$APP_ROOT/.git" ]; then
        echo "[$(date -Iseconds)] auto-update: skip (sem .git em $APP_ROOT)"
        exit 0
    fi

    cd "$APP_ROOT"

    if ! command -v flock >/dev/null 2>&1; then
        echo "[$(date -Iseconds)] auto-update: flock indisponível; sem lock de concorrência."
    fi
} >>"$LOGFILE"

exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
        echo "[$(date -Iseconds)] auto-update: outro update em execução; saindo." >>"$LOGFILE"
        exit 0
    fi
fi

cd "$APP_ROOT"
if ! git fetch --prune "$REMOTE" "$BRANCH" >>"$LOGFILE" 2>&1; then
    echo "[$(date -Iseconds)] auto-update: fetch falhou ($REMOTE/$BRANCH)." >>"$LOGFILE"
    exit 0
fi

LOCAL_REV="$(git rev-parse HEAD 2>/dev/null || true)"
REMOTE_REV="$(git rev-parse "${REMOTE}/${BRANCH}" 2>/dev/null || true)"

if [ -z "$REMOTE_REV" ]; then
    echo "[$(date -Iseconds)] auto-update: remote rev vazio para ${REMOTE}/${BRANCH}." >>"$LOGFILE"
    exit 0
fi

if [ "$LOCAL_REV" = "$REMOTE_REV" ]; then
    echo "[$(date -Iseconds)] auto-update: sem mudanças (${LOCAL_REV:-sem-head})." >>"$LOGFILE"
    exit 0
fi

echo "[$(date -Iseconds)] auto-update: nova revisão ($LOCAL_REV -> $REMOTE_REV), executando update_app.sh..." >>"$LOGFILE"
if [ -x /usr/local/bin/update_app.sh ]; then
    /usr/local/bin/update_app.sh >>"$LOGFILE" 2>&1
else
    /bin/bash "$APP_ROOT/update_app.sh" >>"$LOGFILE" 2>&1
fi
echo "[$(date -Iseconds)] auto-update: concluído." >>"$LOGFILE"
exit 0
