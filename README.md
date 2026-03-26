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

## Guia: instalar no Raspberry Pi e configurar

Este repositório instala um **painel web** (Flask) que corre como **serviço systemd** com o nome por omissão `raspberry-pi-manager`, executado pelo utilizador Linux **`administrador`**. O **login da interface** valida a **mesma palavra-passe** desse utilizador via **PAM** (não há base de dados de utilizadores na app). A **rede** no painel usa **NetworkManager** (`nmcli` através de wrappers com permissões controladas em `sudoers`). O **Chromium** usa um **perfil dedicado** (`--user-data-dir`, por omissão `~/chromium-profile`) para autostart, favoritos e evitar conflitos com outras instâncias.

### Fluxo geral do instalador (`install.sh`)

1. **Ambiente**: confirma que o hardware é Raspberry Pi, que corre como **root** (`sudo`) e cria o utilizador **`administrador`** com palavra-passe inicial `raspberry` se ainda não existir (deve alterar logo após o primeiro acesso).
2. **Assistente opcional** (`scripts/install-wizard.sh`): em terminal interativo, **ENTER** aceita a configuração recomendada (cópia local do repositório para `/home/administrador/raspberry-pi-manager`); **`o`** abre opções simples (clonar do GitHub, pasta de instalação, rede temporária durante o `apt`, limpeza alargada de pastas antigas). Em automação: `PI_MANAGER_INSTALL_INTERACTIVE=0`.
3. **Limpeza de instalações antigas**: remove apenas pastas com nomes previsíveis (`raspberry-pi-manager` / `raspberry_pi_manager`) em caminhos seguros; a varredura larga `*pi-manager*` exige `PI_MANAGER_LEGACY_WIDE_CLEANUP=1`.
4. **Variáveis** como `INSTALL_DIR`, `PI_MANAGER_CHROMIUM_USER_DATA_DIR`, `CLONE_FROM_GITHUB` podem ser definidas **antes** de correr o script (ou via assistente).
5. **Rede opcional para atualizações**: se `PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1`, o script pode guardar o IPv4 atual, aplicar um endereço temporário (ex. rede de gestão) durante o `apt`, e restaurar — requer `nmcli` / NetworkManager (ver tabela mais abaixo).
6. **Conectividade** (`[1.5/12]`): ping para confirmar acesso à Internet antes do `apt`.
7. **Pré-voo** (`[1.6/12]`, `scripts/install-preflight-checks.sh`): após haver rede, verifica **UTF-8** (recomendado para a UI e logs); opcionalmente **espaço em disco** e **memória**. Variáveis: `PI_MANAGER_SKIP_PREFLIGHT`, `PI_MANAGER_UTF8_AUTO_FIX`, `PI_MANAGER_STRICT_LOCALE`, `PI_MANAGER_PREFLIGHT_BASIC`.
8. **`apt upgrade`** e instalação de dependências (entre elas **nginx**, **git**, **chromium**, **network-manager**, **python3-pam**, etc.).
9. **Cópia do projeto** para `INSTALL_DIR` (ou clone do GitHub se configurado), cópia de `update_app.sh`, wrappers em `/usr/local/bin`, **venv** Python com suporte a **PAM** do sistema, `requirements.txt`.
10. **Ficheiro de ambiente** `/etc/default/raspberry-pi-manager` (ex.: `APP_INSTALL_DIR`, `FLASK_SECRET_KEY` gerada se faltar, `PI_MANAGER_CHROMIUM_USER_DATA_DIR`).
11. **Unit systemd** em `/etc/systemd/system/raspberry-pi-manager.service`, utilizador **administrador**, `EnvironmentFile` apontando para `/etc/default/...`.
12. **Auto-login gráfico** (lightdm) e **atalho** `Chromium-Raspberry.desktop` na área de trabalho — **o mesmo perfil** que o serviço usa para o autostart; o instalador **não** coloca um segundo `.desktop` em `~/.config/autostart` para o mesmo perfil (evita SingletonLock e dupla abertura).

