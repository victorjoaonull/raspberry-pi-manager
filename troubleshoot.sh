#!/bin/bash

# =============================================
# SCRIPT DE DIAGNÓSTICO - Gerenciador Raspberry PI
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      DIAGNÓSTICO - Gerenciador Raspberry PI          ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

SERVICE_NAME="${SERVICE_NAME:-raspberry-pi-manager}"
INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"

echo -e "${BLUE}📋 Configurações:${NC}"
echo "  Serviço: $SERVICE_NAME"
echo "  Diretório: $INSTALL_DIR"
echo ""

# ========== VERIFICAR SE É ROOT ==========
if [ "$EUID" -ne 0 ]; then 
    echo -e "${YELLOW}⚠️  Executar com sudo para acesso completo${NC}"
    echo "    sudo $0"
    echo ""
fi

# ========== VERIFICAR PYTHON ==========
echo -e "${BLUE}1️⃣ Verificando Python...${NC}"
if [ -f "$INSTALL_DIR/venv/bin/python" ]; then
    echo -e "${GREEN}✅ Python encontrado${NC}"
    "$INSTALL_DIR/venv/bin/python" --version
else
    echo -e "${RED}❌ Python não encontrado em $INSTALL_DIR/venv/bin/python${NC}"
fi
echo ""

# ========== VERIFICAR APP.PY ==========
echo -e "${BLUE}2️⃣ Verificando app.py...${NC}"
if [ -f "$INSTALL_DIR/app.py" ]; then
    echo -e "${GREEN}✅ app.py encontrado${NC}"
    echo "  Tamanho: $(ls -lh $INSTALL_DIR/app.py | awk '{print $5}')"
    echo "  Permissões: $(ls -l $INSTALL_DIR/app.py | awk '{print $1}')"
else
    echo -e "${RED}❌ app.py não encontrado em $INSTALL_DIR${NC}"
fi
echo ""

# ========== VERIFICAR VENV ==========
echo -e "${BLUE}3️⃣ Verificando ambiente virtual...${NC}"
if [ -d "$INSTALL_DIR/venv" ]; then
    echo -e "${GREEN}✅ Diretório venv existe${NC}"
    if [ -f "$INSTALL_DIR/venv/pyvenv.cfg" ]; then
        echo "  Tipo: $(grep 'home' $INSTALL_DIR/venv/pyvenv.cfg)"
    fi
else
    echo -e "${RED}❌ Diretório venv não existe${NC}"
fi
echo ""

# ========== VERIFICAR ARQUIVO SERVICE ==========
echo -e "${BLUE}4️⃣ Verificando arquivo de serviço...${NC}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
if [ -f "$SERVICE_FILE" ]; then
    echo -e "${GREEN}✅ Arquivo de serviço encontrado${NC}"
    echo "  Caminho: $SERVICE_FILE"
    echo ""
    echo -e "${BLUE}📄 Conteúdo:${NC}"
    cat "$SERVICE_FILE"
else
    echo -e "${RED}❌ Arquivo de serviço não encontrado${NC}"
fi
echo ""

# ========== VALIDAR SERVICE FILE ==========
echo -e "${BLUE}5️⃣ Validando arquivo de serviço...${NC}"
if command -v systemd-analyze >/dev/null 2>&1; then
    if systemd-analyze verify "$SERVICE_FILE" 2>&1 | grep -q "No errors"; then
        echo -e "${GREEN}✅ Arquivo válido${NC}"
    else
        echo -e "${RED}❌ Erros encontrados:${NC}"
        systemd-analyze verify "$SERVICE_FILE" || true
    fi
else
    echo -e "${YELLOW}⚠️  systemd-analyze não disponível${NC}"
fi
echo ""

# ========== VERIFICAR STATUS DO SERVIÇO ==========
echo -e "${BLUE}6️⃣ Status do serviço...${NC}"
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${GREEN}✅ Serviço está rodando${NC}"
else
    echo -e "${RED}❌ Serviço NÃO está rodando${NC}"
fi
echo ""

STATUS=$(systemctl status "$SERVICE_NAME" 2>&1)
echo "$STATUS"
echo ""

