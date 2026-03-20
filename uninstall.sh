#!/bin/bash
# =============================================
# DESINSTALADOR — Raspberry Pi Manager
# Remove serviço systemd, wrappers em /usr/local/bin, sudoers e (opcional) arquivos da aplicação.
# Uso: sudo ./uninstall.sh
#      sudo ./uninstall.sh -y
#      sudo ./uninstall.sh -y --purge
# =============================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SERVICE_NAME="${SERVICE_NAME:-raspberry-pi-manager}"
DEFAULT_INSTALL="/home/administrador/raspberry-pi-manager"
ENV_FILE="/etc/default/${SERVICE_NAME}"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

YES=0
PURGE_ENV=0
KEEP_APP_DIR=0
KEEP_DESKTOP=0
INSTALL_DIR_CLI=""

usage() {
    echo "Uso: sudo $0 [opções]"
    echo ""
    echo "Opções:"
    echo "  -y, --yes              Não pergunta; remove diretório da app (exceto --keep-app-dir)."
    echo "  --purge                Remove também /etc/default/${SERVICE_NAME} (WEBHOOK_SECRET etc.)."
    echo "  --keep-app-dir         Mantém a pasta da instalação (só remove integração systemd/sudo)."
    echo "  --keep-desktop         Não remove o atalho Chromium-Raspberry.desktop da área de trabalho."
    echo "  --install-dir CAMINHO  Força o diretório a apagar (sobrescreve detecção automática)."
    echo "  -h, --help             Esta ajuda."
    echo ""
    echo "Não remove: pacotes apt (nginx, chromium…), auto-login lightdm nem perfil Chromium em ~/chromium-profile."
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) YES=1; shift ;;
        --purge) PURGE_ENV=1; shift ;;
        --keep-app-dir) KEEP_APP_DIR=1; shift ;;
        --keep-desktop) KEEP_DESKTOP=1; shift ;;
        --install-dir)
            if [ -z "${2:-}" ]; then echo "Falta caminho após --install-dir"; exit 1; fi
            INSTALL_DIR_CLI="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Opção desconhecida: $1${NC}"; usage; exit 1 ;;
    esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}Execute como root: sudo $0${NC}"
    exit 1
fi

resolve_install_dir() {
    if [ -n "$INSTALL_DIR_CLI" ]; then
        echo "$INSTALL_DIR_CLI"
        return
    fi
    if [ -n "${INSTALL_DIR:-}" ]; then
        echo "$INSTALL_DIR"
        return
    fi
    if [ -f "$ENV_FILE" ]; then
        local line val
        line="$(grep -E '^[[:space:]]*APP_INSTALL_DIR=' "$ENV_FILE" 2>/dev/null | tail -n1 || true)"
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
    if [ -d "$DEFAULT_INSTALL" ]; then
        echo "$DEFAULT_INSTALL"
        return
    fi
    echo ""
}

INSTALL_DIR="$(resolve_install_dir)"

confirm() {
    local msg="$1"
    if [ "$YES" -eq 1 ]; then
        return 0
    fi
    read -r -p "$msg [s/N] " ans
    case "$ans" in
        s|S|sim|SIM) return 0 ;;
        *) return 1 ;;
    esac
}

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     DESINSTALADOR — Gerenciador Raspberry Pi          ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BLUE}Serviço:${NC} $SERVICE_NAME"
echo -e "${BLUE}Unit:${NC} $UNIT_FILE"
echo -e "${BLUE}Diretório da app detectado:${NC} ${INSTALL_DIR:-"(não encontrado)"}"
echo ""

# --- systemd ---
if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    echo -e "${YELLOW}Parando e desabilitando o serviço...${NC}"
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
fi
# Remove máscara para uma futura reinstalação não falhar em systemctl start
systemctl unmask "${SERVICE_NAME}.service" 2>/dev/null || true

if [ -f "$UNIT_FILE" ]; then
    rm -f "$UNIT_FILE"
    echo -e "${GREEN}✅ Removido $UNIT_FILE${NC}"
fi

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