Após a instalação: `sudo systemctl enable --now raspberry-pi-manager` fica tratado pelo script; aceda a **`http://<IP-do-Pi>:5000`**, inicie sessão com o utilizador Linux configurado (por omissão `administrador` / `raspberry`) e **altere a palavra-passe** em **Sistema → Senha**.

### Configurar o sistema depois de instalado

| Área | O que fazer |
|------|-------------|
| **Segurança** | Alterar a palavra-passe Linux do `administrador`; definir **`FLASK_SECRET_KEY`** estável em `/etc/default/raspberry-pi-manager` (o instalador gera uma se faltar; sem ela, reinícios invalidam sessões). Opcional: **`PI_MANAGER_HEALTH_SECRET`** para não expor `/api/health` sem cabeçalho. |
| **Pasta da app e atualizações** | Garantir que **`APP_INSTALL_DIR`** (e o caminho real da instalação) coincidem; o **webhook** e o **`update_app.sh`** só consideram caminhos permitidos. |
| **Autostart e browser** | Editar URLs em **`config/autostart.conf`** (UI **Autostart**). O serviço abre o Chromium **uma vez** com lock em ficheiro e deteção de processo; não duplicar autostart do mesmo perfil. Ver secção *Chromium não abre automaticamente* em *Troubleshooting*. |
| **Rede** | Configurar na UI **Rede** ou com `nmcli`; wrappers registados em `sudoers`. |
| **Atualizações Git** | Definir **`WEBHOOK_SECRET`** no Pi e no GitHub Actions; workflow `.github/workflows/deploy.yml` dispara o webhook. Atualização manual: `sudo /usr/local/bin/update_app.sh` (logs em `update_app.log` na pasta da app). |
| **Variáveis avançadas** | Tabela completa na secção **Variáveis de ambiente (`/etc/default/raspberry-pi-manager`)** (login, diagnóstico, proxy, rede temporária, etc.). Sempre **`sudo systemctl restart raspberry-pi-manager`** após editar o ficheiro. |

### Desinstalar ou repor integração

O **`uninstall.sh`** remove serviço, unit, wrappers, `sudoers` e opcionalmente a pasta da aplicação e ficheiros `*pi-manager*` extra em `/home/administrador`. **Não** remove pacotes `apt`, auto-login nem o perfil Chromium por omissão — ver comandos na secção **Desinstalar** abaixo.

### Onde aprofundar

- **Instalação rápida** (comandos mínimos): secção seguinte.
- **Tabelas de variáveis** e **rede temporária**: mais abaixo no mesmo README.
- **Problemas com PAM, charset, Chromium, webhook**: secção **Troubleshooting**.

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

**Assistente simples:** ao correr com terminal interativo (SSH ou consola), aparece uma **configuração rápida**: prima **ENTER** para usar as opções recomendadas (cópia local para `/home/administrador/raspberry-pi-manager`). Digite **`o`** e ENTER para escolher em poucos passos: clonar do GitHub, pasta de instalação, rede temporária durante o `apt` (avançado) ou limpeza antiga alargada. Para desligar perguntas (CI, scripts): `export PI_MANAGER_INSTALL_INTERACTIVE=0` antes do `sudo`.

**UTF-8 e verificações básicas:** depois de confirmar **conectividade de rede** (`[1.5/12]`), o passo **`[1.6/12]`** verifica se o sistema usa **UTF-8** (evita bugs na interface e nos logs). Se não for o caso, pergunta se deve configurar **antes** do `apt upgrade`. Opcionalmente pergunta se quer **verificações básicas** (espaço em disco e memória). Variáveis: `PI_MANAGER_SKIP_PREFLIGHT=1` (ignorar tudo), `PI_MANAGER_UTF8_AUTO_FIX=1` (corrigir UTF-8 sem perguntar), `PI_MANAGER_STRICT_LOCALE=1` (abortar se recusar UTF-8 e o sistema continuar sem UTF-8), `PI_MANAGER_PREFLIGHT_BASIC=1` (executar verificações extra sem perguntar).

