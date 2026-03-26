#!/bin/bash
# Atualização do raspberry-pi-manager: git pull, dependências do sistema (python3-pam),
# pip no venv, reinício do serviço.
#
# Uso:
#   /bin/bash /caminho/do/repo/update_app.sh     (webhook / cópia no diretório da app)
#   sudo /usr/local/bin/update_app.sh             (usa APP_INSTALL_DIR em /etc/default/...)

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-raspberry-pi-manager}"

# Descobre o diretório da aplicação (app.py / requirements.txt)
resolve_app_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

    if [ -f "$script_dir/app.py" ] || [ -f "$script_dir/requirements.txt" ]; then
        echo "$script_dir"
        return
    fi

    if [ -n "${APP_INSTALL_DIR:-}" ] && [ -d "$APP_INSTALL_DIR" ]; then
        echo "$APP_INSTALL_DIR"
        return
    fi

    local def="/etc/default/${SERVICE_NAME}"
    if [ -f "$def" ]; then
        local line val
        line="$(grep -E '^[[:space:]]*APP_INSTALL_DIR=' "$def" 2>/dev/null | tail -n1 || true)"
        if [ -n "$line" ]; then
            val="${line#*=}"
            val="${val%\"}"
            val="${val#\"}"
            val="${val%\'}"
            val="${val#\'}"
            if [ -n "$val" ] && [ -d "$val" ]; then
                echo "$val"
                return
            fi
        fi
    fi

    for cand in /home/administrador/raspberry-pi-manager /opt/raspberry-pi-manager; do
        if [ -f "$cand/app.py" ]; then
            echo "$cand"
            return
        fi
    done

    echo "$script_dir"
}

APP_ROOT="$(resolve_app_root)"
LOGFILE="${APP_ROOT}/update_app.log"
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

echo "[$(date -Iseconds)] Starting update (APP_ROOT=$APP_ROOT)" >>"$LOGFILE"
cd "$APP_ROOT"

# --- Rede temporária (opcional): guardar IPv4, usar PI_MANAGER_UPDATE_*, restaurar ao sair ---
_PI_SWAP_LIB="${APP_ROOT}/scripts/lib-network-swap-for-update.sh"
if [ -f "$_PI_SWAP_LIB" ]; then
    # shellcheck source=scripts/lib-network-swap-for-update.sh
    source "$_PI_SWAP_LIB"
    pi_manager_network_swap_begin || true
fi

# --- Dependências do sistema: PAM (login web = senha Linux) ---
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update -qq >>"$LOGFILE" 2>&1 || true
        apt-get install -y -qq python3-pam >>"$LOGFILE" 2>&1 || true
    elif [ -x /usr/local/bin/pi-manager-ensure-deps ]; then
        sudo /usr/local/bin/pi-manager-ensure-deps >>"$LOGFILE" 2>&1 || true
    else
        sudo apt-get update -qq >>"$LOGFILE" 2>&1 || true
        sudo apt-get install -y -qq python3-pam >>"$LOGFILE" 2>&1 || true
    fi
    echo "[$(date -Iseconds)] apt: python3-pam garantido" >>"$LOGFILE"
fi

# --- Git (repo vazio pós install: sem HEAD até primeiro commit / pull) ---
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git fetch --all --prune || true
    if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
        head_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
        if git show-ref --verify --quiet "refs/remotes/origin/${head_branch}"; then
            git reset --hard "origin/${head_branch}" || true
        elif git show-ref --verify --quiet refs/remotes/origin/main; then
            git checkout -B main origin/main || true
        else
            echo "[$(date -Iseconds)] WARN: sem origin/${head_branch} nem origin/main" >>"$LOGFILE"
        fi
    else
        echo "[$(date -Iseconds)] Git: sem commits locais; alinhando a origin/main se existir" >>"$LOGFILE"
        if git show-ref --verify --quiet refs/remotes/origin/main; then
            git checkout -B main origin/main || true
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
            git checkout -B master origin/master || true
        fi
    fi
    echo "[$(date -Iseconds)] Git updated" >>"$LOGFILE"
else
    echo "[$(date -Iseconds)] Not a git repo, skipping git pull" >>"$LOGFILE"
fi

