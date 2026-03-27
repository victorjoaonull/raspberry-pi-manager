#!/bin/bash

# =============================================
# INSTALADOR AUTOMÁTICO - Gerenciador Raspberry PI
# =============================================

set -e  # Para em caso de erro

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║      INSTALADOR DO GERENCIADOR RASPBERRY PI          ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Dica: na configuração rápida, prima ENTER; depois pode ativar troca de IP só para o apt se vir 403."
echo "  Variáveis PI_* antes do sudo: use  sudo -E ./install.sh  (senão o sudo remove o ambiente)."
echo ""

# ========== VERIFICAÇÕES INICIAIS ==========
echo -e "${BLUE}[1/12]${NC} Verificando requisitos..."

# Verificar se é Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    echo -e "${RED}❌ Este script deve ser executado em um Raspberry Pi${NC}"
    exit 1
fi

# Verificar se é root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Execute este script como root ou com sudo${NC}"
    echo -e "${YELLOW}💡 Comando: sudo ./install.sh${NC}"
    exit 1
fi

# Verificar se usuário administrador existe
if ! id "administrador" &>/dev/null; then
    echo -e "${YELLOW}⚠️  Criando usuário 'administrador'...${NC}"
    useradd -m -G sudo,adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,netdev,spi,i2c,gpio administrador
    echo "administrador:raspberry" | chpasswd
    echo -e "${GREEN}✅ Usuário 'administrador' criado com senha 'raspberry'${NC}"
    echo -e "${YELLOW}⚠️  ALTERE A SENHA APÓS A INSTALAÇÃO!${NC}"
fi

# ========== CAPTURAR DIRETÓRIO DO REPOSITÓRIO ==========
# Deve ser feito ANTES de mudar de diretório durante a limpeza
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ========== ASSISTENTE (opcional, leigos: ENTER = recomendado) ==========
_INSTALL_WIZARD="${REPO_DIR}/scripts/install-wizard.sh"
if [ -f "$_INSTALL_WIZARD" ]; then
    # shellcheck source=scripts/install-wizard.sh
    source "$_INSTALL_WIZARD"
    pi_manager_install_run_wizard || true
fi

# Troca IPv4 imediata após "sim" no assistente (ou PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1 no ambiente)
_SWAP_LIB="${REPO_DIR}/scripts/lib-network-swap-for-update.sh"
if [ "${PI_MANAGER_NETWORK_SWAP_FOR_UPDATE:-0}" = "1" ] && [ -f "$_SWAP_LIB" ]; then
    if ! command -v nmcli >/dev/null 2>&1; then
        echo -e "${YELLOW}[--] PI_MANAGER_NETWORK_SWAP: a instalar network-manager…${NC}"
        apt-get update -qq || true
        apt-get install -y -qq network-manager || true
        systemctl enable NetworkManager 2>/dev/null || true
        systemctl start NetworkManager 2>/dev/null || true
        sleep 2
    fi
    # shellcheck source=scripts/lib-network-swap-for-update.sh
    source "$_SWAP_LIB"
    echo -e "${BLUE}[swap]${NC} A aplicar IPv4 temporário (${PI_MANAGER_UPDATE_IPV4:-10.0.8.94}, gw ${PI_MANAGER_UPDATE_GW:-10.0.0.1}) agora…"
    pi_manager_network_swap_begin || true
fi

# ========== LIMPAR INSTALAÇÕES ANTIGAS ==========
# Por omissão só remove pastas com nomes EXATOS raspberry-pi-manager / raspberry_pi_manager
# (evita apagar diretórios tipo "meu-pi-manager-backup"). Para o comportamento antigo
# (find *pi-manager*), defina: PI_MANAGER_LEGACY_WIDE_CLEANUP=1
echo -e "${BLUE}[--]${NC} Removendo instalações antigas conhecidas (modo seguro)..."
REPO_DIR_REAL="$(realpath "$REPO_DIR" 2>/dev/null || echo "$REPO_DIR")"
DIRS_TO_REMOVE=()
FOUND=()

_add_if_legacy_dir() {
    local d="$1"
    # Com set -e, "|| return" sem código devolve 1 de [ e aborta o script inteiro.
    [ -d "$d" ] || return 0
    local D_REAL
    D_REAL="$(realpath "$d" 2>/dev/null || echo "$d")"
    if [ "$D_REAL" = "$REPO_DIR_REAL" ]; then
        echo "  ⊘ $d (pulado - é origem do installer)"
        return
    fi
    FOUND+=("$D_REAL")
}

if [ "${PI_MANAGER_LEGACY_WIDE_CLEANUP:-0}" = "1" ]; then
    echo -e "${YELLOW}⚠️  PI_MANAGER_LEGACY_WIDE_CLEANUP=1: varredura larga *pi-manager* (arriscado).${NC}"
    SEARCH_PATHS=("/home" "/opt" "/usr/local" "/srv" "/var/www" "/root" "/tmp")
    for p in "${SEARCH_PATHS[@]}"; do
        if [ -d "$p" ]; then
            while IFS= read -r -d $'\0' d; do
                [ -n "$d" ] || continue
                _add_if_legacy_dir "$d"
            done < <(find "$p" -maxdepth 3 -type d -iname "*pi-manager*" -print0 2>/dev/null || true)
        fi
    done
