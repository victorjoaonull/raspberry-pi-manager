
### 2. **install.sh** (Atualizado e melhorado)
```bash
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

# ========== VARIÁVEIS DE CONFIGURAÇÃO ==========
INSTALL_DIR="/home/administrador/pi-manager"
VENV_DIR="$INSTALL_DIR/venv"
SERVICE_NAME="pi-manager"
REPO_DIR="$(pwd)"

# ========== ATUALIZAR SISTEMA ==========
echo -e "${BLUE}[2/12]${NC} Atualizando sistema..."
apt update
apt upgrade -y

# ========== INSTALAR DEPENDÊNCIAS ==========
echo -e "${BLUE}[3/12]${NC} Instalando dependências..."
apt install -y \
    python3-pip \
    python3-venv \
    python3-full \
    nginx \
    git \
    chromium \
    chromium-driver \
    xdotool \
    network-manager \
    nmcli \
    lightdm \
    xserver-xorg \
    --no-install-recommends

# ========== CRIAR DIRETÓRIO DE INSTALAÇÃO ==========
echo -e "${BLUE}[4/12]${NC} Criando diretório de instalação..."
mkdir -p "$INSTALL_DIR"
chown administrador:administrador "$INSTALL_DIR"

# ========== COPIAR ARQUIVOS DO PROJETO ==========
echo -e "${BLUE}[5/12]${NC} Copiando arquivos do projeto..."
cp -r "$REPO_DIR/src/"* "$INSTALL_DIR/"
cp "$REPO_DIR/requirements.txt" "$INSTALL_DIR/"
chown -R administrador:administrador "$INSTALL_DIR"

# ========== CRIAR AMBIENTE VIRTUAL ==========
echo -e "${BLUE}[6/12]${NC} Criando ambiente virtual Python..."
sudo -u administrador python3 -m venv "$VENV_DIR"

# ========== INSTALAR DEPENDÊNCIAS PYTHON ==========
echo -e "${BLUE}[7/12]${NC} Instalando Python requirements..."
sudo -u administrador "$VENV_DIR/bin/pip" install --upgrade pip
sudo -u administrador "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

# ========== CRIAR DIRETÓRIOS DE CONFIGURAÇÃO ==========
echo -e "${BLUE}[8/12]${NC} Criando diretórios de configuração..."
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

# ========== CONFIGURAR PERMISSÕES SUDO ==========
echo -e "${BLUE}[9/12]${NC} Configurando permissões sudo..."
cat > /etc/sudoers.d/pi-manager << 'EOF'
administrador ALL=(ALL) NOPASSWD: /usr/bin/nmcli
administrador ALL=(ALL) NOPASSWD: /usr/bin/chpasswd
administrador ALL=(ALL) NOPASSWD: /usr/bin/hostnamectl
administrador ALL=(ALL) NOPASSWD: /usr/bin/chromium-browser
administrador ALL=(ALL) NOPASSWD: /usr/bin/chromium
administrador ALL=(ALL) NOPASSWD: /bin/systemctl
administrador ALL=(ALL) NOPASSWD: /usr/bin/pkill
administrador ALL=(ALL) NOPASSWD: /usr/bin/killall
administrador ALL=(ALL) NOPASSWD: /usr/bin/sed
administrador ALL=(ALL) NOPASSWD: /sbin/shutdown
administrador ALL=(ALL) NOPASSWD: /sbin/reboot
administrador ALL=(ALL) NOPASSWD: /bin/chown
administrador ALL=(ALL) NOPASSWD: /bin/chmod
EOF
chmod 440 /etc/sudoers.d/pi-manager

# ========== CONFIGURAR SERVIÇO SYSTEMD ==========
echo -e "${BLUE}[10/12]${NC} Configurando serviço systemd..."
cat > /etc/systemd/system/pi-manager.service << EOF
[Unit]
Description=Gerenciador Web Raspberry PI
After=graphical.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=administrador
Group=administrador
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$VENV_DIR/bin"
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/app.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pi-manager
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/administrador/.Xauthority

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable pi-manager.service

# ========== CONFIGURAR AUTO-LOGIN ==========
echo -e "${BLUE}[11/12]${NC} Configurando auto-login gráfico..."
if [ -f /etc/lightdm/lightdm.conf ]; then
    sed -i 's/^#autologin-user=.*/autologin-user=administrador/' /etc/lightdm/lightdm.conf
    sed -i 's/^#autologin-user-timeout=.*/autologin-user-timeout=0/' /etc/lightdm/lightdm.conf
fi

# Configurar para iniciar no modo gráfico
raspi-config nonint do_boot_behaviour B4

# ========== CONFIGURAR CHROMIUM ==========
echo -e "${BLUE}[12/12]${NC} Configurando Chromium..."
# Criar diretório de perfil personalizado
mkdir -p /home/administrador/chromium-profile
chown -R administrador:administrador /home/administrador/chromium-profile

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
echo ""

echo -e "${BLUE}🔄 Iniciando o serviço...${NC}"
systemctl start pi-manager.service
sleep 2

# Verificar se o serviço está rodando
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}✅ Serviço iniciado com sucesso!${NC}"
else
    echo -e "${RED}❌ Erro ao iniciar o serviço. Verifique os logs:${NC}"
    echo -e "${YELLOW}sudo journalctl -u $SERVICE_NAME -n 20${NC}"
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