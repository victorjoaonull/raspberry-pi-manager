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

# ========== LIMPAR INSTALAÇÕES ANTIGAS ==========
echo -e "${BLUE}[--]${NC} Removendo possíveis instalações antigas que contenham 'pi-manager' no nome..."
SEARCH_PATHS=("/home" "/opt" "/usr/local" "/srv" "/var/www" "/root" "/tmp")
FOUND=()
for p in "${SEARCH_PATHS[@]}"; do
    if [ -d "$p" ]; then
        while IFS= read -r -d $'\0' d; do
            FOUND+=("$d")
        done < <(find "$p" -maxdepth 3 -type d -iname "*pi-manager*" -print0 2>/dev/null || true)
    fi
done
if [ ${#FOUND[@]} -gt 0 ]; then
    # Resolver o caminho real do REPO_DIR para comparação segura
    REPO_DIR_REAL="$(realpath "$REPO_DIR" 2>/dev/null || echo "$REPO_DIR")"
    
    echo "Encontrado diretórios para remoção:" 
    DIRS_TO_REMOVE=()
    for d in "${FOUND[@]}"; do
        D_REAL="$(realpath "$d" 2>/dev/null || echo "$d")"
        if [ "$D_REAL" = "$REPO_DIR_REAL" ]; then
            echo "  ⊘ $d (pulado - é origem do installer)"
        else
            echo "  - $d (será removido)"
            DIRS_TO_REMOVE+=("$d")
        fi
    done
    
    if [ ${#DIRS_TO_REMOVE[@]} -gt 0 ]; then
        echo "Removendo diretórios antigos..."
        # Mudar para um diretório seguro antes de remover possíveis diretórios
        cd /tmp || cd / || true
        
        for d in "${DIRS_TO_REMOVE[@]}"; do
            echo "  Removendo: $d"
            rm -rf "$d" || echo -e "${YELLOW}⚠️  Aviso: não foi possível remover $d${NC}"
        done
    fi
else
    echo "Nenhuma instalação antiga encontrada."
fi

# ========== VARIÁVEIS DE CONFIGURAÇÃO ==========
# Permite sobrescrever o diretório de instalação via variável de ambiente
INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
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
    exit 1
fi

# ========== INSTALAR DEPENDÊNCIAS ==========
echo -e "${BLUE}[3/12]${NC} Instalando dependências..."
apt install -y python3-pip python3-venv nginx git chromium python3-full xdotool network-manager --no-install-recommends

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
fi
chown -R administrador:administrador "$INSTALL_DIR"

# ========== CRIAR AMBIENTE VIRTUAL ==========
echo -e "${BLUE}[6/12]${NC} Criando ambiente virtual Python..."
sudo -u administrador python3 -m venv "$VENV_DIR" --system-site-packages

# ========== INSTALAR DEPENDÊNCIAS PYTHON ==========
echo -e "${BLUE}[7/12]${NC} Instalando Python requirements..."
sudo -u administrador "$VENV_DIR/bin/pip" install --upgrade pip
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
    sudo -u administrador "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
else
    echo -e "${YELLOW}⚠️  requirements.txt não encontrado em $INSTALL_DIR; pulando instalação de dependências Python.${NC}"
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
chown administrador:administrador "$INSTALL_DIR/config"
chown administrador:administrador "$INSTALL_DIR/static"

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

# Escreve sudoers restrito apontando apenas para o wrapper (valide com visudo)

cat > /etc/sudoers.d/pi-manager << 'EOF'
administrador ALL=(root) NOPASSWD: /usr/local/bin/pi-manager-nmcli, /usr/local/bin/pi-manager-chpasswd, /usr/local/bin/pi-manager-hostname
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
    if sudo -u administrador -n /usr/local/bin/pi-manager-nmcli help >/dev/null 2>&1; then
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
if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Parando serviço anterior para reinstalação...${NC}"
    systemctl stop "${SERVICE_NAME}.service" || true
    sleep 2
fi

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
# Criar diretório de perfil personalizado
mkdir -p /home/administrador/chromium-profile
chown -R administrador:administrador /home/administrador/chromium-profile

# Inicializar git no diretório se não for clone do GitHub
if [ "$CLONE_FROM_GITHUB" != "true" ] && ! [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "${BLUE}📦 Inicializando repositório git local...${NC}"
    cd "$INSTALL_DIR"
    sudo -u administrador git init
    sudo -u administrador git remote add origin "$GIT_REPO"
    sudo -u administrador git branch -M main
    echo "✅ Git inicializado; execute 'git pull origin main' para sincronizar com o GitHub"
fi

# Criar atalho .desktop "Chromium-Raspberry" no Desktop do usuário e em autostart
echo -e "${BLUE}⚙️  Criando atalho Chromium-Raspberry...${NC}"
USER_DESKTOP_DIR="/home/administrador/Desktop"
USER_AUTOSTART_DIR="/home/administrador/.config/autostart"
mkdir -p "$USER_DESKTOP_DIR"
mkdir -p "$USER_AUTOSTART_DIR"

# Detecta binário do Chromium (mais localizações)
CHROMIUM_BIN=""
for bin in chromium chromium-browser google-chrome google-chrome-stable; do
    if command -v "$bin" >/dev/null 2>&1; then
        CHROMIUM_BIN="$bin"
        echo -e "${GREEN}✅ Chromium encontrado: $CHROMIUM_BIN${NC}"
        break
    fi
done

if [ -z "$CHROMIUM_BIN" ]; then
    echo -e "${YELLOW}⚠️  Chromium não encontrado. Pulando configuração.${NC}"
    CHROMIUM_BIN="chromium"
fi

DESKTOP_FILE_CONTENT="[Desktop Entry]\nName=Chromium-Raspberry\nComment=Chromium custom profile for Raspberry PI Manager\nExec=$CHROMIUM_BIN --user-data-dir=/home/administrador/chromium-profile --no-first-run --start-maximized --ignore-certificate-errors --noerrdialogs --disable-session-crashed-bubble %U\nTerminal=false\nType=Application\nCategories=Network;WebBrowser;\nStartupNotify=false\n"

echo -e "$DESKTOP_FILE_CONTENT" > "$USER_DESKTOP_DIR/Chromium-Raspberry.desktop"
echo -e "[Desktop Entry]\nName=Chromium-Raspberry\nComment=Autostart Chromium custom profile for Raspberry PI Manager\nExec=$CHROMIUM_BIN --user-data-dir=/home/administrador/chromium-profile --no-first-run --start-maximized --ignore-certificate-errors --noerrdialogs --disable-session-crashed-bubble\nTerminal=false\nType=Application\nX-GNOME-Autostart-enabled=true\nStartupNotify=false\n" > "$USER_AUTOSTART_DIR/Chromium-Raspberry.desktop"

chown administrador:administrador "$USER_DESKTOP_DIR/Chromium-Raspberry.desktop" || true
chown administrador:administrador "$USER_AUTOSTART_DIR/Chromium-Raspberry.desktop" || true
chmod 755 "$USER_DESKTOP_DIR/Chromium-Raspberry.desktop" || true
chmod 644 "$USER_AUTOSTART_DIR/Chromium-Raspberry.desktop" || true

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