else
    STRICT_NAMES=( "raspberry-pi-manager" "raspberry_pi_manager" )
    for name in "${STRICT_NAMES[@]}"; do
        for base in /opt /srv /var/www /usr/local /root /tmp; do
            _add_if_legacy_dir "$base/$name"
        done
    done
    if [ -d /home ]; then
        for udir in /home/*; do
            [ -d "$udir" ] || continue
            for name in "${STRICT_NAMES[@]}"; do
                _add_if_legacy_dir "$udir/$name"
            done
        done
    fi
fi

# Deduplicar sem readarray/sort (evita exit por set -e em alguns Bash/Pi OS)
_dedupe_legacy_found() {
    local -a out=()
    local x y dup
    for x in "${FOUND[@]}"; do
        [ -z "$x" ] && continue
        dup=0
        for y in "${out[@]}"; do
            if [ "$x" = "$y" ]; then
                dup=1
                break
            fi
        done
        if [ "$dup" -eq 0 ]; then
            out+=("$x")
        fi
    done
    FOUND=("${out[@]}")
}
if [ ${#FOUND[@]} -gt 0 ]; then
    _dedupe_legacy_found
fi

if [ ${#FOUND[@]} -gt 0 ]; then
    echo "Encontrado diretórios para remoção:"
    for d in "${FOUND[@]}"; do
        echo "  - $d (será removido)"
        DIRS_TO_REMOVE+=("$d")
    done
    echo "Removendo diretórios antigos..."
    cd /tmp || cd / || true
    for d in "${DIRS_TO_REMOVE[@]}"; do
        echo "  Removendo: $d"
        rm -rf "$d" || echo -e "${YELLOW}⚠️  Aviso: não foi possível remover $d${NC}"
    done
else
    echo "Nenhuma instalação antiga encontrada."
fi

# ========== VARIÁVEIS DE CONFIGURAÇÃO ==========
# Permite sobrescrever o diretório de instalação via variável de ambiente
INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
# Perfil Chromium (alinhado com PI_MANAGER_CHROMIUM_USER_DATA_DIR no serviço / app.py)
PI_MANAGER_CHROMIUM_USER_DATA_DIR="${PI_MANAGER_CHROMIUM_USER_DATA_DIR:-/home/administrador/chromium-profile}"
VENV_DIR="$INSTALL_DIR/venv"
SERVICE_NAME="${SERVICE_NAME:-raspberry-pi-manager}"
GIT_REPO="${GIT_REPO:-https://github.com/victorjoaonull/raspberry-pi-manager.git}"
# Se desejar clonar do GitHub, exporte CLONE_FROM_GITHUB=true antes de rodar
CLONE_FROM_GITHUB="${CLONE_FROM_GITHUB:-false}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"

# ========== VERIFICAR CONECTIVIDADE ==========
echo -e "${BLUE}[1.5/12]${NC} Verificando conectividade de rede..."
NET_OK=false
for i in {1..5}; do
    if ping -c 1 8.8.8.8 &>/dev/null || ping -c 1 1.1.1.1 &>/dev/null; then
        echo -e "${GREEN}✅ Conectividade verificada${NC}"
        NET_OK=true
        break
    fi
    if [ $i -lt 5 ]; then
        echo -e "${YELLOW}⚠️  Tentativa $i/5: sem conectividade. Aguardando...${NC}"
        sleep 5
    fi
done
if [ "$NET_OK" = false ]; then
    echo -e "${RED}❌ Sem conectividade de rede. Verifique sua conexão.${NC}"
    exit 1
fi

# Locale UTF-8 e verificações básicas (após rede, para apt install locales) — scripts/install-preflight-checks.sh
_PREFLIGHT="${REPO_DIR}/scripts/install-preflight-checks.sh"
if [ -f "$_PREFLIGHT" ]; then
    # shellcheck source=scripts/install-preflight-checks.sh
    source "$_PREFLIGHT"
    pi_manager_run_preflight_checks
fi

# (Troca de IPv4 já aplicada após o assistente, se PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1.)

# ========== ATUALIZAR SISTEMA ==========
echo -e "${BLUE}[2/12]${NC} Atualizando sistema..."
APT_OK=false
for i in {1..3}; do
    if apt update && apt upgrade -y; then
        APT_OK=true
        break
    fi
    if [ $i -lt 3 ]; then
        echo -e "${YELLOW}⚠️  apt falhou. Tentativa $((i+1))/3...${NC}"
        sleep 10
    fi
done
if [ "$APT_OK" = false ]; then
    echo -e "${RED}❌ Falha ao atualizar sistema após 3 tentativas${NC}"
    if type pi_manager_network_swap_end >/dev/null 2>&1; then
        pi_manager_network_swap_end || true
    fi
    exit 1
fi

if type pi_manager_network_swap_end >/dev/null 2>&1; then
    pi_manager_network_swap_end || true
fi

# ========== INSTALAR DEPENDÊNCIAS ==========
echo -e "${BLUE}[3/12]${NC} Instalando dependências..."
apt install -y python3-pip python3-venv nginx git chromium python3-full xdotool network-manager python3-pam --no-install-recommends

# ========== CRIAR DIRETÓRIO DE INSTALAÇÃO ==========
echo -e "${BLUE}[4/12]${NC} Criando diretório de instalação..."
mkdir -p "$INSTALL_DIR"
chown administrador:administrador "$INSTALL_DIR"

# ========== COPIAR ARQUIVOS DO PROJETO ==========
echo -e "${BLUE}[5/12]${NC} Copiando arquivos do projeto..."
if [ "$CLONE_FROM_GITHUB" = "true" ]; then
    echo "Clonando do repositório GitHub: $GIT_REPO"
    sudo -u administrador git clone "$GIT_REPO" "$INSTALL_DIR"
else
    echo "Copiando arquivos do diretório local: $REPO_DIR"
    # Suporta projetos que colocam os arquivos diretamente no repositório
    # ou dentro de um subdiretório `src`.
    if [ -d "$REPO_DIR/src" ]; then
        SRC_DIR="$REPO_DIR/src"
    else
        SRC_DIR="$REPO_DIR"
    fi
    echo "  Fonte: $SRC_DIR"

    # Se a fonte for o mesmo caminho do destino (ex.: o usuário executou o
    # instalador de dentro do próprio diretório alvo), NÃO copie para evitar
    # criar cópias recursivas dentro de si mesmo.
    if [ "$(realpath "$SRC_DIR")" = "$(realpath "$INSTALL_DIR")" ]; then
        echo -e "${YELLOW}⚠️  Fonte e destino são o mesmo diretório; arquivos já estão no lugar.${NC}"
    else
        # Use rsync se disponível (mais robusto), fallback para cp com nullglob
        if command -v rsync >/dev/null 2>&1; then
            sudo -u administrador rsync -a --exclude='.git' "$SRC_DIR/" "$INSTALL_DIR/"
        else
            # Evita erro com globs que não casam (set -e presente)
            shopt -s nullglob
            FILES=( "$SRC_DIR/"* )
            if [ ${#FILES[@]} -gt 0 ]; then
                sudo -u administrador cp -r "${FILES[@]}" "$INSTALL_DIR/"
            fi
            shopt -u nullglob
        fi

        # Copy possible auxiliary files: prefer repository root, fallback to SRC_DIR
        if [ -f "$REPO_DIR/requirements.txt" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
            cp "$REPO_DIR/requirements.txt" "$INSTALL_DIR/"
        elif [ -f "$SRC_DIR/requirements.txt" ] && [ "$(realpath "$SRC_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
            cp "$SRC_DIR/requirements.txt" "$INSTALL_DIR/"
        fi
    fi
    
    # Se há um arquivo app.py diretamente em REPO_DIR, copie também
    if [ -f "$REPO_DIR/app.py" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        cp "$REPO_DIR/app.py" "$INSTALL_DIR/"
    fi

    if [ -f "$REPO_DIR/update_app.sh" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        cp "$REPO_DIR/update_app.sh" "$INSTALL_DIR/"
    elif [ -f "$SRC_DIR/update_app.sh" ] && [ "$(realpath "$SRC_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        cp "$SRC_DIR/update_app.sh" "$INSTALL_DIR/"
    fi
    if [ -f "$REPO_DIR/uninstall.sh" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        cp "$REPO_DIR/uninstall.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/uninstall.sh"
    fi
    if [ -f "$REPO_DIR/scripts/fix-pam-on-pi.sh" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        mkdir -p "$INSTALL_DIR/scripts"
        cp "$REPO_DIR/scripts/fix-pam-on-pi.sh" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/fix-pam-on-pi.sh"
    fi
    if [ -f "$REPO_DIR/scripts/lib-pam-venv.sh" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        mkdir -p "$INSTALL_DIR/scripts"
        cp "$REPO_DIR/scripts/lib-pam-venv.sh" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/lib-pam-venv.sh"
    fi
    if [ -f "$REPO_DIR/scripts/lib-network-swap-for-update.sh" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        mkdir -p "$INSTALL_DIR/scripts"
        cp "$REPO_DIR/scripts/lib-network-swap-for-update.sh" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/lib-network-swap-for-update.sh"
    fi
    if [ -f "$REPO_DIR/scripts/install-wizard.sh" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        mkdir -p "$INSTALL_DIR/scripts"
        cp "$REPO_DIR/scripts/install-wizard.sh" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/install-wizard.sh"
    fi
    if [ -f "$REPO_DIR/scripts/install-preflight-checks.sh" ] && [ "$(realpath "$REPO_DIR")" != "$(realpath "$INSTALL_DIR")" ]; then
        mkdir -p "$INSTALL_DIR/scripts"
        cp "$REPO_DIR/scripts/install-preflight-checks.sh" "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/install-preflight-checks.sh"
    fi
fi
chown -R administrador:administrador "$INSTALL_DIR"

# ========== CRIAR AMBIENTE VIRTUAL ==========
# python3-pam (apt) instala extensão por VERSÃO de Python. Se `python3` for 3.13 mas o
# pacote só fornecer pam para 3.11/3.12, o venv herdaria site-packages mas import pam falha.
# Escolhemos o primeiro interpretador do sistema em que "import pam" funciona.
INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "${INSTALLER_ROOT}/scripts/lib-pam-venv.sh" ]; then
    echo -e "${RED}❌ Falta ${INSTALLER_ROOT}/scripts/lib-pam-venv.sh (mantenha o repositório completo).${NC}"
    exit 1
fi
# shellcheck source=scripts/lib-pam-venv.sh
source "${INSTALLER_ROOT}/scripts/lib-pam-venv.sh"

echo -e "${BLUE}[6/12]${NC} Criando ambiente virtual Python..."
if [ -n "${VENV_PYTHON_CMD:-}" ]; then
    VPY="${VENV_PYTHON_CMD}"
    echo -e "${GREEN}✅ Usando VENV_PYTHON_CMD do ambiente: $VPY${NC}"
elif pick_python_with_pam; then
    VPY="$PICK_PAM_PY"
    echo -e "${GREEN}✅ Python do venv (import pam OK neste binário do sistema): $VPY${NC}"
else
    VPY="$(command -v python3)"
    echo -e "${YELLOW}⚠️  Nenhum python3.X do sistema importou 'pam' pelo apt (comum no Debian Trixie + Python 3.13).${NC}"
    echo -e "${GREEN}    Venv com ${VPY}; no passo [7] será instalado python-pam via pip se necessário.${NC}"
fi
sudo -u administrador "$VPY" -m venv "$VENV_DIR" --system-site-packages

# Debian: forçar herança de site-packages do sistema (python3-pam no apt)
PYVENV_CFG="$VENV_DIR/pyvenv.cfg"
if [ -f "$PYVENV_CFG" ] && grep -q '^include-system-site-packages = false' "$PYVENV_CFG" 2>/dev/null; then
    sed -i 's/^include-system-site-packages = false/include-system-site-packages = true/' "$PYVENV_CFG"
    echo -e "${GREEN}✅ pyvenv.cfg: include-system-site-packages=true (corrigido)${NC}"
fi

# ========== INSTALAR DEPENDÊNCIAS PYTHON ==========
echo -e "${BLUE}[7/12]${NC} Instalando Python requirements..."
sudo -u administrador "$VENV_DIR/bin/pip" install --upgrade pip
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    sudo -u administrador "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
else
    echo -e "${YELLOW}⚠️  requirements.txt não encontrado em $INSTALL_DIR; pulando instalação de dependências Python.${NC}"
fi

# PAM: preferir módulo do apt (herdado no venv). Se não importar (Trixie/3.13 sem .so para pam), usar PyPI.
if ! ensure_pam_in_venv_for_path "$VENV_DIR" administrador; then
    echo -e "${RED}❌ PAM continua indisponível. Login web não funcionará até corrigir.${NC}"
fi

# ========== CRIAR SHELL SCRIPT WRAPPER ==========
echo -e "${BLUE}[8/12]${NC} Criando script wrapper..."
cat > "$INSTALL_DIR/run.sh" << EOF
#!/bin/bash
set -e

cd "$INSTALL_DIR"

# Ativar ambiente virtual
if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
else
    echo "Ambiente virtual não encontrado"
    exit 1
fi

# Executar aplicação
exec python "$INSTALL_DIR/app.py"
EOF

chmod +x "$INSTALL_DIR/run.sh"
chown administrador:administrador "$INSTALL_DIR/run.sh"

# ========== CRIAR DIRETÓRIOS DE CONFIGURAÇÃO ==========
echo -e "${BLUE}[9/12]${NC} Criando diretórios de configuração..."
mkdir -p "$INSTALL_DIR/config"
mkdir -p "$INSTALL_DIR/static"
mkdir -p "$INSTALL_DIR/logs"
chown administrador:administrador "$INSTALL_DIR/config"
chown administrador:administrador "$INSTALL_DIR/static"
chown administrador:administrador "$INSTALL_DIR/logs"

# Configurar arquivo autostart.conf se não existir
if [ ! -f "$INSTALL_DIR/config/autostart.conf" ]; then
    echo -e "${YELLOW}⚠️  Criando autostart.conf padrão...${NC}"
    cat > "$INSTALL_DIR/config/autostart.conf" << 'EOF'
# URLs para abrir automaticamente no Chromium
http://localhost:5000
https://www.google.com
EOF
    chown administrador:administrador "$INSTALL_DIR/config/autostart.conf"
fi

# ========== INSTALAR UPDATE_APP.SH ==========
echo -e "${BLUE}[10.5/12]${NC} Instalando script de atualização..."
if [ -f "$INSTALL_DIR/update_app.sh" ]; then
    cp "$INSTALL_DIR/update_app.sh" /usr/local/bin/update_app.sh
    chmod +x /usr/local/bin/update_app.sh
    chown root:root /usr/local/bin/update_app.sh
    echo "✅ update_app.sh instalado em /usr/local/bin/"
elif [ -f "$REPO_DIR/update_app.sh" ]; then
    cp "$REPO_DIR/update_app.sh" /usr/local/bin/update_app.sh
    chmod +x /usr/local/bin/update_app.sh
    chown root:root /usr/local/bin/update_app.sh
    echo "✅ update_app.sh instalado em /usr/local/bin/"
else
    echo "⚠️  update_app.sh não encontrado; pulando."
fi

# ========== CONFIGURAR PERMISSÕES SUDO ==========
echo -e "${BLUE}[10/12]${NC} Configurando permissões sudo..."
cat > /usr/local/bin/pi-manager-nmcli << 'EOF'
#!/bin/bash
# Wrapper seguro para nmcli chamado pelo pi-manager.
# Loga a chamada e passa os argumentos para nmcli.
LOG=/var/log/pi-manager-nmcli.log
mkdir -p "$(dirname "$LOG")"
echo "$(date -Iseconds) nmcli called by $(whoami) args: $*" >> "$LOG"
# Aqui você pode adicionar validações adicionais dos argumentos.
exec /usr/bin/nmcli "$@"
EOF

chmod 750 /usr/local/bin/pi-manager-nmcli
chown root:root /usr/local/bin/pi-manager-nmcli

touch /var/log/pi-manager-nmcli.log || true
chown root:adm /var/log/pi-manager-nmcli.log || true
chmod 640 /var/log/pi-manager-nmcli.log || true

# Wrapper seguro para chpasswd (apenas altera senha do usuário 'administrador')
cat > /usr/local/bin/pi-manager-chpasswd << 'EOF'
#!/bin/bash
LOG=/var/log/pi-manager-chpasswd.log
mkdir -p "$(dirname "$LOG")"
echo "$(date -Iseconds) chpasswd called by $(whoami)" >> "$LOG"
# Leia stdin e verifique formato
read LINE
if [[ "$LINE" != administrador:* ]]; then
    echo "Only administrador password changes allowed" >&2
    exit 1
fi
echo "$LINE" | /usr/sbin/chpasswd
EXIT_CODE=$?
echo "$(date -Iseconds) result: $EXIT_CODE" >> "$LOG"
exit $EXIT_CODE
EOF

chmod 750 /usr/local/bin/pi-manager-chpasswd
chown root:root /usr/local/bin/pi-manager-chpasswd
touch /var/log/pi-manager-chpasswd.log || true
chown root:adm /var/log/pi-manager-chpasswd.log || true
chmod 640 /var/log/pi-manager-chpasswd.log || true

# Wrapper seguro para hostname (valida e aplica hostname persistente)
cat > /usr/local/bin/pi-manager-hostname << 'EOF'
#!/bin/bash
LOG=/var/log/pi-manager-hostname.log
mkdir -p "$(dirname "$LOG")"
echo "$(date -Iseconds) hostname called by $(whoami) args: $*" >> "$LOG"
NEWHOST="$1"
if [ -z "$NEWHOST" ]; then
    echo "Uso: pi-manager-hostname <hostname>" >&2
    exit 1
fi
# Validação simples do hostname
if ! [[ "$NEWHOST" =~ ^[A-Za-z0-9-]{1,63}$ ]]; then
    echo "Hostname inválido" >&2
    echo "$(date -Iseconds) invalid hostname: $NEWHOST" >> "$LOG"
    exit 2
fi
# Aplica hostname via hostnamectl
/usr/bin/hostnamectl set-hostname "$NEWHOST"
RC=$?
if [ $RC -ne 0 ]; then
    echo "hostnamectl falhou com code $RC" >> "$LOG"
    exit $RC
fi
# Atualiza /etc/hostname (arquivo persistente)
echo "$NEWHOST" > /etc/hostname
chown root:root /etc/hostname
chmod 644 /etc/hostname

# Atualiza /etc/hosts: substitui 127.0.1.1 existente ou adiciona
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEWHOST/" /etc/hosts
else
    echo -e "127.0.1.1\t$NEWHOST" >> /etc/hosts
fi

echo "$(date -Iseconds) hostname set to $NEWHOST" >> "$LOG"
exit 0
EOF

chmod 750 /usr/local/bin/pi-manager-hostname
chown root:root /usr/local/bin/pi-manager-hostname
touch /var/log/pi-manager-hostname.log || true
chown root:adm /var/log/pi-manager-hostname.log || true
chmod 640 /var/log/pi-manager-hostname.log || true

# Wrapper para apt instalar python3-pam (update_app.sh / webhook rodam como administrador)
cat > /usr/local/bin/pi-manager-ensure-deps << 'ENSUREOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-pam
exit 0
ENSUREOF
chmod 750 /usr/local/bin/pi-manager-ensure-deps
chown root:root /usr/local/bin/pi-manager-ensure-deps

# Wrapper: remove locks Singleton do Chromium como root (ficheiros criados por sudo / outro UID)
cat > /usr/local/bin/pi-manager-chromium-clean-locks << 'LOCKCLEANEOF'
#!/bin/bash
# Corre como root (sudoers): encerra Chromium do perfil gerido e apaga Singleton* (incl. ficheiros de outro UID).
kill_chromium_for_profile() {
  local prof="$1"
  [ -d /proc ] || return 0
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -Fq -- "--user-data-dir=$prof"; then
      kill -9 "${d##*/}" 2>/dev/null || true
    fi
  done
}
ENV_FILE="/etc/default/raspberry-pi-manager"
profile="/home/administrador/chromium-profile"
if [ -f "$ENV_FILE" ]; then
  line="$(grep -E '^[[:space:]]*PI_MANAGER_CHROMIUM_USER_DATA_DIR=' "$ENV_FILE" 2>/dev/null | tail -n1 || true)"
  if [ -n "$line" ]; then
    val="${line#*=}"
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
    [ -n "$val" ] && profile="$val"
  fi
