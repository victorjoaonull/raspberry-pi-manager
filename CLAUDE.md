# CLAUDE.md — Guia de alterações do raspberry-pi-manager

Este arquivo define os **contratos** que mantêm o projeto funcionando. Antes de
qualquer alteração, leia os contratos abaixo. A validação roda **automaticamente
no CI** (`.github/workflows/ci.yml`) a cada push/PR e falha se algum contrato
quebrar. Para checar localmente antes de commitar, rode `bash scripts/validate.sh`.
Toda mudança deve manter `app.py`, `install.sh`, o serviço systemd e o `README.md`
**alinhados entre si**.

---

## Estrutura

```
raspberry-pi-manager/
├── src/app.py        # Aplicação Flask (ÚNICO ponto de entrada)
├── src/templates/    # Páginas HTML
├── src/static/       # CSS e imagens
├── systemd/          # Unit file de referência
├── install.sh        # Instalador (GERA seu próprio service/run.sh/sudoers)
├── update_app.sh     # Atualizador (verificação semanal PULL; roda como root pelo timer)
├── requirements.txt
├── scripts/validate.sh    # Engine de validação dos contratos (rodada pelo CI)
├── .github/workflows/     # ci.yml — valida os contratos em push/PR
├── CLAUDE.md              # Este arquivo
└── README.md              # Documentação — deve refletir os valores reais
```

---

## Contratos (NÃO quebrar)

### C1 — `app.py` vive em `src/`
Qualquer coisa que execute o app (ExecStart do serviço, `run.sh`, docs) deve
apontar para `src/app.py`, nunca para `app.py` na raiz.
- `install.sh`: `ExecStart=...$INSTALL_DIR/src/app.py` e `exec python src/app.py`.

### C2 — Caminhos derivados da raiz do repositório
`app.py` calcula `BASE_DIR` a partir de `__file__` e deriva `CONFIG_DIR =
BASE_DIR/config` e `LOG_DIR = BASE_DIR/logs`. **Não** use caminhos absolutos
hardcoded (ex.: `/home/administrador/pi-manager/config`). O `install.sh` cria
`$INSTALL_DIR/config`, então os dois ficam alinhados automaticamente.

### C3 — Todo `sudo` em `app.py` precisa de entrada no sudoers
Cada comando executado via `sudo` no `app.py` deve ter cobertura em
`/etc/sudoers.d/pi-manager` (gerado pelo `install.sh`). Hoje cobre:
- root: wrappers `pi-manager-*`, `/sbin/shutdown`, `/usr/sbin/shutdown`, `/usr/bin/pkill`.
- como `administrador` (sem elevar): `env`, `rm`, `find`, `chromium`, `chromium-browser`, `xdpyinfo`.
Se adicionar um novo `sudo <bin>` no código, adicione `<bin>` ao sudoers.
**Prefira wrappers** (como `pi-manager-nmcli`) a liberar binários genéricos como root.

### C4 — Tudo que o app escreve deve estar em `ReadWritePaths`
O serviço roda com `ProtectHome=read-only`/`ProtectSystem=full`. Caminhos graváveis:
`$INSTALL_DIR`, `/home/administrador/chromium-profile`,
`/home/administrador/.config/raspberry-pi-manager` (secret_key).
Novo caminho de escrita → adicione ao `ReadWritePaths` em `install.sh`.

### C5 — Segredos só via ambiente/arquivo, nunca hardcoded
- `app.secret_key`: vem de `SECRET_KEY` (env) → arquivo persistente → geração automática.
- `ADMIN_PASSWORD`: de `/etc/default/raspberry-pi-manager`.
- **Nunca** commitar `secret_key = '...'` literal nem secrets no código.

### C6 — Senha/porta/valores padrão alinhados ao README
A senha padrão do **login web** é `sil123` (default do código `ADMIN_PASSWORD` **e**
do env template). NÃO confundir com a senha do **usuário do sistema** `administrador`,
que é `raspberry` (definida no `install.sh` via `chpasswd`, usada para SSH).
Porta padrão: `5000`. Se mudar qualquer um destes, atualize **no mesmo commit**:
`app.py`, `install.sh` (env template) e `README.md`.

### C10 — `install.sh` remove versões antigas antes de instalar
`detect_and_purge_old()` detecta artefatos de **qualquer** versão anterior
(units por nome `*pi-manager*` E por conteúdo `ExecStart` apontando ao app,
wrappers `pi-manager-*`, sudoers, nginx, env, dados), lista, **pede confirmação**
e faz **purge total**. NUNCA remover diretórios cegamente por nome (apagaria o
próprio repo). Novo artefato criado pela instalação → adicione à detecção.

### C11 — WiFi/rede gerenciáveis apenas pelo serviço
Uma regra polkit (`/etc/polkit-1/rules.d/49-pi-manager-nm.rules`, criada pelo
`install.sh`) NEGA as ações `org.freedesktop.NetworkManager.*` para usuários
não-root. O app funciona porque chama `nmcli` como root (via wrapper
`pi-manager-nmcli`). **Padrão (`PI_MANAGER_WIFI_DEFAULT=keep`)**: mantém a conexão
atual e apenas bloqueia o gerenciamento por não-root (impede desconectar/trocar
de rede pelo ícone do sistema). Opcional `=blocked`: desliga o rádio por padrão
(com trava se o WiFi for o único uplink). O app controla o rádio via
`/api/network/wifi/radio`. Toda gerência de rede deve continuar passando pelo
wrapper (root) — nunca por chamadas não-root.

### C7 — `install.sh` gera o service; o `systemd/*.service` é referência
O instalador escreve seu próprio unit file. Se editar um, reflita no outro
(ExecStart, EnvironmentFile, ReadWritePaths) para não divergirem.

### C8 — README é parte do contrato
O `README.md` deve refletir os caminhos, comandos e valores reais. Ao mudar
estrutura, paths, porta, senha ou passos de instalação, atualize o README junto.
Mantenha a estrutura legível: seções com `##`, blocos de código com a linguagem,
e a árvore de "Estrutura do Projeto" coerente com a real.

---

## Checklist antes de finalizar qualquer alteração

1. [ ] Os contratos C1–C8 acima continuam válidos?
2. [ ] Mexeu em path/porta/senha? Atualizou `app.py` + `install.sh` + `README.md`?
3. [ ] Adicionou `sudo`? Adicionou a entrada no sudoers (C3)?
4. [ ] Adicionou escrita em disco? Está em `ReadWritePaths` (C4)?
5. [ ] Rodou `bash scripts/validate.sh` (ou conferiu o CI verde) sem erros?
6. [ ] README continua legível e coerente com o comportamento real?