O script irá:
- ✅ Remover instalações antigas
- ✅ Criar usuário `administrador` (se não existir)
- ✅ Instalar dependências do sistema
- ✅ Configurar ambiente Python com venv
- ✅ Instalar o serviço systemd
- ✅ Configurar auto-login gráfico
- ✅ Instalar e configurar Chromium
- ✅ Criar atalho **Chromium-Raspberry.desktop** na área de trabalho (`xdg-user-dir DESKTOP`): mesmo perfil que o serviço (por omissão `/home/administrador/chromium-profile`; configurável com `PI_MANAGER_CHROMIUM_USER_DATA_DIR` antes do `install.sh` ou em `/etc/default/...`) e mesmas flags base que o autostart (marcado como confiável para duplo clique quando `gio` estiver disponível)
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
sudo ./uninstall.sh              # confirmações; procura *pi-manager* extra em /home/administrador
sudo ./uninstall.sh -y           # remove serviço, wrappers, sudoers, pasta da app e *pi-manager* em home
sudo ./uninstall.sh -y --purge   # também remove /etc/default/raspberry-pi-manager
sudo ./uninstall.sh -y --keep-app-dir   # só remove integração (systemd, /usr/local/bin, sudoers)
sudo ./uninstall.sh --skip-home-wide    # não remove pastas/ficheiros *pi-manager* extra em home
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

**Instalação em pasta personalizada:** defina `INSTALL_DIR` ao correr o `install.sh` e confirme que `/etc/default/raspberry-pi-manager` contém `APP_INSTALL_DIR` com o mesmo caminho (o instalador acrescenta se faltar). Isso alinha `update_app.sh`, o webhook (só executa `update_app.sh` dentro de diretórios permitidos) e as atualizações.

---

## Variáveis de ambiente (`/etc/default/raspberry-pi-manager`)