fi
kill_chromium_for_profile "$profile"
sleep 1
clean_dir() {
  local d="$1"
  local depth="${2:-4}"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth "$depth" \( -name 'Singleton*' -o -name '.com.google.Chrome*' \) -exec rm -f {} \; 2>/dev/null || true
}
clean_dir "$profile" 4
clean_dir "/home/administrador/.config/chromium" 3
clean_dir "/home/administrador/.cache/chromium" 3
exit 0
LOCKCLEANEOF
chmod 750 /usr/local/bin/pi-manager-chromium-clean-locks
chown root:root /usr/local/bin/pi-manager-chromium-clean-locks

# Wrapper: reinício/desligamento só com subcomandos fixos (evita sudo shutdown genérico)
cat > /usr/local/bin/pi-manager-power << 'POWEREOF'
#!/bin/bash
set -e
LOG=/var/log/pi-manager-power.log
action="$1"
case "$action" in
  reboot-now) /usr/sbin/shutdown -r now ;;
  halt-now)   /usr/sbin/shutdown -h now ;;
  reboot-1)   /usr/sbin/shutdown -r +1 ;;
  halt-1)     /usr/sbin/shutdown -h +1 ;;
  *)
    echo "uso: pi-manager-power reboot-now|halt-now|reboot-1|halt-1" >&2
    echo "$(date -Iseconds) invalid action: $action" >> "$LOG"
    exit 2
    ;;
