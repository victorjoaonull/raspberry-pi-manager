# Raspberry Pi Manager

Um gerenciador web completo para Raspberry Pi com controle de rede, sistema, autostart e sincronização de favoritos do Chromium.

## Características

- **Dashboard**: Monitoramento de status do sistema, CPU, memória e temperatura em tempo real
- **Rede**: Gerenciamento de conexões Ethernet e Wi-Fi via NetworkManager
- **Sistema**: Alteração de hostname, senha, reinicialização e desligamento
- **Autostart**: Configuração de URLs para abrir automaticamente no Chromium
- **Atualização automática**: cada Pi verifica o GitHub 1× por semana (dia aleatório) e se atualiza sozinho
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
- ✅ **Detectar e remover versões antigas** (serviços, wrappers, sudoers, nginx, dados) — ver abaixo
- ✅ Criar usuário `administrador` (se não existir)
- ✅ Instalar dependências do sistema
- ✅ Configurar ambiente Python com venv
- ✅ Instalar o serviço systemd
- ✅ Configurar auto-login gráfico
- ✅ Instalar e configurar Chromium
- ✅ Criar script de atualização automática

#### Remoção de versões antigas (purge)

Antes de instalar, o script **detecta automaticamente** instalações anteriores —
de **qualquer versão** (os nomes de serviço/wrappers já mudaram ao longo do tempo),
via detecção dinâmica por nome e por conteúdo. Ele **lista** o que encontrou e
**pede confirmação** antes de fazer um **purge total**:

```
⚠️  Instalações/artefatos antigos encontrados:
   - unit: pi-manager.service
   - bin: /usr/local/bin/pi-manager-power
   - sudoers: /etc/sudoers.d/pi-manager
   - dados: /home/administrador/chromium-profile
Remover TUDO isso (PURGE TOTAL — inclui config, senha e favoritos) e prosseguir? (s/N):
```

> ⚠️ O purge remove também os **dados do usuário** (URLs do autostart, senha em
> `/etc/default`, favoritos do Chromium). Para rodar **sem prompt** (automação),
> use `sudo PI_MANAGER_PURGE=yes ./install.sh`. Se você responder "não", a
> instalação é abortada para não conflitar com a versão antiga.

### 4. Acesse a aplicação

Abra seu navegador e acesse (via HTTPS, atendido pelo nginx):

```
https://seu-pi.local
ou
https://192.168.1.100
```

> 🔒 O Pi usa um **certificado autoassinado** (não há domínio público numa rede
> local). Na primeira vez o navegador mostra um aviso "conexão não segura" —
> clique em **Avançado → Prosseguir**. A conexão é criptografada normalmente; o
> aviso some depois. O acesso HTTP (porta 80) é redirecionado automaticamente
> para HTTPS, e o Flask não fica mais exposto diretamente na porta 5000.

**Credenciais padrão do login web:**
- Usuário: `administrador`
- Senha: `sil123`

> ℹ️ Esta é a senha da **interface web** (configurável via `ADMIN_PASSWORD` em
> `/etc/default/raspberry-pi-manager`). Não confunda com a senha do **usuário do
> sistema** `administrador` (padrão `raspberry`, usada para SSH).

⚠️ **ALTERE A SENHA IMEDIATAMENTE APÓS O PRIMEIRO LOGIN**

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

## Atualização Automática Semanal (recomendado para vários Pis)

Cada Pi **verifica sozinho** se há uma nova versão no GitHub, **1× por semana, em
um dia e horário aleatórios** (re-sorteados a cada semana). Se houver atualização,
ele baixa, reinstala dependências no venv e reinicia o serviço. Se não houver,
não faz nada.

Esse é o modelo **PULL**: o Pi *sai* falando com o GitHub, então:
- ✅ **Não precisa saber o IP** de cada Pi nem abrir portas de entrada.
- ✅ **Escala para qualquer quantidade** de Raspberries.
- ✅ **Nada para configurar por Pi** — o instalador já ativa o verificador.

### Como funciona (systemd timer)

O instalador cria `raspberry-pi-manager-update.timer` com:

```ini
OnCalendar=weekly        # base semanal
RandomizedDelaySec=7d    # + atraso aleatório de até 7 dias = dia aleatório da semana
Persistent=true          # se o Pi estava desligado no dia sorteado, roda ao ligar
```

### Comandos úteis

```bash
# Ver quando será a próxima verificação (e o dia sorteado desta semana)
systemctl list-timers 'raspberry-pi-manager-update*'

# Forçar uma verificação/atualização agora (não espera o dia sorteado)
sudo systemctl start raspberry-pi-manager-update.service

# Ver o histórico de atualizações
tail -f /home/administrador/raspberry-pi-manager/update_app.log
```

> O script `update_app.sh` é executado pelo verificador semanal (como root). Ele só
> atualiza quando o Pi está **atrás** do GitHub — comparando o commit local com o
> remoto. É o único mecanismo de atualização (não há webhook/deploy via push).

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

### Atualização automática não funciona

1. Veja se o timer está ativo e quando dispara:
   ```bash
   systemctl list-timers 'raspberry-pi-manager-update*'
   ```

2. Force uma verificação agora (não espera o dia sorteado):
   ```bash
   sudo systemctl start raspberry-pi-manager-update.service
   ```

3. Verifique os logs da atualização:
   ```bash
   tail -f /home/administrador/raspberry-pi-manager/update_app.log
   ```

### Chromium não abre automaticamente

- Verifique se o X11/Wayland está ativo: `echo $DISPLAY`
- Reinicie o serviço lightdm: `sudo systemctl restart lightdm`
- Verifique o arquivo de autostart:
  ```bash
  cat ~/.config/autostart/Chromium-Raspberry.desktop
  ```

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

# Executar atualização manual
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
├── scripts/
│   └── validate.sh            # Validação dos contratos (rodada pelo CI)
├── .github/workflows/
│   └── ci.yml                 # Valida os contratos em cada push/PR
├── install.sh                 # Script de instalação
├── update_app.sh              # Script de atualização automática
├── requirements.txt           # Dependências Python
├── CLAUDE.md                  # Contratos e boas práticas de alteração
└── README.md                  # Este arquivo
```

---

## Variáveis de Ambiente

Edite `/etc/default/raspberry-pi-manager`:

| Variável | Descrição | Padrão |
|----------|-----------|--------|
| `SECRET_KEY` | Chave de assinatura das sessões Flask (gere com `openssl rand -hex 32`) | (auto-gerada/persistida) |
| `ADMIN_PASSWORD` | Senha do login da interface web | `sil123` |
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
- **HTTPS já vem configurado** pelo instalador (nginx + certificado autoassinado). Se o Pi tiver um domínio público, troque por um certificado Let's Encrypt
- **Restrinja acesso de rede** com firewall se exposto à internet
- **Mantenha atualizado** via verificação semanal automática ou manualmente
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
- ✅ Atualização automática semanal (modelo PULL, dia aleatório)
- ✅ Sincronização de favoritos do navegador
- ✅ Logo e background customizados
- ✅ Instalador automático para Raspberry Pi