| Variável | Descrição |
|----------|-----------|
| `WEBHOOK_SECRET` | Secret HMAC do GitHub (obrigatório para auto-update via webhook). |
| `APP_INSTALL_DIR` | Diretório da aplicação (usado por `update_app.sh` em `/usr/local/bin` e na lista segura do webhook). |
| `PI_MANAGER_INSTALL_DIR` | Opcional; mesmo papel que `APP_INSTALL_DIR` se precisar de um segundo nome. |
| `PI_MANAGER_CHROMIUM_USER_DATA_DIR` | Pasta do perfil Chromium (`--user-data-dir`). Por omissão: `/home/administrador/chromium-profile`. Use outro caminho (ex. `.../chromium-profile-padrao`) após clonar imagem ou mudar hostname para evitar bloqueio SingletonLock. |
| `PI_MANAGER_LOG_DIR` | Onde gravar logs de ficheiro da app (ex.: `browser-launch.log`). Por omissão: `<pasta da app>/logs`. |
| `SESSION_COOKIE_SECURE` | `true` / `1` / `yes` se a UI for servida só por HTTPS (cookies `Secure`). |
| `SESSION_COOKIE_SAMESITE` | Valor do SameSite (ex.: `Lax`, `Strict`); por omissão `Lax`. |
| `PI_MANAGER_PAM_USER` | Utilizador Linux cuja senha é validada no login (por omissão `administrador`). |
| `PI_MANAGER_PAM_SERVICES` | Lista de serviços PAM a tentar, separados por vírgula (por omissão `login,sshd,su,sudo`). |
| `PI_MANAGER_HEALTH_SECRET` | Opcional. Se definido, **`GET /api/health`** só responde com o JSON completo quando o pedido inclui o cabeçalho **`X-Health-Secret`** com o mesmo valor; caso contrário devolve **`404`** com `{"ok": false}` (menos exposição de diagnóstico na rede). |
| `PI_MANAGER_DEBUG_TRACEBACK` | Opcional (`true`/`1`/`yes`). Quando ativo, o servidor regista **tracebacks** extra em pontos que antes engoliam erros (ex.: limpeza de locks Chromium, `pgrep`), útil para diagnóstico no `journalctl`. |
| `FLASK_SECRET_KEY` | **Recomendado em produção.** Chave hexadecimal longa para assinar cookies de sessão. O **`install.sh`** gera e grava em `/etc/default/...` se ainda não existir; sem isto, cada restart do serviço gera chave nova e **desliga todas as sessões**. |
| `PI_MANAGER_DIAGNOSTICS` | `true`/`1`/`yes` ativa **`/api/diagnostic/*`** e **`/api/favorites/diagnostic`**. Por omissão **desligado** (resposta `404` mínima), exceto se a app correr em **debug**. |
| `PI_MANAGER_LOGIN_RATE_LIMIT` | `0`/`false` desliga o limite de tentativas de login; por omissão **ativo**. |
| `PI_MANAGER_LOGIN_MAX_FAILS` | Número máximo de falhas de palavra-passe na janela (por omissão **8**). `≤ 0` desliga o limite. |
| `PI_MANAGER_LOGIN_WINDOW_SEC` | Janela em segundos para contar falhas (por omissão **900** = 15 min). |
| `PI_MANAGER_LOGIN_LOCKOUT_SEC` | Duração do bloqueio após exceder o máximo (por omissão **600** = 10 min). |
| `PI_MANAGER_TRUST_PROXY` | `true` se estiver atrás de um **proxy de confiança**; o limite de login usa o primeiro IP de **`X-Forwarded-For`**. **Não ative** sem proxy controlado (risco de spoofing). |
| `PI_MANAGER_ASCII_LOGS` | `true`/`1`/`yes`: substitui **emoji** comuns nos logs do painel (`add_event`) e em algumas mensagens de consola por etiquetas **`[OK]`**, **`[WARN]`**, etc. (útil em `journalctl` / terminais sem Unicode). |
| `SKIP_STARTUP_TASKS` | Reservado para **testes** (`1`/`true`): não executa `startup_tasks()` na importação do `app.py` (evita sleeps e threads). **Não use em produção**. |

**Atualização com IPv4 temporário (Raspberry Pi / NetworkManager):** variáveis de **ambiente** (não vão em `/etc/default` por omissão; use `export` no cron, webhook ou `sudo env …`). Com **`PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1`**, o `install.sh` (antes do `apt upgrade`) e o `update_app.sh` podem **guardar** a ligação IPv4 atual, aplicar um endereço **estático temporário** e **restaurar** no fim ou em caso de erro (via `trap`). Requer **`nmcli`** (pacote `network-manager`). O instalador instala o NM cedo se o swap estiver ativo e o `nmcli` ainda não existir.

| Variável | Descrição |
|----------|-----------|
| `PI_MANAGER_NETWORK_SWAP_FOR_UPDATE` | `1` ativa o fluxo guardar → IP temporário → atualizar → restaurar. |
| `PI_MANAGER_UPDATE_IPV4` | IPv4 temporário (por omissão `10.0.8.94`). |
| `PI_MANAGER_UPDATE_PREFIX` | Prefixo CIDR (por omissão `24`). |
| `PI_MANAGER_UPDATE_GW` | Gateway durante a janela de atualização (recomendado na rede de gestão). |
| `PI_MANAGER_UPDATE_DNS` | DNS durante a janela (por omissão `8.8.8.8 8.8.4.4`). |
| `PI_MANAGER_NETWORK_SWAP_STATE` | Caminho do ficheiro de estado (por omissão `/run/pi-manager-network-swap.state`). |

**Aviso:** mudar o IP pode **cortar SSH** se a sessão não estiver na mesma subnet; prefira consola, IPMI ou rede de gestão. Defina **`PI_MANAGER_UPDATE_GW`** (e DNS) conforme a VLAN onde o Pi precisa de chegar aos repositórios.