esac
echo "$(date -Iseconds) ok $action" >> "$LOG"
exit 0
POWEREOF
chmod 750 /usr/local/bin/pi-manager-power
chown root:root /usr/local/bin/pi-manager-power
touch /var/log/pi-manager-power.log || true
chown root:adm /var/log/pi-manager-power.log || true
chmod 640 /var/log/pi-manager-power.log || true

# Escreve sudoers restrito apontando apenas para os wrappers (valide com visudo)

cat > /etc/sudoers.d/pi-manager << EOF
administrador ALL=(root) NOPASSWD: /usr/local/bin/pi-manager-nmcli, /usr/local/bin/pi-manager-chpasswd, /usr/local/bin/pi-manager-hostname, /usr/local/bin/pi-manager-ensure-deps, /usr/local/bin/pi-manager-chromium-clean-locks, /usr/local/bin/pi-manager-power, /usr/bin/systemctl restart ${SERVICE_NAME}
EOF
chown root:root /etc/sudoers.d/pi-manager
chmod 440 /etc/sudoers.d/pi-manager

# Validar o arquivo sudoers criado
if ! visudo -cf /etc/sudoers.d/pi-manager >/dev/null 2>&1; then
    echo -e "${RED}❌ Erro: o arquivo /etc/sudoers.d/pi-manager contém erros${NC}"
    cat /etc/sudoers.d/pi-manager
    exit 1
