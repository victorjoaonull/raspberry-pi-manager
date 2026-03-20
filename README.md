# Raspberry Pi Manager

Um gerenciador web completo para Raspberry Pi com controle de rede, sistema, autostart e sincronização de favoritos do Chromium.

## Características

- **Dashboard**: Monitoramento de status do sistema, CPU, memória e temperatura em tempo real
- **Rede**: Gerenciamento de conexões Ethernet e Wi-Fi via NetworkManager
- **Sistema**: Alteração de hostname, senha, reinicialização e desligamento
- **Autostart**: Configuração de URLs para abrir automaticamente no Chromium
- **Webhook**: Atualizações automáticas via GitHub Actions
- **Interface Responsiva**: Design limpo e profissional com logo e background

---

## Requisitos

- **Hardware**: Raspberry Pi 4 ou 5 com pelo menos 2GB RAM
- **SO**: Raspberry Pi OS (Bookworm recomendado) ou qualquer Linux com systemd
- **Conexão**: Internet para clonar repositório e receber atualizações
- **Acesso**: SSH ou teclado/mouse conectados ao Pi

---

## Instalação Rápida

### 1. Acesse o Raspberry Pi via SSH

```bash
ssh administrador@seu-pi.local
# ou use o IP: ssh administrador@192.168.1.100
```

### 2. Clone o repositório

```bash
git clone https://github.com/victorjoaonull/raspberry-pi-manager.git
cd raspberry-pi-manager
```

### 3. Execute o instalador

```bash
chmod +x install.sh
sudo ./install.sh
```

O script irá:
- ✅ Remover instalações antigas
- ✅ Criar usuário `administrador` (se não existir)
- ✅ Instalar dependências do sistema
- ✅ Configurar ambiente Python com venv
- ✅ Instalar o serviço systemd
- ✅ Configurar auto-login gráfico
- ✅ Instalar e configurar Chromium
- ✅ Criar atalho **Chromium-Raspberry.desktop** na área de trabalho (`xdg-user-dir DESKTOP`): mesmo perfil `/home/administrador/chromium-profile` e mesmas flags base que o autostart do serviço (marcado como confiável para duplo clique quando `gio` estiver disponível)
- ✅ Criar script de atualização automática

### 4. Acesse a aplicação

Abra seu navegador e acesse:

```
http://seu-pi.local:5000
ou
http://192.168.1.100:5000
```

**Credenciais padrão:**
- Usuário: `administrador`
- Senha: `raspberry`

⚠️ **ALTERE A SENHA IMEDIATAMENTE APÓS O PRIMEIRO LOGIN**

### Desinstalar

No repositório ou em `/home/administrador/raspberry-pi-manager` (após copiar o script pelo instalador):

```bash
chmod +x uninstall.sh
sudo ./uninstall.sh              # confirmações interativas
sudo ./uninstall.sh -y           # remove serviço, wrappers, sudoers e a pasta da app
sudo ./uninstall.sh -y --purge   # também remove /etc/default/raspberry-pi-manager
sudo ./uninstall.sh -y --keep-app-dir   # só remove integração (systemd, /usr/local/bin, sudoers)
```

O desinstalador **não** remove pacotes `apt`, auto-login do Lightdm nem o perfil `~/chromium-profile`. Use `./uninstall.sh --help` para todas as opções.

---

## Configuração Pós-Instalação

### 1. Alterar a Senha

No dashboard, acesse **Sistema** → **Senha** e defina uma nova senha segura.

### 2. Configurar URLs de Autostart

Acesse **Autostart** e adicione as URLs que deseja abrir automaticamente quando o Pi iniciar. Exemplos:

- `http://localhost:5000` — Seu gerenciador
- `http://seu-servidor:3000` — Seu app
- `https://www.google.com` — Google

### 3. Configurar Rede

Acesse **Rede** para:
- Conectar a Wi-Fi
- Configurar IP estático
- Visualizar informações de conexão

### 4. Alterar Hostname (opcional)

Acesse **Sistema** → **Hostname** para mudar o nome do seu Raspberry Pi (ex: `pi-tv`, `pi-servidor`).

---

## Atualizações Automáticas via Webhook (Opcional)

Se quiser que o Pi receba atualizações automaticamente quando você fizer push para GitHub:

### 1. Configure o Webhook Secret

```bash
sudo nano /etc/default/raspberry-pi-manager
```

Procure pela linha `WEBHOOK_SECRET=` e adicione o seu secret:

```bash
WEBHOOK_SECRET=602d5122f688294d2155c7766df73588cd25c6333f056acc58e9f10c425dd17a
SERVICE_NAME=raspberry-pi-manager
```

Salve (Ctrl+O, Enter, Ctrl+X) e reinicie o serviço:

```bash
sudo systemctl restart raspberry-pi-manager
```

### 2. Configure GitHub Actions

Adicione este secret ao seu repositório GitHub:

1. Vá para **Settings** → **Secrets and variables** → **Actions**
2. Clique em **New repository secret**
3. Nome: `WEBHOOK_SECRET`
4. Valor: Cole o mesmo secret do passo 1

### 3. Ative o Workflow de Deploy

O arquivo `.github/workflows/deploy.yml` já está configurado. A cada push para `main`, o Pi receberá a atualização automaticamente.

---

## Usando o Gerenciador

### Dashboard

Visualize status em tempo real:
- Temperatura do processador
- Uso de CPU
- Uso de memória
- Status de rede
- Últimos eventos do sistema

### Rede

- Criar/editar conexões Ethernet e Wi-Fi
- Alternar entre DHCP e IP estático
- Visualizar informações de conexão
- Copiar IPs facilmente

### Sistema

- Alterar hostname
- Alterar senha
- Visualizar informações do sistema
- Reiniciar ou desligar o Pi
- Sincronizar favoritos do navegador
- Limpar locks do Chromium

### Autostart

- Gerenciar URLs que abrem automaticamente
- Reorganizar ordem (drag & drop)
- Validar URLs antes de salvar
- Testar URLs abrindo-as
- Sincronizar com favoritos do Chromium

---

## Troubleshooting

### Erro: "Este script deve ser executado em um Raspberry Pi"

- Verifique se está rodando em um Raspberry Pi original
- Tente comentar a verificação em `install.sh` (linha 28) se estiver em emulador

### Erro: "Permission denied" ao fazer push

- Configure chave SSH: `ssh-keygen -t ed25519`
- Adicione a chave ao GitHub: https://github.com/settings/keys
- Teste: `ssh -T git@github.com`

### Serviço não inicia

Verifique os logs:

```bash
sudo journalctl -u raspberry-pi-manager -f
```

Possíveis problemas:
- Variáveis de ambiente não definidas → edite `/etc/default/raspberry-pi-manager`
- Permissões incorretas → `sudo chown -R administrador:administrador /home/administrador/raspberry-pi-manager`
- Porta 5000 em uso → mude em `src/app.py` e `systemd/raspberry-pi-manager.service`

### Webhook não funciona

1. Verifique se `WEBHOOK_SECRET` está configurado:
   ```bash
   cat /etc/default/raspberry-pi-manager | grep WEBHOOK_SECRET
   ```

2. Teste a assinatura manualmente:
   ```bash
   BODY='{"event":"deploy"}'
   SECRET="seu-secret-aqui"
   SIGNATURE=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)
   curl -v -X POST http://localhost:5000/webhook \
     -H "X-Hub-Signature-256: sha256=$SIGNATURE" \
     -H "Content-Type: application/json" \
     -d "$BODY"
   ```

3. Verifique os logs do webhook em `update_app.log`:
   ```bash
   tail -f /home/administrador/raspberry-pi-manager/update_app.log
   ```

### Login: "PAM nao disponivel" ou acentos quebrados (MÃ³dulo / usuÃ¡rio)

**PAM**

1. No Pi (SSH), rode o script de correção (instalador copia para a pasta da app):
   ```bash
   sudo bash /home/administrador/raspberry-pi-manager/scripts/fix-pam-on-pi.sh
   ```
   Ou manualmente:
   ```bash
   sudo apt install -y python3-pam
   sudo -u administrador /home/administrador/raspberry-pi-manager/venv/bin/pip uninstall -y python-pam
   sudo systemctl restart raspberry-pi-manager
   ```
2. Confira o erro real: `journalctl -u raspberry-pi-manager -b -n 40 --no-pager`
3. O venv deve ter sido criado com `--system-site-packages` (o `install.sh` já faz isso).

**Acentos (charset)**

- Acesse direto `http://IP:5000` (sem proxy) ou configure nginx com `charset utf-8;`.
- Atualize a página com Ctrl+F5. A aplicação força `Content-Type: ... charset=utf-8`.

### Chromium não abre automaticamente

O Chromium com **URLs de `config/autostart.conf`** é aberto **uma vez** pelo serviço `raspberry-pi-manager` (thread em `startup_tasks` → `open_browser_with_urls`). Não use um segundo `.desktop` em `~/.config/autostart/` para o mesmo perfil (`chromium-profile`), senão há risco de SingletonLock / duas aberturas.