Reinicie o serviço após alterar: `sudo systemctl restart raspberry-pi-manager`.

### Manutenção (Etapa 2 — auditoria)

- **`src/lib/chromium_favorites.py`**: lógica de favoritos fora do `app.py`.
- **`scripts/install-wizard.sh`**: perguntas simples no **`install.sh`** (Enter = recomendado; `o` para mais opções); desligar com **`PI_MANAGER_INSTALL_INTERACTIVE=0`**.
- **`scripts/install-preflight-checks.sh`**: locale **UTF-8** (após rede) e verificações opcionais de disco/memória; ver variáveis `PI_MANAGER_SKIP_PREFLIGHT`, `PI_MANAGER_UTF8_AUTO_FIX`, etc. na secção de instalação rápida.
- **`scripts/lib-pam-venv.sh`**: funções partilhadas de PAM no venv; usadas por **`install.sh`**, **`scripts/fix-pam-on-pi.sh`** e **`update_app.sh`** (com fallback se o ficheiro ainda não existir numa instalação antiga).
- **`scripts/lib-network-swap-for-update.sh`**: troca temporária de IPv4 via **NetworkManager** durante `install.sh` / `update_app.sh` quando **`PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1`** (ver tabela acima).
- **Chromium**: `pgrep` / `pkill` / wrapper **`pi-manager-chromium-clean-locks`** passam a alvo só processos com **`--user-data-dir=`** igual ao perfil gerido (variável de ambiente / predefinição), para não encerrar outras instâncias do Chromium no mesmo sistema.

### Robustez (Etapa 3 — auditoria)

- **`FLASK_SECRET_KEY`**: gerada pelo **`install.sh`** quando em falta; sessões estáveis entre restarts.
- **Login**: limite de tentativas por IP (falhas de palavra-passe + tentativas vazias), com bloqueio temporário; sem biblioteca extra.
- **Diagnóstico**: rotas **`/api/diagnostic/*`** e **`/api/favorites/diagnostic`** só com **`PI_MANAGER_DIAGNOSTICS=true`** (ou modo debug).
- **`update_app.sh`**: verificação final **`import pam`** registada em `update_app.log`; opcional **`UPDATE_APP_STRICT_PAM=1`** para **`exit 1`** se PAM falhar (útil em CI ou webhook com monitorização).

### Qualidade / DX (Etapa 4 — auditoria)

- **Logs ASCII**: variável **`PI_MANAGER_ASCII_LOGS`** para `journalctl` sem emoji.
- **`install.sh`**: limpeza de pastas antigas só com nomes **`raspberry-pi-manager`** / **`raspberry_pi_manager`** em caminhos previsíveis (`/home/*`, `/opt`, …). A varredura larga `*pi-manager*` fica atrás de **`PI_MANAGER_LEGACY_WIDE_CLEANUP=1`** (comportamento antigo, mais arriscado).
- **Testes**: `pip install -r requirements-dev.txt` e `pytest` na raiz do repositório (`tests/`).
- **Tipos**: `mypy.ini` cobre `src/lib/*.py` (módulos extraídos); correr `mypy` após instalar `requirements-dev.txt`.

### Fluxo do login (PAM) — resumo

1. O browser envia **POST `/login`** com a senha do utilizador configurado (`PI_MANAGER_PAM_USER`, por defeito `administrador`), um **token CSRF** (campo oculto + sessão) e está sujeito a **limite de tentativas** por IP (ver variáveis `PI_MANAGER_LOGIN_*` acima).
2. **`get_pam_module()`** carrega o módulo `pam` (preferencialmente **`python3-pam` do apt** dentro do venv com `include-system-site-packages=true`, com reforço de `sys.path` para `dist-packages`).
3. **`verify_admin_password()`** chama `authenticate(user, password, service=…)` para cada serviço em **`PI_MANAGER_PAM_SERVICES`** e trata **tanto excepções como retorno `False`** (comportamento típico do Debian).
4. Se o módulo não carregar, a página de login mostra instruções; em qualquer caso pode abrir **`/api/health`** (JSON) para ver: `pam_module_loaded`, `venv_include_system_site_packages`, `linux_user_exists`, `pam_user`, `pam_services`, etc.

