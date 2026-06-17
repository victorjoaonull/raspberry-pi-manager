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

# ========== LIMPAR INSTALAÇÕES ANTIGAS ==========
# A detecção e remoção (purge total, com confirmação) das versões antigas é feita
# por detect_and_purge_old(), definida e chamada logo após as variáveis abaixo
# (precisa de INSTALL_DIR / SERVICE_NAME / REPO_DIR já definidos).

# ========== VARIÁVEIS DE CONFIGURAÇÃO ==========
# Permite sobrescrever o diretório de instalação via variável de ambiente
INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
VENV_DIR="$INSTALL_DIR/venv"
SERVICE_NAME="${SERVICE_NAME:-raspberry-pi-manager}"
# Diretório do repositório (onde o script está localizado)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_REPO="${GIT_REPO:-https://github.com/victorjoaonull/raspberry-pi-manager.git}"
# Se desejar clonar do GitHub, exporte CLONE_FROM_GITHUB=true antes de rodar
CLONE_FROM_GITHUB="${CLONE_FROM_GITHUB:-false}"

# ========== DETECÇÃO E REMOÇÃO DE VERSÕES ANTIGAS (PURGE) ==========
# Detecta artefatos de QUALQUER versão anterior (o nome do serviço/wrappers já
# mudou ao longo do tempo) via detecção DINÂMICA — por nome e por conteúdo que
# aponte ao app — e, após confirmação, faz um PURGE TOTAL antes de instalar do
# zero. Para automação (sem prompt), exporte PI_MANAGER_PURGE=yes.
detect_and_purge_old() {
    echo -e "${BLUE}[--]${NC} Procurando instalações anteriores..."

    local units=() files=() dirs=() found=()
    local u f d p name

    # 1) Units systemd: por NOME (*pi-manager*) e por CONTEÚDO (ExecStart do app)
    shopt -s nullglob
    for u in /etc/systemd/system/*pi-manager*.service /etc/systemd/system/*pi-manager*.timer; do
        units+=("$u")
    done
    while IFS= read -r u; do
        [ -n "$u" ] && units+=("$u")
    done < <(grep -rlE "/src/app\.py|/usr/local/bin/update_app\.sh|Gerenciador.*Raspberry" /etc/systemd/system/*.service 2>/dev/null || true)
    shopt -u nullglob
    if [ ${#units[@]} -gt 0 ]; then
        mapfile -t units < <(printf '%s\n' "${units[@]}" | sort -u)
        for u in "${units[@]}"; do found+=("unit: $(basename "$u")"); done
    fi

    # 2) Wrappers / scripts em /usr/local/bin
    shopt -s nullglob
    for f in /usr/local/bin/pi-manager-* /usr/local/bin/update_app.sh; do
        files+=("$f"); found+=("bin: $f")
    done
    shopt -u nullglob

    # 3) sudoers
    for f in /etc/sudoers.d/pi-manager /etc/sudoers.d/pi-manager.bak; do
        [ -e "$f" ] && { files+=("$f"); found+=("sudoers: $f"); }
    done

    # 4) nginx (nomes usados pelas versões)
    for f in /etc/nginx/sites-enabled/raspberry-pi-manager /etc/nginx/sites-available/raspberry-pi-manager \
             /etc/nginx/sites-enabled/pi-manager /etc/nginx/sites-available/pi-manager; do
        [ -e "$f" ] && { files+=("$f"); found+=("nginx: $f"); }
    done

    # 5) atalhos / autostart do kiosk
    for f in /home/administrador/.config/autostart/Chromium-Raspberry.desktop \
             /home/administrador/Desktop/Chromium-Raspberry.desktop; do
        [ -e "$f" ] && { files+=("$f"); found+=("atalho: $f"); }
    done

    # 6) env file
    if [ -e "/etc/default/${SERVICE_NAME}" ]; then
        files+=("/etc/default/${SERVICE_NAME}"); found+=("env: /etc/default/${SERVICE_NAME}")
    fi

    # 7) PURGE de dados do usuário (URLs, logs, perfil/favoritos, secret_key)
    for d in "$INSTALL_DIR/config" "$INSTALL_DIR/logs" \
             /home/administrador/chromium-profile \
             /home/administrador/.config/raspberry-pi-manager; do
        [ -e "$d" ] && { dirs+=("$d"); found+=("dados: $d"); }
    done

    # 8) Diretórios de instalações DUPLICADAS (nunca a fonte atual)
    while IFS= read -r -d $'\0' d; do
        if [ "$(realpath "$d")" != "$(realpath "$REPO_DIR")" ] && \
           [ "$(realpath "$d")" != "$(realpath "$INSTALL_DIR")" ]; then
            dirs+=("$d"); found+=("dir duplicado: $d")
        fi
    done < <(find /home /opt /srv /var/www /root /tmp -maxdepth 3 -type d -iname "*pi-manager*" -print0 2>/dev/null || true)

    if [ ${#found[@]} -eq 0 ]; then
        echo "  Nenhuma instalação anterior encontrada."
        return 0
    fi

    echo -e "${YELLOW}⚠️  Instalações/artefatos antigos encontrados:${NC}"
    for d in "${found[@]}"; do echo "   - $d"; done
    echo ""

    # Confirmação (pulada se PI_MANAGER_PURGE=yes)
    local resp="${PI_MANAGER_PURGE:-}"
    if [ "$resp" = "yes" ]; then
        resp="s"
    elif [ -t 0 ]; then
        read -r -p "Remover TUDO isso (PURGE TOTAL — inclui config, senha e favoritos) e prosseguir? (s/N): " resp
    else
        echo -e "${RED}❌ Sem terminal interativo. Para remover automaticamente, rode com PI_MANAGER_PURGE=yes${NC}"
        exit 1
    fi
    case "$resp" in
        [sSyY]*) ;;
        *) echo -e "${RED}Remoção cancelada — instalação abortada para não conflitar com a versão antiga.${NC}"; exit 1;;
    esac

    echo -e "${BLUE}🧹 Removendo versões antigas (purge total)...${NC}"
    # Encerra processos do app em execução (por PID; padrão não casa este script)
    for p in $(ps -eo pid,cmd | grep -F '/src/app.py' | grep -v grep | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    # Units: parar, desabilitar, remover
    for u in "${units[@]}"; do
        name="$(basename "$u")"
        systemctl stop "$name" 2>/dev/null || true
        systemctl disable "$name" 2>/dev/null || true
        rm -f "$u"
    done
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true
    # Arquivos e diretórios
    for f in "${files[@]}"; do rm -f "$f" 2>/dev/null || true; done
    for d in "${dirs[@]}"; do rm -rf "$d" 2>/dev/null || true; done
    # nginx: recarrega se a config seguir válida
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    fi
    echo -e "${GREEN}✅ Versões antigas removidas. Prosseguindo com instalação limpa.${NC}"
}

detect_and_purge_old

# ========== ATUALIZAR SISTEMA ==========
echo -e "${BLUE}[2/12]${NC} Atualizando sistema..."
apt update
apt upgrade -y

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
        echo -e "${YELLOW}⚠️  Fonte e destino são o mesmo diretório; pulando cópia de arquivos.${NC}"
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
        if [ -f "$REPO_DIR/requirements.txt" ]; then
            cp "$REPO_DIR/requirements.txt" "$INSTALL_DIR/"
        elif [ -f "$SRC_DIR/requirements.txt" ]; then
            cp "$SRC_DIR/requirements.txt" "$INSTALL_DIR/"
        fi
    fi

    if [ -f "$REPO_DIR/update_app.sh" ]; then
        cp "$REPO_DIR/update_app.sh" "$INSTALL_DIR/"
    elif [ -f "$SRC_DIR/update_app.sh" ]; then
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

# Executar aplicação (app.py fica em src/)
exec python src/app.py
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
# Wrappers privilegiados (executados como root)
administrador ALL=(root) NOPASSWD: /usr/local/bin/pi-manager-nmcli, /usr/local/bin/pi-manager-chpasswd, /usr/local/bin/pi-manager-hostname
# Operações que exigem root de fato (reboot/shutdown e matar processos do Chromium)
administrador ALL=(root) NOPASSWD: /sbin/shutdown, /usr/sbin/shutdown, /usr/bin/pkill
# Operações executadas COMO o próprio usuário administrador (sem escalonamento de privilégio):
# o serviço já roda como administrador, então estes 'sudo -u administrador ...' não elevam permissão.
administrador ALL=(administrador) NOPASSWD: /usr/bin/env, /usr/bin/rm, /usr/bin/find, /usr/bin/chromium, /usr/bin/chromium-browser, /usr/bin/xdpyinfo
EOF
chown root:root /etc/sudoers.d/pi-manager
chmod 440 /etc/sudoers.d/pi-manager

# Validar o arquivo sudoers criado
if ! visudo -cf /etc/sudoers.d/pi-manager >/dev/null 2>&1; then
    echo -e "${RED}❌ Erro: o arquivo /etc/sudoers.d/pi-manager contém erros${NC}"
    exit 1
fi

# ========== HARDENING DO WIFI: GERÊNCIA SÓ PELO SERVIÇO (POLKIT) ==========
echo -e "${BLUE}[--]${NC} Restringindo o gerenciamento do WiFi/NetworkManager ao serviço..."
# Regra polkit: apenas root (o serviço, via wrapper 'sudo nmcli') pode gerenciar o
# NetworkManager. Qualquer outro usuário (sessão gráfica, terminal não-root) é
# NEGADO. O app continua funcionando porque o wrapper roda nmcli como root.
cat > /etc/polkit-1/rules.d/49-pi-manager-nm.rules << 'EOF'
// raspberry-pi-manager: WiFi/rede gerenciáveis APENAS pelo serviço (root).
// Nega ações do NetworkManager para usuários não-root (sessão gráfica/terminal).
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0) {
        if (subject.user === "root") {
            return polkit.Result.YES;
        }
        return polkit.Result.NO;
    }
});
EOF
chown root:root /etc/polkit-1/rules.d/49-pi-manager-nm.rules
chmod 644 /etc/polkit-1/rules.d/49-pi-manager-nm.rules
# O polkit recarrega rules.d automaticamente; um restart garante aplicação imediata.
systemctl restart polkit 2>/dev/null || true
echo "✅ Gerenciamento de rede restrito ao serviço (regra polkit aplicada)."

# ========== CRIAR ARQUIVO DE AMBIENTE ==========
echo -e "${BLUE}[11/12]${NC} Criando arquivo de variáveis de ambiente..."
ENV_FILE="/etc/default/${SERVICE_NAME}"
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" << 'ENVEOF'
# Variáveis de ambiente para raspberry-pi-manager
# Edite este arquivo e reinicie o serviço: sudo systemctl restart raspberry-pi-manager

# Chave de assinatura das sessões Flask (RECOMENDADO definir).
# Gere com: openssl rand -hex 32
# Se vazio, o app gera/persiste automaticamente em ~/.config/raspberry-pi-manager/secret_key
SECRET_KEY=

# Senha de acesso à interface web (login). Padrão do app: 'sil123'.
# (NÃO confundir com a senha do usuário do sistema 'administrador', que é 'raspberry'.)
ADMIN_PASSWORD=sil123

# Nome do serviço systemd
SERVICE_NAME=raspberry-pi-manager

# Outras variáveis opcionais
#DEBUG=false
#FLASK_HOST=0.0.0.0
#FLASK_PORT=5000
ENVEOF
    chown root:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "✅ Criado $ENV_FILE"
else
    echo "ℹ️  $ENV_FILE já existe; preservando."
fi

# ========== CONFIGURAR SERVIÇO SYSTEMD ==========
[ -n "$SERVICE_NAME" ] || SERVICE_NAME="${SERVICE_NAME}"
echo -e "${BLUE}[11.5/12]${NC} Configurando serviço systemd..."
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
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/src/app.py
# Ao parar o serviço (inclusive durante desligamento/reinício do sistema),
# encerra o kiosk do Chromium de forma limpa: SIGTERM e, se persistir, SIGKILL.
# Evita o aviso "o Chrome não foi encerrado corretamente" no próximo boot.
ExecStop=-/bin/bash -c 'pkill -TERM -f chromium 2>/dev/null; sleep 2; pkill -KILL -f chromium 2>/dev/null; true'
TimeoutStopSec=15
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Segurança / sandboxing
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=$INSTALL_DIR /home/administrador/chromium-profile /home/administrador/.config/raspberry-pi-manager
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Ambiente mínimo
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service || true

# ========== CONFIGURAR NGINX (HTTPS / PROXY REVERSO) ==========
echo -e "${BLUE}[11.7/12]${NC} Configurando nginx com HTTPS (certificado autoassinado)..."

# 1. Gera certificado autoassinado (válido por 10 anos) se ainda não existir.
SSL_CERT=/etc/ssl/certs/pi-manager.crt
SSL_KEY=/etc/ssl/private/pi-manager.key
if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -days 3650 \
        -subj "/CN=raspberry-pi-manager" >/dev/null 2>&1
    chmod 600 "$SSL_KEY"
    echo "✅ Certificado autoassinado gerado em $SSL_CERT"
else
    echo "ℹ️  Certificado já existe; preservando."
fi

# 2. Escreve o site do nginx: redireciona HTTP->HTTPS e faz proxy reverso para o Flask.
cat > /etc/nginx/sites-available/${SERVICE_NAME} << EOF
# Redireciona todo HTTP (porta 80) para HTTPS (porta 443)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

# HTTPS: termina o TLS e repassa para o Flask em 127.0.0.1:5000
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate     $SSL_CERT;
    ssl_certificate_key $SSL_KEY;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 3. Ativa o site e desativa o default do nginx
ln -sf /etc/nginx/sites-available/${SERVICE_NAME} /etc/nginx/sites-enabled/${SERVICE_NAME}
rm -f /etc/nginx/sites-enabled/default

# 4. Testa a configuração e reinicia o nginx
if nginx -t >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    echo "✅ nginx configurado: acesse via https://<ip-do-pi>"
else
    echo -e "${RED}❌ Configuração do nginx inválida; verifique com 'sudo nginx -t'${NC}"
fi

# ========== CONFIGURAR ATUALIZAÇÃO AUTOMÁTICA SEMANAL (PULL) ==========
echo -e "${BLUE}[11.8/12]${NC} Configurando verificador semanal de atualizações..."

# Serviço oneshot que roda o atualizador (como root)
cat > /etc/systemd/system/${SERVICE_NAME}-update.service << EOF
[Unit]
Description=Verifica e aplica atualizações do raspberry-pi-manager
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Roda como root: reinicia o serviço sem sudo. git/pip rodam como o dono do repo.
Environment="SERVICE_NAME=${SERVICE_NAME}"
Environment="INSTALL_DIR=${INSTALL_DIR}"
Environment="RUN_USER=administrador"
ExecStart=/usr/local/bin/update_app.sh
EOF

# Timer: 1x por semana, em dia/horário aleatório (re-sorteado a cada semana)
cat > /etc/systemd/system/${SERVICE_NAME}-update.timer << 'EOF'
[Unit]
Description=Dispara a verificação de atualização 1x por semana, em dia/horário aleatório

[Timer]
# Base semanal + atraso aleatório de até 7 dias => cai num dia aleatório da semana.
OnCalendar=weekly
RandomizedDelaySec=7d
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
if systemctl enable --now ${SERVICE_NAME}-update.timer >/dev/null 2>&1; then
    echo "✅ Verificador semanal ativado."
    echo "   Veja o próximo disparo com: systemctl list-timers '${SERVICE_NAME}-update*'"
    echo "   Force uma verificação agora com: sudo systemctl start ${SERVICE_NAME}-update.service"
else
    echo -e "${YELLOW}⚠️  Não foi possível ativar o timer de atualização.${NC}"
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

# Detecta binário do Chromium
if [ -x "/usr/bin/chromium" ]; then
    CHROMIUM_BIN="/usr/bin/chromium"
elif [ -x "/usr/bin/chromium-browser" ]; then
    CHROMIUM_BIN="/usr/bin/chromium-browser"
else
    CHROMIUM_BIN="chromium"
fi

DESKTOP_FILE_CONTENT="[Desktop Entry]\nName=Chromium-Raspberry\nComment=Chromium custom profile for Raspberry PI Manager\nExec=$CHROMIUM_BIN --user-data-dir=/home/administrador/chromium-profile --no-first-run --start-maximized --ignore-certificate-errors --noerrdialogs --disable-session-crashed-bubble %U\nTerminal=false\nType=Application\nCategories=Network;WebBrowser;\nStartupNotify=false\n"

echo -e "$DESKTOP_FILE_CONTENT" > "$USER_DESKTOP_DIR/Chromium-Raspberry.desktop"
echo -e "[Desktop Entry]\nName=Chromium-Raspberry\nComment=Autostart Chromium custom profile for Raspberry PI Manager\nExec=$CHROMIUM_BIN --user-data-dir=/home/administrador/chromium-profile --no-first-run --start-maximized --ignore-certificate-errors --noerrdialogs --disable-session-crashed-bubble\nTerminal=false\nType=Application\nX-GNOME-Autostart-enabled=true\nStartupNotify=false\n" > "$USER_AUTOSTART_DIR/Chromium-Raspberry.desktop"

chown administrador:administrador "$USER_DESKTOP_DIR/Chromium-Raspberry.desktop" || true
chown administrador:administrador "$USER_AUTOSTART_DIR/Chromium-Raspberry.desktop" || true
chmod 755 "$USER_DESKTOP_DIR/Chromium-Raspberry.desktop" || true
chmod 644 "$USER_AUTOSTART_DIR/Chromium-Raspberry.desktop" || true

# ========== POLÍTICA DO WIFI ==========
# Padrão (recomendado): MANTÉM a conexão WiFi atual (a rede em que o Pi subiu
# acessando) e apenas BLOQUEIA o GERENCIAMENTO por não-root (regra polkit acima).
# Ou seja: ninguém desconecta nem troca de rede pelo ícone do sistema; só o app
# (root) gerencia. O acesso à rede atual permanece normal.
#
# Opcional: PI_MANAGER_WIFI_DEFAULT=blocked desliga o rádio por padrão (com trava
# de segurança se o WiFi for o único acesso). Use só se quiser o Pi sem WiFi até
# liberar pelo app.
echo -e "${BLUE}[--]${NC} Definindo política do WiFi..."
WIFI_DEFAULT="${PI_MANAGER_WIFI_DEFAULT:-keep}"
if [ "$WIFI_DEFAULT" = "blocked" ]; then
    eth_up=false; wifi_up=false
    nmcli -t -f TYPE,STATE device status 2>/dev/null | grep -q '^ethernet:connected' && eth_up=true
    nmcli -t -f TYPE,STATE device status 2>/dev/null | grep -q '^wifi:connected' && wifi_up=true
    if [ "$wifi_up" = true ] && [ "$eth_up" != true ] && [ "${PI_MANAGER_WIFI_FORCE:-no}" != "yes" ]; then
        echo -e "${YELLOW}⚠️  WiFi é o ÚNICO acesso ativo; NÃO vou desligar (evita perder a conexão).${NC}"
        echo -e "${YELLOW}    Conecte um cabo e desligue pelo app, ou rode com PI_MANAGER_WIFI_FORCE=yes.${NC}"
    else
        nmcli radio wifi off 2>/dev/null || true
        echo -e "${GREEN}✅ Rádio WiFi desligado por padrão — ligue pelo app (tela Rede).${NC}"
    fi
else
    echo -e "${GREEN}✅ WiFi mantém a conexão atual; gerenciamento bloqueado para não-root.${NC}"
    echo -e "${GREEN}   Ninguém desconecta nem troca de rede pelo sistema — só o app gerencia.${NC}"
fi

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
echo -e "  • Acesse https://$IP_ADDRESS para usar o gerenciador (aceite o aviso do certificado autoassinado)"
echo -e "  • Configure as URLs em: $INSTALL_DIR/config/autostart.conf"
echo -e "  • Login web: usuário 'administrador' / senha 'sil123' (senha do sistema é 'raspberry')"
echo -e "  • ALTERE A SENHA PADRÃO após o primeiro login!"
echo -e "  • AUTO-UPDATE: cada Pi verifica o GitHub 1x por semana automaticamente"
echo -e "    Ver: systemctl list-timers '${SERVICE_NAME}-update*'"
echo ""

echo -e "${BLUE}🔄 Iniciando o serviço...${NC}"
systemctl start ${SERVICE_NAME}.service || true
sleep 3

# Verificar se o serviço está rodando
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}✅ Serviço iniciado com sucesso!${NC}"
    
    # Testar se a API responde
    echo -e "${BLUE}🧪 Testando API...${NC}"
    sleep 2
    if curl -s http://localhost:5000 > /dev/null; then
        echo -e "${GREEN}✅ API respondendo corretamente!${NC}"
    else
        echo -e "${YELLOW}⚠️ API não respondeu. Verifique os logs.${NC}"
    fi
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