fi

# Testar se as permissões funcionam (apenas se o usuário existe)
if id "administrador" &>/dev/null 2>&1; then
    echo -e "${BLUE}🔒 Testando permissões sudo para o usuário administrador...${NC}"
    if sudo -u administrador -n /usr/local/bin/pi-manager-nmcli --version >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Permissões sudo verificadas${NC}"
    else
        echo -e "${YELLOW}⚠️  Sudoers configurado mas permissões podem não estar funcionando.${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Usuário administrador não existe ainda; pulando teste de permissões.${NC}"
fi

# ========== CRIAR ARQUIVO DE AMBIENTE PARA WEBHOOK ==========
echo -e "${BLUE}[11/12]${NC} Criando arquivo de variáveis de ambiente..."
ENV_FILE="/etc/default/${SERVICE_NAME}"
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" << 'ENVEOF'
# Variáveis de ambiente para raspberry-pi-manager
# Edite este arquivo e reinicie o serviço: sudo systemctl restart raspberry-pi-manager

# Secret para validar webhooks do GitHub (OBRIGATÓRIO para auto-update)
WEBHOOK_SECRET=

# Nome do serviço systemd para reiniciar após atualização
SERVICE_NAME=raspberry-pi-manager

# Diretório da app (update_app.sh em /usr/local/bin usa esta linha)
#APP_INSTALL_DIR=/home/administrador/raspberry-pi-manager