# --- pip no venv (como root usa sudo -u administrador para não mudar dono do venv) ---
VENV_PIP="${APP_ROOT}/venv/bin/pip"
if [ -x "$VENV_PIP" ] && [ -f "${APP_ROOT}/requirements.txt" ]; then
    if [ "$(id -u)" -eq 0 ] && id administrador >/dev/null 2>&1; then
        sudo -u administrador "$VENV_PIP" install --upgrade pip >>"$LOGFILE" 2>&1 || true
        sudo -u administrador "$VENV_PIP" install -r "${APP_ROOT}/requirements.txt" >>"$LOGFILE" 2>&1 || true
        VENV_PY="${APP_ROOT}/venv/bin/python"
        if [ -x "$VENV_PY" ]; then
            _PAML="${APP_ROOT}/scripts/lib-pam-venv.sh"
            if [ -f "$_PAML" ]; then
                # shellcheck source=scripts/lib-pam-venv.sh
                source "$_PAML"
                ensure_pam_in_venv_for_path "${APP_ROOT}/venv" administrador >>"$LOGFILE" 2>&1 || true
            else
                if sudo -u administrador "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None))" >>"$LOGFILE" 2>&1; then
                    sudo -u administrador "$VENV_PIP" uninstall -y python-pam >>"$LOGFILE" 2>&1 || true
                    if ! sudo -u administrador "$VENV_PY" -c "import pam" >>"$LOGFILE" 2>&1; then
                        sudo -u administrador "$VENV_PIP" install --no-cache-dir 'python-pam>=2.0.2' 'six>=1.16.0' >>"$LOGFILE" 2>&1 || true
                    fi
                else
                    sudo -u administrador "$VENV_PIP" install --no-cache-dir 'python-pam>=2.0.2' 'six>=1.16.0' >>"$LOGFILE" 2>&1 || true
                fi
            fi
        fi
    else
        "$VENV_PIP" install --upgrade pip >>"$LOGFILE" 2>&1 || true
        "$VENV_PIP" install -r "${APP_ROOT}/requirements.txt" >>"$LOGFILE" 2>&1 || true
        VENV_PY="${APP_ROOT}/venv/bin/python"
        if [ -x "$VENV_PY" ]; then
            _PAML="${APP_ROOT}/scripts/lib-pam-venv.sh"
            if [ -f "$_PAML" ]; then
                # shellcheck source=scripts/lib-pam-venv.sh
                source "$_PAML"
                ensure_pam_in_venv_for_path "${APP_ROOT}/venv" "" >>"$LOGFILE" 2>&1 || true
            else
                if "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None))" >>"$LOGFILE" 2>&1; then
                    "$VENV_PIP" uninstall -y python-pam >>"$LOGFILE" 2>&1 || true
                    if ! "$VENV_PY" -c "import pam" >>"$LOGFILE" 2>&1; then
                        "$VENV_PIP" install --no-cache-dir 'python-pam>=2.0.2' 'six>=1.16.0' >>"$LOGFILE" 2>&1 || true
                    fi
                else
                    "$VENV_PIP" install --no-cache-dir 'python-pam>=2.0.2' 'six>=1.16.0' >>"$LOGFILE" 2>&1 || true
                fi
            fi
        fi
    fi
    echo "[$(date -Iseconds)] venv pip install done" >>"$LOGFILE"
elif [ -f "${APP_ROOT}/requirements.txt" ]; then
    echo "[$(date -Iseconds)] WARN: venv pip not found at $VENV_PIP" >>"$LOGFILE"
fi

# --- Reinício do serviço (sudoers: NOPASSWD systemctl restart <SERVICE_NAME>) ---
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --full -all 2>/dev/null | grep -q "${SERVICE_NAME}"; then
        if [ "$(id -u)" -eq 0 ]; then
            systemctl restart "${SERVICE_NAME}" >>"$LOGFILE" 2>&1 || true
        else
            sudo /usr/bin/systemctl restart "${SERVICE_NAME}" >>"$LOGFILE" 2>&1 || true
        fi
        echo "[$(date -Iseconds)] Restarted service ${SERVICE_NAME}" >>"$LOGFILE"
    else
        echo "[$(date -Iseconds)] Service ${SERVICE_NAME} not found; skipping restart" >>"$LOGFILE"
    fi
fi

echo "[$(date -Iseconds)] Update finished" >>"$LOGFILE"

# --- Verificação explícita PAM (login web) ---
PAM_FINAL_OK=1
VENV_PY="${APP_ROOT}/venv/bin/python"
if [ -x "$VENV_PY" ]; then
    if [ "$(id -u)" -eq 0 ] && id administrador >/dev/null 2>&1; then
        if sudo -u administrador "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None))" >>"$LOGFILE" 2>&1; then
            echo "[$(date -Iseconds)] PAM final check: OK" >>"$LOGFILE"
        else
            echo "[$(date -Iseconds)] ERROR PAM final check: FAILED (login web pode falhar)" >>"$LOGFILE"
            PAM_FINAL_OK=0
        fi
    else
        if "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None))" >>"$LOGFILE" 2>&1; then
            echo "[$(date -Iseconds)] PAM final check: OK" >>"$LOGFILE"
        else
            echo "[$(date -Iseconds)] ERROR PAM final check: FAILED (login web pode falhar)" >>"$LOGFILE"
            PAM_FINAL_OK=0
        fi
    fi
else
    echo "[$(date -Iseconds)] WARN PAM final check: venv python missing at $VENV_PY" >>"$LOGFILE"
fi

if [ "${UPDATE_APP_STRICT_PAM:-0}" = "1" ] && [ "$PAM_FINAL_OK" != "1" ]; then
    echo "[$(date -Iseconds)] EXIT 1 (UPDATE_APP_STRICT_PAM=1 e PAM inválido)" >>"$LOGFILE"
    if type pi_manager_network_swap_end >/dev/null 2>&1; then
        pi_manager_network_swap_end || true
    fi
    exit 1
fi

if type pi_manager_network_swap_end >/dev/null 2>&1; then
    pi_manager_network_swap_end || true
fi

exit 0