**Checklist rápido no Pi:** sem `PI_MANAGER_HEALTH_SECRET`: `curl -s http://127.0.0.1:5000/api/health | python3 -m json.tool` — confirme `pam_module_loaded: true`, `venv_include_system_site_packages: true` e `linux_user_exists: true`. Com segredo definido: `curl -s -H "X-Health-Secret: SEU_SEGREDO" http://127.0.0.1:5000/api/health | python3 -m json.tool`.

**`pam_module_loaded: false` com `No module named 'pam'` e `venv_include_system_site_packages: true`:** em **Debian Trixie** (Raspberry Pi OS recente) o pacote `python3-pam` pode estar instalado mas **nenhum** `python3.X -c "import pam"` funciona no sistema (falta de módulo compilado para essa versão/arm64). O **`install.sh`** e o **`scripts/fix-pam-on-pi.sh` atualizados** instalam então **`python-pam` via pip** no venv após o `requirements.txt`. No Pi: `sudo bash ~/raspberry-pi-manager/scripts/fix-pam-on-pi.sh` ou volte a correr o instalador com o repo atualizado.

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

3. Verifique os logs do webhook em `update_app.log` na pasta da instalação (valor de `APP_INSTALL_DIR` em `/etc/default/raspberry-pi-manager`, por defeito `/home/administrador/raspberry-pi-manager/update_app.log`):
   ```bash
   tail -f /home/administrador/raspberry-pi-manager/update_app.log
   ```
   Se mudou o diretório de instalação, o webhook só corre `update_app.sh` se o caminho estiver permitido (raiz da app, `..`, caminhos conhecidos ou o definido em `APP_INSTALL_DIR` / `PI_MANAGER_INSTALL_DIR`).

### Login: "PAM nao disponivel" ou acentos quebrados (MÃ³dulo / usuÃ¡rio)

**PAM — APT, pip e venv (leia isto se o apt diz que `python3-pam` já está instalado)**

- **`python3-pam` (apt)** e **`python-pam` (PyPI)** são pacotes **diferentes**. O projeto usa **só o do Debian** (`apt install python3-pam`).
- O **venv isola** o Python: por defeito **não vê** os módulos do sistema. O `python3-pam` do apt fica em *site-packages* do sistema; o interpretador dentro do venv só o importa se o venv tiver sido criado com **`--system-site-packages`** (ou `pyvenv.cfg` com `include-system-site-packages = true`). É o comportamento documentado dos ambientes virtuais em Python.
- O `pip uninstall python-pam` no venv só remove o wheel **PyPI** (se existir). A mensagem *Skipping … not installed* é **normal** quando esse pacote nunca foi instalado no venv.
- O problema típico de “já tenho python3-pam no sistema mas o login falha” é: **venv sem herança de site-packages** ou **wheel PyPI `python-pam` no venv** a sombrear o apt.

**Passos**

1. No Pi (SSH), use o script (instala apt, ajusta `pyvenv.cfg` se estiver `false`, remove `python-pam` do pip, reinicia o serviço):
   ```bash
   sudo bash /home/administrador/raspberry-pi-manager/scripts/fix-pam-on-pi.sh
   ```
   Ou manualmente (equivalente resumido):
   ```bash
   sudo apt install -y python3-pam
   # Se criou o venv sem --system-site-packages, edite venv/pyvenv.cfg e ponha include-system-site-packages = true
   sudo -u administrador /home/administrador/raspberry-pi-manager/venv/bin/pip uninstall -y python-pam
   sudo systemctl restart raspberry-pi-manager
   ```
