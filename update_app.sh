#!/bin/bash
# =============================================================================
# Atualizador do raspberry-pi-manager.
#
# Funciona nos DOIS modos:
#   - PULL (principal): chamado como root pelo timer semanal
#     (raspberry-pi-manager-update.timer).
#   - PUSH (opcional): chamado como 'administrador' pelo webhook (Flask).
#
# Só atualiza quando o checkout local está ATRÁS do remoto — caso contrário,
# apenas registra "já atualizado" e sai. Reinicia o serviço ao final.
# =============================================================================
set -uo pipefail

SERVICE_NAME="${SERVICE_NAME:-raspberry-pi-manager}"
RUN_USER="${RUN_USER:-administrador}"

# Diretório do repositório: env > diretório de instalação padrão > diretório do script
REPO_DIR="${INSTALL_DIR:-/home/${RUN_USER}/raspberry-pi-manager}"
[ -d "$REPO_DIR/.git" ] || REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PIP="$REPO_DIR/venv/bin/pip"
LOGFILE="${REPO_DIR}/update_app.log"

# Garante um log gravável e de posse do usuário (para webhook E timer poderem escrever)
touch "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/update_app.log"
if [ "$(id -u)" -eq 0 ]; then
    chown "$RUN_USER":"$RUN_USER" "$LOGFILE" 2>/dev/null || true
fi

log() { echo "[$(date -Iseconds)] $*" >> "$LOGFILE"; }

# Executa um comando COMO o dono do repositório, independente de quem somos agora.
# (root pode virar administrador sem senha; administrador roda direto.)
as_owner() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$RUN_USER" "$@"
    else
        "$@"
    fi
}

# Reinicia o serviço: como root, direto; como usuário, via sudo (regra no sudoers).
restart_service() {
    if [ "$(id -u)" -eq 0 ]; then
        systemctl restart "$SERVICE_NAME"
    else
        sudo systemctl restart "$SERVICE_NAME"
    fi
}

log "=== Verificando atualizações em $REPO_DIR (executado por: $(whoami)) ==="
cd "$REPO_DIR" || { log "ERRO: repositório não encontrado em $REPO_DIR"; exit 1; }

if ! as_owner git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Não é um repositório git; nada a fazer."
    exit 0
fi

BRANCH="$(as_owner git rev-parse --abbrev-ref HEAD)"

# 1. Busca o estado remoto (sem alterar nada ainda)
if ! as_owner git fetch --quiet origin "$BRANCH"; then
    log "ERRO: 'git fetch' falhou (sem internet?). Tentaremos na próxima semana."
    exit 1
fi

LOCAL="$(as_owner git rev-parse HEAD)"
REMOTE="$(as_owner git rev-parse "origin/$BRANCH" 2>/dev/null || echo '')"

# 2. Decide se há atualização
if [ -z "$REMOTE" ]; then
    log "Não foi possível ler origin/$BRANCH; abortando sem alterar nada."
    exit 1
fi
if [ "$LOCAL" = "$REMOTE" ]; then
    log "Já está na versão mais recente ($LOCAL). Nenhuma atualização necessária."
    exit 0
fi

# 3. Aplica a atualização
log "Atualização encontrada: ${LOCAL:0:8} -> ${REMOTE:0:8}. Aplicando..."
if ! as_owner git reset --hard "origin/$BRANCH" >>"$LOGFILE" 2>&1; then
    log "ERRO: 'git reset --hard' falhou."
    exit 1
fi

# 4. Dependências NO VENV (não no Python do sistema)
if [ -f requirements.txt ] && [ -x "$VENV_PIP" ]; then
    as_owner "$VENV_PIP" install -r requirements.txt >>"$LOGFILE" 2>&1 \
        && log "Dependências do venv verificadas." \
        || log "Aviso: pip install retornou erro (seguindo mesmo assim)."
fi

# 5. Reinicia o serviço para rodar o código novo
if restart_service >>"$LOGFILE" 2>&1; then
    log "Serviço '$SERVICE_NAME' reiniciado com a nova versão ($REMOTE)."
else
    log "ERRO ao reiniciar '$SERVICE_NAME'."
    exit 1
fi

log "=== Atualização concluída com sucesso ==="