# ========== VERIFICAR PORTA 5000 ==========
echo -e "${BLUE}7️⃣ Verificando porta 5000...${NC}"
if command -v ss >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ":5000"; then
        echo -e "${GREEN}✅ Porta 5000 está escutando${NC}"
        ss -tlnp 2>/dev/null | grep ":5000"
    else
        echo -e "${YELLOW}⚠️  Nada escutando na porta 5000${NC}"
    fi
elif command -v netstat >/dev/null 2>&1; then
    if netstat -tlnp 2>/dev/null | grep -q ":5000"; then
        echo -e "${GREEN}✅ Porta 5000 está escutando${NC}"
        netstat -tlnp 2>/dev/null | grep ":5000"
    else
        echo -e "${YELLOW}⚠️  Nada escutando na porta 5000${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  ss/netstat não disponível${NC}"
fi
echo ""

# ========== TESTAR CONEXÃO ==========
echo -e "${BLUE}8️⃣ Testando conexão na porta 5000...${NC}"
if timeout 2 bash -c "</dev/tcp/localhost/5000" 2>/dev/null; then
    echo -e "${GREEN}✅ Conexão bem-sucedida${NC}"
else
    echo -e "${YELLOW}⚠️  Não foi possível conectar${NC}"
fi
echo ""

# ========== VERIFICAR PERMISSÕES ==========
echo -e "${BLUE}9️⃣ Verificando permissões...${NC}"
echo "Diretório de instalação:"
ls -ld "$INSTALL_DIR"
echo ""
echo "Executáveis Python:"
ls -l "$INSTALL_DIR/venv/bin/python" 2>/dev/null || echo "  ❌ Não encontrado"
echo ""
echo "app.py:"
ls -l "$INSTALL_DIR/app.py" 2>/dev/null || echo "  ❌ Não encontrado"
echo ""

# ========== VERIFICAR LOGS ==========
echo -e "${BLUE}🔟 Últimos logs (últimas 50 linhas)...${NC}"
echo "journalctl:"
journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null || echo "  ❌ Erro ao ler logs"
echo ""

# ========== TESTAR PYTHON MANUALMENTE ==========
echo -e "${BLUE}1️⃣1️⃣ Teste manual de Python...${NC}"
echo "Testando se venv está funcional:"
if [ -x "$INSTALL_DIR/venv/bin/python" ]; then
    echo -e "${BLUE}Executando:${NC} $INSTALL_DIR/venv/bin/python --version"
    "$INSTALL_DIR/venv/bin/python" --version 2>&1 || echo "  ❌ Erro ao executar"
    echo ""
    echo -e "${BLUE}Tentando importar flask:${NC}"
    "$INSTALL_DIR/venv/bin/python" -c "import flask; print(f'Flask {flask.__version__}')" 2>&1 || echo "  ❌ Flask não instalado"
else
    echo -e "${RED}❌ Python não é executável${NC}"
fi
echo ""

# ========== RESUMO DE RECOMENDAÇÕES ==========
echo -e "${BLUE}💡 Recomendações:${NC}"
echo ""

if ! [ -f "$INSTALL_DIR/app.py" ]; then
    echo -e "${RED}1. app.py não encontrado:${NC}"
    echo "   Verificar se a instalação foi concluída corretamente"
    echo "   sudo $0"
    echo ""
fi

if systemctl is-masked --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo -e "${RED}2. Serviço MASCARADO (não pode iniciar):${NC}"
    echo "   sudo systemctl unmask ${SERVICE_NAME}.service"
    echo "   sudo systemctl enable --now ${SERVICE_NAME}.service"
    echo ""
elif ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${RED}2. Serviço não está rodando:${NC}"
    echo "   Iniciar manualmente:"
    echo "   sudo systemctl start $SERVICE_NAME"
    echo "   Se disser 'masked': sudo systemctl unmask $SERVICE_NAME"
    echo "   Verificar logs:"
    echo "   sudo journalctl -u $SERVICE_NAME -f"
    echo ""
fi

echo -e "${BLUE}📞 Comandos úteis:${NC}"
echo "  Restart serviço: sudo systemctl restart $SERVICE_NAME"
echo "  Ver logs ao vivo: sudo journalctl -u $SERVICE_NAME -f"
echo "  Status: sudo systemctl status $SERVICE_NAME"
echo "  Resetar serviço: sudo systemctl reset-failed $SERVICE_NAME"
echo ""

echo -e "${GREEN}✨ Diagnóstico concluído!${NC}"