# Perfil Chromium (autostart, favoritos, atalho na área de trabalho)
#PI_MANAGER_CHROMIUM_USER_DATA_DIR=/home/administrador/chromium-profile

# Logs da app (browser-launch, etc.); por defeito usa INSTALL_DIR/logs
#PI_MANAGER_LOG_DIR=/home/administrador/raspberry-pi-manager/logs

# HTTPS atrás de proxy: cookies seguros (1/true/yes)
#SESSION_COOKIE_SECURE=true
#SESSION_COOKIE_SAMESITE=Lax

# Login PAM: utilizador Linux e serviços (login,sshd,su,sudo)
#PI_MANAGER_PAM_USER=administrador
#PI_MANAGER_PAM_SERVICES=login,su,sudo

# Chave de sessão Flask (o instalador gera automaticamente se a linha faltar ou estiver vazia)
#FLASK_SECRET_KEY=

# Endpoints /api/diagnostic/* e /api/favorites/diagnostic (1/true/yes para ativar)
#PI_MANAGER_DIAGNOSTICS=false

# Outras variáveis opcionais
#DEBUG=false
#FLASK_HOST=0.0.0.0
#FLASK_PORT=5000
ENVEOF
    chown root:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "✅ Criado $ENV_FILE (configure WEBHOOK_SECRET nele)"
else
    echo "ℹ️  $ENV_FILE já existe; preservando."
fi

# Caminho da instalação para update_app.sh (quando instalado em /usr/local/bin)
if [ -f "$ENV_FILE" ] && ! grep -q '^APP_INSTALL_DIR=' "$ENV_FILE" 2>/dev/null; then
    echo "APP_INSTALL_DIR=$INSTALL_DIR" >> "$ENV_FILE"
    echo -e "${GREEN}✅ APP_INSTALL_DIR registrado em $ENV_FILE (atualizações automáticas).${NC}"
fi
if [ -f "$ENV_FILE" ] && ! grep -q '^PI_MANAGER_CHROMIUM_USER_DATA_DIR=' "$ENV_FILE" 2>/dev/null; then
    echo "PI_MANAGER_CHROMIUM_USER_DATA_DIR=$PI_MANAGER_CHROMIUM_USER_DATA_DIR" >> "$ENV_FILE"
    echo -e "${GREEN}✅ PI_MANAGER_CHROMIUM_USER_DATA_DIR registrado em $ENV_FILE.${NC}"
fi

# Chave persistente Flask (evita invalidar sessões a cada restart do serviço)
if [ -f "$ENV_FILE" ]; then
    if grep -qE '^FLASK_SECRET_KEY=.+' "$ENV_FILE" 2>/dev/null; then
        echo -e "${GREEN}✅ FLASK_SECRET_KEY já definida em $ENV_FILE${NC}"
    else
        sed -i '/^FLASK_SECRET_KEY=$/d' "$ENV_FILE" 2>/dev/null || true
        if command -v openssl >/dev/null 2>&1; then
            _FSK="$(openssl rand -hex 32)"
        else
            _FSK="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || echo "")"
        fi
        if [ -n "$_FSK" ]; then
            echo "FLASK_SECRET_KEY=$_FSK" >> "$ENV_FILE"
            chmod 600 "$ENV_FILE" 2>/dev/null || true
            echo -e "${GREEN}✅ FLASK_SECRET_KEY gerada e anexada a $ENV_FILE (reinicie o serviço).${NC}"
        else
            echo -e "${YELLOW}⚠️  Não foi possível gerar FLASK_SECRET_KEY automaticamente; defina manualmente.${NC}"
        fi
    fi
fi

# ========== CONFIGURAR SERVIÇO SYSTEMD ==========
[ -n "$SERVICE_NAME" ] || SERVICE_NAME="${SERVICE_NAME}"
echo -e "${BLUE}[11.5/12]${NC} Configurando serviço systemd..."

# Garantir que ExecStart está corrigido com o caminho absoluto
PYTHON_PATH="$INSTALL_DIR/venv/bin/python"
APP_PATH="$INSTALL_DIR/app.py"

# Validar que os caminhos existem
if [ ! -f "$PYTHON_PATH" ]; then
    echo -e "${YELLOW}⚠️  Aviso: Python não encontrado em $PYTHON_PATH${NC}"
    echo -e "${BLUE}Criando venv novamente...${NC}"
    sudo -u administrador python3 -m venv "$INSTALL_DIR/venv" --system-site-packages || {
        echo -e "${RED}❌ Erro ao criar venv${NC}"
        exit 1
    }
    PYVENV_CFG="$INSTALL_DIR/venv/pyvenv.cfg"
    if [ -f "$PYVENV_CFG" ] && grep -q '^include-system-site-packages = false' "$PYVENV_CFG" 2>/dev/null; then
        sed -i 's/^include-system-site-packages = false/include-system-site-packages = true/' "$PYVENV_CFG"
    fi
fi

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Gerenciador Web Raspberry PI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=administrador
Group=administrador
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=/etc/default/${SERVICE_NAME}
ExecStart=$PYTHON_PATH $APP_PATH
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Ambiente
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Unit mascarada impede start/enable (symlink para /dev/null)
if systemctl is-masked --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Serviço estava mascarado — removendo máscara...${NC}"
    systemctl unmask "${SERVICE_NAME}.service" || true
    systemctl daemon-reload
