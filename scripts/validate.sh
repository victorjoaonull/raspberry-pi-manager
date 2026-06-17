#!/bin/bash
# =============================================================================
# Validação dos contratos do raspberry-pi-manager (ver CLAUDE.md, C1–C8).
# Roda no CI (.github/workflows/ci.yml) e localmente.
# Sai com código != 0 se qualquer contrato estiver quebrado.
# =============================================================================
set -uo pipefail

# Raiz do repositório = pasta-pai deste script
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="src/app.py"
INSTALL="install.sh"
README="README.md"

FAIL=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=1; }

echo "🔎 Validando contratos do projeto em: $ROOT"

# --- C0: Python compila ------------------------------------------------------
echo "[C0] Sintaxe Python"
if python3 -m py_compile "$APP" 2>/dev/null; then
    pass "src/app.py compila"
else
    fail "src/app.py NÃO compila (erro de sintaxe)"
fi

# --- C1: app.py em src/ e referenciado corretamente --------------------------
echo "[C1] Ponto de entrada src/app.py"
[ -f "$APP" ] && pass "src/app.py existe" || fail "src/app.py não encontrado"
grep -q 'ExecStart=.*\$INSTALL_DIR/src/app.py' "$INSTALL" \
    && pass "install.sh ExecStart aponta para src/app.py" \
    || fail "install.sh ExecStart NÃO aponta para src/app.py"
grep -q 'exec python src/app.py' "$INSTALL" \
    && pass "run.sh (gerado) usa src/app.py" \
    || fail "run.sh gerado NÃO usa src/app.py"

# --- C2: caminhos derivados, sem hardcode ------------------------------------
echo "[C2] Caminhos derivados da raiz"
grep -q 'BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))' "$APP" \
    && pass "app.py define BASE_DIR a partir de __file__" \
    || fail "app.py não deriva BASE_DIR de __file__"
if grep -q "/pi-manager/config" "$APP"; then
    fail "app.py contém caminho hardcoded '/pi-manager/config'"
else
    pass "app.py sem caminho de config hardcoded"
fi

# --- C3: todo sudo em app.py coberto pelo sudoers ----------------------------
echo "[C3] Cobertura de sudo no sudoers"
SUDOERS_BLOCK="$(awk '/sudoers.d\/pi-manager << /{f=1} f; /^EOF$/{if(f)exit}' "$INSTALL")"
# binários esperados (root + como administrador)
for bin in shutdown pkill chromium env rm find xdpyinfo; do
    if echo "$SUDOERS_BLOCK" | grep -q "/$bin\b"; then
        pass "sudoers cobre '$bin'"
    else
        fail "sudoers NÃO cobre '$bin' (usado via sudo no app.py)"
    fi
done
# Heurística: avisa sobre binários sudo no app.py possivelmente não cobertos
while read -r b; do
    [ -z "$b" ] && continue
    case "$b" in nmcli|chpasswd|hostnamectl|pi-manager-*|administrador|now|sudo|set-hostname|env) continue;; esac
    echo "$SUDOERS_BLOCK" | grep -q "/$b\b" \
        || echo "  ⚠️  '$b' aparece após sudo no app.py — confirme cobertura no sudoers"
done < <(grep -oE "'sudo'[^]]*" "$APP" | grep -oE "'[a-z][a-z0-9-]+'" | tr -d "'" | sort -u)

# --- C4: ReadWritePaths cobre o que o app escreve ----------------------------
echo "[C4] ReadWritePaths"
grep -q 'ReadWritePaths=.*\.config/raspberry-pi-manager' "$INSTALL" \
    && pass "ReadWritePaths inclui ~/.config/raspberry-pi-manager (secret_key)" \
    || fail "ReadWritePaths NÃO inclui ~/.config/raspberry-pi-manager"

# --- C5: nenhum segredo hardcoded --------------------------------------------
echo "[C5] Segredos não hardcoded"
if grep -qE "secret_key\s*=\s*['\"]" "$APP"; then
    fail "app.py tem secret_key hardcoded (use _load_secret_key/env)"
else
    pass "app.py sem secret_key literal"
fi
grep -q '_load_secret_key' "$APP" \
    && pass "app.py usa _load_secret_key()" \
    || fail "app.py não usa _load_secret_key()"

# --- C6: senha/porta alinhadas em app/install/README -------------------------
echo "[C6] Valores padrão alinhados (senha web / porta)"
for f in "$APP" "$INSTALL" "$README"; do
    grep -q 'sil123' "$f" \
        && pass "$f menciona senha web 'sil123'" \
        || fail "$f NÃO menciona a senha web padrão 'sil123'"
done
for f in "$APP" "$README"; do
    grep -q '5000' "$f" \
        && pass "$f menciona porta 5000" \
        || fail "$f NÃO menciona porta 5000"
done

# --- C9: atualização automática (updater + timer) ----------------------------
echo "[C9] Atualização automática"
if grep -q 'pip install' update_app.sh && ! grep -q 'VENV_PIP' update_app.sh; then
    fail "update_app.sh faz 'pip install' sem usar o pip do venv (VENV_PIP)"
else
    pass "update_app.sh usa o pip do venv"
fi
grep -q 'git rev-parse HEAD' update_app.sh && grep -q 'git rev-parse "origin/$BRANCH"' update_app.sh \
    && pass "update_app.sh compara local x remoto antes de atualizar" \
    || fail "update_app.sh não compara local x remoto (atualizaria sempre)"
grep -q 'OnCalendar=weekly' install.sh && grep -q 'RandomizedDelaySec=7d' install.sh \
    && pass "install.sh gera timer semanal com dia aleatório" \
    || fail "install.sh não gera o timer semanal aleatório"
# Webhook PUSH removido: só o modelo PULL (verificação semanal) deve existir.
if grep -q "@app.route('/webhook'" "$APP" || [ -f .github/workflows/deploy.yml ]; then
    fail "modelo webhook/PUSH ainda presente (deve existir só o PULL semanal)"
else
    pass "webhook/PUSH removido — apenas modelo PULL semanal"
fi

# --- C8: README presente e com seções mínimas --------------------------------
echo "[C8] README coerente"
[ -f "$README" ] && pass "README.md existe" || fail "README.md ausente"
grep -q '## Instalação' "$README" \
    && pass "README tem seção de Instalação" \
    || fail "README sem seção de Instalação"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "✅ Todos os contratos validados com sucesso."
else
    echo "❌ Validação falhou — corrija os itens marcados acima (ver CLAUDE.md)."
fi
exit "$FAIL"
