# Melhorias Implementadas no Script install.sh

## ✅ Melhorias Aplicadas

### 1. **Verificação de Conectividade de Rede**
   - Adicionado teste de conexão com retry automático (5 tentativas)
   - Testa conexão com servidores DNS públicos (8.8.8.8, 1.1.1.1)
   - Evita falhas silenciosas ao executar `apt` sem rede

### 2. **Retry Logic para apt update/upgrade**
   - `apt update` e `apt upgrade` agora têm retry automático (3 tentativas)
   - Aguarda 10 segundos entre tentativas
   - Falha explícita após 3 tentativas

### 3. **Caminho Absoluto do app.py**
   - Corrigido: `python app.py` → `python "$INSTALL_DIR/app.py"`
   - Evita erro de módulo não encontrado quando executado de outro diretório

### 4. **Detecção Melhorada do Chromium**
   - Busca em múltiplos binários: `chromium`, `chromium-browser`, `google-chrome`, `google-chrome-stable`
   - Usa `command -v` em vez de verificar caminhos específicos
   - Mais compatível com diferentes distribuições

### 5. **Validação de Serviço systemd**
   - Verifica se o serviço anterior está rodando antes de reinstalar
   - Para o serviço anterior com delay de 2 segundos
   - Valida que a habilitação do serviço funcionou

### 6. **Teste de API Sem curl**
   - Substituído `curl` por teste TCP nativo com `/dev/tcp`
   - Não depende de `curl` estar instalado
   - Mais robusto em ambientes minimalistas

### 7. **Testes de Permissões Sudoers**
   - Testa se as permissões sudo foram aplicadas corretamente
   - Valida usando a própria command sudo
   - Fornece feedback claro sobre o status

### 8. **Remoção Segura de Instalações Antigas**
   - Melhor logging durante remoção de diretórios
   - Tratamento individual de erros em remoções
   - Avisos em vez de falhas silenciosas

### 9. **Delay Entre Operações**
   - Adicionado sleep de 2 segundos antes de `systemctl start`
   - Garante que `daemon-reload` foi processado
   - Evita race conditions

## 🔍 Recomendações Adicionais Não Implementadas

### 1. **Validação de Entrada**
```bash
# Validar INSTALL_DIR
if [[ ! "$INSTALL_DIR" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
    echo "INSTALL_DIR inválido"
    exit 1
fi
```

### 2. **Logging Centralizado**
```bash
LOG_DIR="/var/log/pi-manager-install"
LOG_FILE="$LOG_DIR/install-$(date +%s).log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE")
exec 2>&1
```

### 3. **Backup de Configurações Existentes**
```bash
if [ -f "$INSTALL_DIR/config/autostart.conf" ]; then
    cp "$INSTALL_DIR/config/autostart.conf" \
       "$INSTALL_DIR/config/autostart.conf.backup.$(date +%s)"
fi
```

### 4. **Verificação de Espaço em Disco**
```bash
AVAILABLE_SPACE=$(df "$INSTALL_DIR" | awk 'NR==2 {print $4}')
if [ "$AVAILABLE_SPACE" -lt 524288 ]; then  # 512MB
    echo "Espaço insuficiente (mínimo 512MB)"
    exit 1
fi
```

### 5. **Hash de Integridade para Arquivos Críticos**
```bash
# Verificar se arquivos foram corrompidos
sha256sum -c checksum.txt || {
    echo "Arquivos corrompidos"
    exit 1
}
```

### 6. **Detecção de Arquivo de Travamento**
```bash
LOCK_FILE="/var/run/pi-manager-install.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "Instalação já em progresso ou anterior foi interrompida"
    exit 1
fi
touch "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT
```

### 7. **Rollback Automático em Caso de Erro**
```bash
# Criar snapshot do estado antes de começar
mkdir -p "$INSTALL_DIR.backup"
cp -a "$INSTALL_DIR"/* "$INSTALL_DIR.backup/" 2>/dev/null || true

# Em caso de erro:
trap "restore_backup" ERR
restore_backup() {
    echo "Restaurando backup..."
    rm -rf "$INSTALL_DIR"/*
    cp -a "$INSTALL_DIR.backup"/* "$INSTALL_DIR/"
}
```

### 8. **Validação de Integração Completa**
```bash
# Teste completo após instalação
test_installation() {
    echo "Testando instalação..."
    
    # Testar Python
    if ! "$VENV_DIR/bin/python" -c "import flask" 2>/dev/null; then
        echo "Flask não está instalado"
        return 1
    fi
    
    # Testar arquivo app.py
    if ! [ -f "$INSTALL_DIR/app.py" ]; then
        echo "app.py não encontrado"
        return 1
    fi
    
    # Testar serviço
    if ! systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
        echo "Serviço não está habilitado"
        return 1
    fi
    
    return 0
}
```

### 9. **Suporte a Múltiplos Usuários**
```bash
# Permitir especificar usuário via variável
APP_USER="${APP_USER:-administrador}"

# Usar variável em todo o script
chown -R "$APP_USER:$APP_USER" "$INSTALL_DIR"
sudo -u "$APP_USER" python3 -m venv "$VENV_DIR"
```

### 10. **Suporte a Dry-run (Preview)**
```bash
DRY_RUN="${DRY_RUN:-false}"

run_cmd() {
    local cmd="$1"
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] $cmd"
    else
        eval "$cmd"
    fi
}

# Usar assim:
# run_cmd "systemctl start $SERVICE_NAME"
```

## 📋 Como Usar as Recomendações

Para implementar uma recomendação, adicione a função no início do script e use em todo o código:

```bash
# No topo do script, após as definições de cores
source /tmp/pi-manager-functions.sh

# Ou defina inline antes de use
```

## 🧪 Testando o Script

### Teste Local (sem instalar)
```bash
# Verificar sintaxe
bash -n ./install.sh

# Dry-run (simulado)
DRY_RUN=true bash ./install.sh
```

### Teste em VM ou Raspberry Pi
```bash
# Primeira execução
sudo ./install.sh

# Reinstalação (testa idempotência)
sudo ./install.sh
```

### Teste de Recuperação
```bash
# Parar serviço
sudo systemctl stop raspberry-pi-manager

# Rodar instalação novamente
sudo ./install.sh

# Verificar se recuperou
sudo systemctl status raspberry-pi-manager
```

## ✨ Resumo das Mudanças

| Problema | Solução | Status |
|----------|---------|--------|
| Sem validação de rede | Retry com ping | ✅ |
| `apt` falha silenciosamente | Retry automático | ✅ |
| app.py não encontrado | Caminho absoluto | ✅ |
| Chromium não encontrado | Múltiplas buscas | ✅ |
| Serviço anterior interfere | Para antes de reinstalar | ✅ |
| `curl` pode não estar instalado | Usa `/dev/tcp` | ✅ |
| Sudoers sem validação | Testa permissões | ✅ |
| Instalador pode ser removido | Melhor verificação de caminho | ✅ |
| Sem logging centralizado | Recomendações no documento | 📋 |
| Sem rollback | Recomendações no documento | 📋 |