fi
if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Parando serviço anterior para reinstalação...${NC}"
    systemctl stop "${SERVICE_NAME}.service" || true
    sleep 2
fi
# Garantir unmask antes de enable (caso is-masked não detecte em todas as versões)
systemctl unmask "${SERVICE_NAME}.service" 2>/dev/null || true

if ! systemctl enable "${SERVICE_NAME}.service" 2>/dev/null; then
    echo -e "${RED}❌ Erro ao habilitar serviço${NC}"
    systemctl status "${SERVICE_NAME}.service" || true
    exit 1
fi

# Validar arquivo de serviço
echo -e "${BLUE}🔍 Validando arquivo de serviço...${NC}"
if ! systemd-analyze verify /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Aviso: systemd-analyze não disponível, mas continuando...${NC}"
fi

# ========== CONFIGURAR AUTO-LOGIN ==========
echo -e "${BLUE}[12/12]${NC} Configurando auto-login gráfico..."
if [ -f /etc/lightdm/lightdm.conf ]; then
    sed -i 's/^#autologin-user=.*/autologin-user=administrador/' /etc/lightdm/lightdm.conf
    sed -i 's/^#autologin-user-timeout=.*/autologin-user-timeout=0/' /etc/lightdm/lightdm.conf
fi

# Configurar para iniciar no modo gráfico
raspi-config nonint do_boot_behaviour B4

# ========== CONFIGURAR CHROMIUM ==========
echo -e "${BLUE}[13/12]${NC} Configurando Chromium..."
# Criar diretório de perfil personalizado (pasta configurável)
mkdir -p "$PI_MANAGER_CHROMIUM_USER_DATA_DIR"
chown -R administrador:administrador "$PI_MANAGER_CHROMIUM_USER_DATA_DIR"

# Inicializar git no diretório se não for clone do GitHub
if [ "$CLONE_FROM_GITHUB" != "true" ] && ! [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "${BLUE}📦 Inicializando repositório git local...${NC}"
    cd "$INSTALL_DIR"
    sudo -u administrador git init
    sudo -u administrador git remote add origin "$GIT_REPO" 2>/dev/null || true
    sudo -u administrador git branch -M main
    # Commit vazio para existir HEAD (update_app.sh / git reset não falham)
    sudo -u administrador git -c user.email=pi-manager@local -c user.name="Pi Manager" \
        commit --allow-empty -m "chore: base da instalação local" 2>/dev/null || true
    echo "✅ Git inicializado; execute 'git pull origin main' para sincronizar com o GitHub"
fi

# Atalho na área de trabalho: mesmo perfil e mesmas flags base que src/app.py (open_browser_with_urls)
echo -e "${BLUE}⚙️  Criando atalho do Chromium na área de trabalho (perfil pi-manager)...${NC}"
USER_AUTOSTART_DIR="/home/administrador/.config/autostart"
mkdir -p "$USER_AUTOSTART_DIR"

# Pasta "Área de trabalho" / Desktop localizada (xdg-user-dir)
USER_DESKTOP_DIR=""
if id administrador >/dev/null 2>&1; then
    if command -v runuser >/dev/null 2>&1; then
        USER_DESKTOP_DIR="$(runuser -u administrador -- xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    if [ -z "$USER_DESKTOP_DIR" ]; then
        USER_DESKTOP_DIR="$(sudo -u administrador env HOME=/home/administrador xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
fi
if [ -z "$USER_DESKTOP_DIR" ] || [ ! -d "$USER_DESKTOP_DIR" ]; then
    USER_DESKTOP_DIR="/home/administrador/Desktop"
fi
mkdir -p "$USER_DESKTOP_DIR"
chown administrador:administrador "$USER_DESKTOP_DIR" 2>/dev/null || true

# Mesma prioridade que app.py: /usr/bin/chromium-browser, senão chromium (e fallbacks)
CHROMIUM_BIN=""
if [ -x /usr/bin/chromium-browser ]; then
    CHROMIUM_BIN="/usr/bin/chromium-browser"
elif command -v chromium-browser >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v chromium-browser)"
elif command -v chromium >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v chromium)"
elif command -v google-chrome-stable >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v google-chrome-stable)"
elif command -v google-chrome >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v google-chrome)"
fi

if [ -z "$CHROMIUM_BIN" ]; then
    echo -e "${YELLOW}⚠️  Chromium não encontrado no PATH. Atalho usará /usr/bin/chromium (instale o pacote).${NC}"
    CHROMIUM_BIN="/usr/bin/chromium"
fi
echo -e "${GREEN}✅ Binário do atalho: $CHROMIUM_BIN${NC}"

DESKTOP_SHORTCUT="$USER_DESKTOP_DIR/Chromium-Raspberry.desktop"
# Flags alinhadas a open_browser_with_urls em src/app.py (sem URLs; %U = arquivos/links arrastados)
# Manter sincronizado ao alterar o lançamento automático no Python.
cat > "$DESKTOP_SHORTCUT" << DESKTOPEOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium (Pi Manager)
Name[pt_BR]=Chromium (Pi Manager)
Comment=Mesmo perfil e flags do Raspberry Pi Manager ($PI_MANAGER_CHROMIUM_USER_DATA_DIR)
Comment[pt_BR]=Mesmo perfil do gerenciador: autostart, favoritos e kiosk
TryExec=${CHROMIUM_BIN}
Exec=env DISPLAY=:0 ${CHROMIUM_BIN} --user-data-dir=$PI_MANAGER_CHROMIUM_USER_DATA_DIR --no-first-run --start-maximized --ignore-certificate-errors --noerrdialogs --disable-session-crashed-bubble --disable-single-process --disable-features=ChromeWhatsNewUI --disable-features=SingleProcess --disable-features=ProcessPerSite --disable-gpu --disable-dbus --disable-background-networking --disable-sync --disable-default-apps --disable-extensions --disable-component-extensions-with-background-pages --disable-client-side-phishing-detection --disable-crash-reporter --disable-ipc-flooding-protection --disable-prompt-on-repost --disable-renderer-backgrounding --disable-hang-monitor --no-sandbox --test-type --force-device-scale-factor=1 %U
Icon=chromium
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=false
DESKTOPEOF