- Aguarde ~15–20 s após o boot (atraso interno para X11 e display `:0`).
- Verifique o serviço: `sudo systemctl status raspberry-pi-manager`
- Log de lançamento: `tail -f /home/administrador/pi-manager/logs/browser-launch.log`
- Display: `sudo -u administrador env DISPLAY=:0 xdpyinfo`
- Reinício gráfico se necessário: `sudo systemctl restart lightdm`

---

## Comandos Úteis

```bash
# Ver status do serviço
sudo systemctl status raspberry-pi-manager

# Ver logs em tempo real
sudo journalctl -u raspberry-pi-manager -f

# Reiniciar serviço
sudo systemctl restart raspberry-pi-manager

# Parar serviço
sudo systemctl stop raspberry-pi-manager

# Iniciar serviço
sudo systemctl start raspberry-pi-manager

# Executar atualização manual (instala python3-pam, pip no venv, git pull, reinicia o serviço)
sudo /usr/local/bin/update_app.sh

# Ver logs de atualização
tail -f /home/administrador/raspberry-pi-manager/update_app.log
```

---

## Estrutura do Projeto

```
raspberry-pi-manager/
├── src/
│   ├── app.py                 # Aplicação Flask principal
│   ├── config/                # Arquivos de configuração
│   ├── static/                # CSS, imagens, JavaScript
│   │   └── imgs/
│   │       ├── logo.png
│   │       └── background.jpg
│   └── templates/             # Templates HTML
│       ├── index.html         # Dashboard
│       ├── network.html       # Configuração de rede
│       ├── system.html        # Sistema
│       ├── autostart.html     # Autostart
│       ├── about.html         # Sobre
│       └── login.html         # Login
├── systemd/
│   ├── raspberry-pi-manager.service    # Unit file do systemd
│   └── raspberry-pi-manager.env.example # Exemplo de variáveis
├── install.sh                 # Script de instalação
├── uninstall.sh               # Desinstala serviço e integração no sistema
├── update_app.sh              # Script de atualização automática
├── requirements.txt           # Dependências Python
└── README.md                  # Este arquivo
```

---

## Variáveis de Ambiente

Edite `/etc/default/raspberry-pi-manager`:

| Variável | Descrição | Padrão |
|----------|-----------|--------|
| `WEBHOOK_SECRET` | Secret para validar webhooks do GitHub | (vazio) |
| `SERVICE_NAME` | Nome do serviço systemd | `raspberry-pi-manager` |
| `DEBUG` | Modo debug Flask | `false` |
| `FLASK_HOST` | Host para bind | `0.0.0.0` |
| `FLASK_PORT` | Porta da aplicação | `5000` |

---

## Desenvolvimento

Para modificar o código localmente:

```bash
# Clone o repositório
git clone https://github.com/victorjoaonull/raspberry-pi-manager.git
cd raspberry-pi-manager

# Crie um venv
python3 -m venv venv
source venv/bin/activate

# Instale dependências
pip install -r requirements.txt

# Rode localmente
python3 src/app.py
```

Acesse `http://localhost:5000` (sem autenticação em modo local).

---

## Segurança

- **Sempre altere a senha padrão**
- **Use HTTPS** em produção (configure nginx com Let's Encrypt)
- **Restrinja acesso de rede** com firewall se exposto à internet
- **Mantenha atualizado** via webhook ou manualmente
- **Backup de configurações** em `/home/administrador/raspberry-pi-manager/config/`

---

## Suporte e Contribuições

- GitHub: https://github.com/victorjoaonull/raspberry-pi-manager
- Issues: https://github.com/victorjoaonull/raspberry-pi-manager/issues
- Pull Requests: Bem-vindo!

---

## Licença

Este projeto é fornecido como está. Consulte o repositório para detalhes de licença.

---

## Créditos

Desenvolvido por **@victorjoaonull** — https://github.com/victorjoaonull

---

## Changelog

### v1.0.0 (12 de fevereiro de 2026)

- ✅ Interface web responsiva com dashboard
- ✅ Gerenciamento de rede (Ethernet/Wi-Fi)
- ✅ Gerenciamento de sistema (hostname/senha)
- ✅ Configuração de autostart com Chromium
- ✅ Suporte a webhook para atualizações automáticas
- ✅ Sincronização de favoritos do navegador
- ✅ Logo e background customizados
- ✅ Instalador automático para Raspberry Pi