# --- /usr/local/bin ---
WRAPPERS=(
    /usr/local/bin/update_app.sh
    /usr/local/bin/pi-manager-nmcli
    /usr/local/bin/pi-manager-chpasswd
    /usr/local/bin/pi-manager-hostname
    /usr/local/bin/pi-manager-ensure-deps
)
for f in "${WRAPPERS[@]}"; do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo -e "${GREEN}✅ Removido $f${NC}"
    fi
done

# --- sudoers ---
if [ -f /etc/sudoers.d/pi-manager ]; then
    rm -f /etc/sudoers.d/pi-manager
    echo -e "${GREEN}✅ Removido /etc/sudoers.d/pi-manager${NC}"
fi

# --- logs do instalador ---
for logf in /var/log/pi-manager-nmcli.log /var/log/pi-manager-chpasswd.log /var/log/pi-manager-hostname.log; do
    if [ -f "$logf" ]; then
        rm -f "$logf"
        echo -e "${GREEN}✅ Removido $logf${NC}"
    fi
done

# --- /etc/default ---
if [ "$PURGE_ENV" -eq 1 ]; then
    if [ -f "$ENV_FILE" ]; then
        rm -f "$ENV_FILE"
        echo -e "${GREEN}✅ Removido $ENV_FILE${NC}"
    fi
elif [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}ℹ️  Mantido $ENV_FILE (secrets/webhook). Use --purge para apagar.${NC}"
fi

# --- diretório da aplicação ---
if [ "$KEEP_APP_DIR" -eq 1 ]; then
    echo -e "${YELLOW}ℹ️  Pasta da instalação mantida (--keep-app-dir).${NC}"
elif [ -n "$INSTALL_DIR" ] && [ -d "$INSTALL_DIR" ]; then
    if confirm "Remover TUDO em ${INSTALL_DIR} (código, venv, config)?"; then
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}✅ Removido diretório $INSTALL_DIR${NC}"
    else
        echo -e "${YELLOW}ℹ️  Diretório da app não foi removido.${NC}"
    fi
else
    echo -e "${YELLOW}ℹ️  Diretório da instalação não encontrado; nada a apagar.${NC}"
fi

# --- atalho na área de trabalho ---
if [ "$KEEP_DESKTOP" -eq 0 ] && id administrador >/dev/null 2>&1; then
    DESK=""
    if command -v runuser >/dev/null 2>&1; then
        DESK="$(runuser -u administrador -- xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    if [ -z "$DESK" ]; then
        DESK="$(sudo -u administrador env HOME=/home/administrador xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    if [ -z "$DESK" ]; then
        DESK="/home/administrador/Desktop"
    fi
    SHORTCUT="${DESK}/Chromium-Raspberry.desktop"
    if [ -f "$SHORTCUT" ]; then
        if [ "$YES" -eq 1 ] || confirm "Remover atalho ${SHORTCUT}?"; then
            rm -f "$SHORTCUT"
            echo -e "${GREEN}✅ Removido atalho da área de trabalho${NC}"
        fi
    fi
fi

# --- logs em ~/pi-manager (fora do diretório da app) ---
if id administrador >/dev/null 2>&1; then
    PI_MGR_LOG="/home/administrador/pi-manager"
    if [ -d "$PI_MGR_LOG" ]; then
        echo -e "${YELLOW}ℹ️  Pasta extra (logs do browser etc.): $PI_MGR_LOG — apague manualmente: sudo rm -rf $PI_MGR_LOG${NC}"
    fi
fi

echo ""
echo -e "${GREEN}Desinstalação do serviço e integração concluída.${NC}"
echo -e "${YELLOW}Não removido automaticamente:${NC}"
echo "  • Pacotes apt (chromium, nginx, python3-pam, …)"
echo "  • Auto-login / lightdm (raspi-config / lightdm.conf)"
echo "  • Perfil Chromium: /home/administrador/chromium-profile"
echo ""
echo -e "${BLUE}Para remover só o pacote opcional do sistema (se não for mais usado):${NC}"
echo "  sudo apt remove --purge nginx   # apenas se não precisar de nginx"
echo ""