# NÃO colocar Chromium em ~/.config/autostart: o serviço systemd já chama open_browser_with_urls()
LEGACY_AUTOSTART="$USER_AUTOSTART_DIR/Chromium-Raspberry.desktop"
if [ -f "$LEGACY_AUTOSTART" ]; then
    rm -f "$LEGACY_AUTOSTART"
    echo -e "${YELLOW}⚠️  Removido autostart legado $LEGACY_AUTOSTART (Chromium passa a subir só pelo serviço).${NC}"
fi

chown administrador:administrador "$DESKTOP_SHORTCUT" || true
chmod 755 "$DESKTOP_SHORTCUT" || true

# Tornar o atalho "confiável" para duplo clique (GTK / gerenciadores recentes)
if command -v gio >/dev/null 2>&1 && id administrador >/dev/null 2>&1; then
    runuser -u administrador -- gio set "$DESKTOP_SHORTCUT" metadata::trusted true 2>/dev/null \
        || sudo -u administrador gio set "$DESKTOP_SHORTCUT" metadata::trusted true 2>/dev/null \
        || true
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
    echo -e "${BLUE}🔍 Validando .desktop...${NC}"
    desktop-file-validate "$DESKTOP_SHORTCUT" && echo -e "${GREEN}✅ desktop-file-validate OK${NC}" \
        || echo -e "${YELLOW}⚠️  desktop-file-validate reportou avisos (ver acima).${NC}"
fi

echo -e "${GREEN}✅ Atalho: $DESKTOP_SHORTCUT${NC}"

# ========== INSTALAÇÃO CONCLUÍDA ==========
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          INSTALAÇÃO CONCLUÍDA COM SUCESSO!          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Obter IP da máquina
IP_ADDRESS=$(hostname -I | awk '{print $1}')

echo -e "${BLUE}📊 Informações da Instalação:${NC}"
echo -e "  📁 Diretório: $INSTALL_DIR"
echo -e "  🐍 Ambiente Virtual: $VENV_DIR"
echo -e "  🌐 Acesso Web: http://$IP_ADDRESS:5000"
echo -e "  👤 Usuário: administrador"
echo -e "  🔧 Serviço: $SERVICE_NAME"
echo ""

echo -e "${BLUE}📝 Comandos Úteis:${NC}"
echo -e "  📊 Status do serviço: ${GREEN}sudo systemctl status $SERVICE_NAME${NC}"
echo -e "  📋 Logs do serviço: ${GREEN}sudo journalctl -u $SERVICE_NAME -f${NC}"
echo -e "  🔄 Reiniciar serviço: ${GREEN}sudo systemctl restart $SERVICE_NAME${NC}"
echo -e "  🚀 Iniciar serviço: ${GREEN}sudo systemctl start $SERVICE_NAME${NC}"
echo -e "  ⏹️ Parar serviço: ${GREEN}sudo systemctl stop $SERVICE_NAME${NC}"
echo ""

echo -e "${YELLOW}⚠️ IMPORTANTE:${NC}"
echo -e "  • Acesse http://$IP_ADDRESS:5000 para usar o gerenciador"
echo -e "  • Configure as URLs em: $INSTALL_DIR/config/autostart.conf"
echo -e "  • Usuário padrão: administrador / raspberry"
echo -e "  • ALTERE A SENHA PADRÃO após o primeiro login!"
echo -e "  • PARA AUTO-UPDATE: Edite $ENV_FILE e defina WEBHOOK_SECRET"
echo -e "    Comando: sudo nano $ENV_FILE"
echo ""

echo -e "${BLUE}🔄 Iniciando o serviço...${NC}"
# Aguardar um pouco para garantir que o daemon recarregou
sleep 2
systemctl start "${SERVICE_NAME}.service" || true
sleep 3

# Verificar se o serviço está rodando
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}✅ Serviço iniciado com sucesso!${NC}"
    
    # Testar se a API responde usando nc ou /dev/tcp (mais portátil que curl)
    echo -e "${BLUE}🧪 Testando API...${NC}"
    sleep 2
    
    # Tenta conexão TCP porta 5000
    if timeout 3 bash -c "</dev/tcp/localhost/5000" 2>/dev/null; then
        echo -e "${GREEN}✅ API respondendo na porta 5000!${NC}"
    else
        echo -e "${YELLOW}⚠️  Não foi possível verificar API. Verifique os logs.${NC}"
    fi
else
    echo -e "${RED}❌ Erro ao iniciar o serviço. Verifique os logs:${NC}"
    echo -e "${YELLOW}sudo journalctl -u $SERVICE_NAME -n 30${NC}"
    echo ""
    echo -e "${BLUE}📋 Informações de diagnóstico:${NC}"
    echo -e "  Arquivo de serviço: /etc/systemd/system/${SERVICE_NAME}.service"
    echo -e "  Python executável: $PYTHON_PATH"
    echo -e "  App.py: $APP_PATH"
    echo -e "  Diretório de trabalho: $INSTALL_DIR"
    echo ""
    echo -e "${BLUE}Verificar arquivo de serviço:${NC}"
    cat /etc/systemd/system/${SERVICE_NAME}.service
    echo ""
    echo -e "${BLUE}Logs recentes:${NC}"
    journalctl -u $SERVICE_NAME -n 30 || true
    exit 1
fi

echo ""
read -p "🔄 Deseja reiniciar o sistema agora? (s/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    echo -e "${BLUE}🔄 Reiniciando sistema...${NC}"
    reboot
else
    echo -e "${GREEN}✨ Instalação concluída! O sistema está pronto para uso.${NC}"
fi