2. Confira o erro real: `journalctl -u raspberry-pi-manager -b -n 40 --no-pager`
3. O `install.sh` cria o venv com **`--system-site-packages`** e corrige `pyvenv.cfg` se vier `false` (Debian).
4. A aplicação também tenta acrescentar `dist-packages` do sistema ao `sys.path` como reforço; o caminho suportado continua a ser **venv + apt + sem `python-pam` no pip**.

**Acentos (charset)**

- Acesse direto `http://IP:5000` (sem proxy) ou configure nginx com `charset utf-8;`.
- Atualize a página com Ctrl+F5. A aplicação força `Content-Type: ... charset=utf-8`.

### Chromium não abre automaticamente

O Chromium com **URLs de `config/autostart.conf`** é aberto **uma vez** pelo serviço `raspberry-pi-manager` (thread em `startup_tasks` → `open_browser_with_urls`). O código usa **lock em ficheiro** (`fcntl`, por omissão em `/tmp/pi-manager-chromium-launch.lock`; override: `PI_MANAGER_CHROMIUM_LAUNCH_LOCK`) para evitar duas threads a lançarem em simultâneo, **deteta** processos com `pgrep -f -- --user-data-dir=…` (o `--` evita o padrão ser confundido com opções) e, antes de um segundo lançamento após singleton, volta a verificar se o browser já está a correr. Não use um segundo `.desktop` em `~/.config/autostart/` para o mesmo perfil (`chromium-profile`), senão há risco de SingletonLock / duas aberturas.

- **Comentários em `autostart.conf`:** só linhas que começam por `#` são ignoradas. Texto de comentário sem `#` no início pode ser tratado como URL inválida ou virar `http://...` estranho.
- **Singleton / “outro computador”:** o instalador cria `/usr/local/bin/pi-manager-chromium-clean-locks` (no sudoers) para matar o Chromium como root e apagar `Singleton*` mesmo que tenham sido criados por outro UID. Após atualizar o projeto, volte a correr o `install.sh` (ou adicione o wrapper e a linha no `sudoers` manualmente) para não ficar só com `sudo find` genérico (que pode não estar permitido).
- **Perfil novo:** defina `PI_MANAGER_CHROMIUM_USER_DATA_DIR` se mudou hostname ou clonou imagem (ver secção de variáveis de ambiente).

- Aguarde ~15–20 s após o boot (atraso interno para X11 e display `:0`).
- Verifique o serviço: `sudo systemctl status raspberry-pi-manager`
- Log de lançamento: `tail -f <pasta-da-app>/logs/browser-launch.log` (ou o caminho em `PI_MANAGER_LOG_DIR`)
- Display: `sudo -u administrador env DISPLAY=:0 xdpyinfo`
- Reinício gráfico se necessário: `sudo systemctl restart lightdm`

### Serviço `masked` (não inicia)

Se aparecer `Unit ... is masked`:

```bash
sudo systemctl unmask raspberry-pi-manager.service
sudo systemctl daemon-reload
sudo systemctl enable --now raspberry-pi-manager.service
```

O `install.sh` atual remove a máscara automaticamente antes de habilitar o serviço.

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
├── install.sh                 # Script de instalação (assistente: scripts/install-wizard.sh)
├── scripts/                   # install-wizard, lib-pam-venv, lib-network-swap, fix-pam-on-pi
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

# Crie um venv (no Linux/Debian, --system-site-packages permite importar python3-pam do apt)
python3 -m venv venv --system-site-packages
source venv/bin/activate

# Instale dependências (não instale o pacote PyPI "python-pam")
pip install -r requirements.txt

# Rode localmente
python3 src/app.py
```

Acesse `http://localhost:5000`. Em Windows o login PAM não replica o Pi; em Linux com `python3-pam` (apt) e venv com `--system-site-packages`, o fluxo aproxima-se do Raspberry.

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
