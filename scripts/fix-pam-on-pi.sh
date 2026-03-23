#!/usr/bin/env bash
# Corrige login "PAM nao disponivel" no Raspberry Pi Manager.
#
# Contexto (APT vs pip vs venv):
# - python3-pam (apt) instala o modulo (muitas vezes extensao C) por VERSAO de Python.
#   Se o venv usa Python 3.13 mas o apt so tem pam para 3.11/3.12, "import pam" falha
#   mesmo com include-system-site-packages=true.
# - Este script escolhe um binario do sistema em que "import pam" funciona e RECRIA o venv.
# - python-pam (PyPI) e outro pacote; removemos do venv para nao sombreiar o apt.
#
# Uso no Raspberry (SSH): sudo bash scripts/fix-pam-on-pi.sh
#    ou: sudo INSTALL_DIR=/caminho/da/app bash scripts/fix-pam-on-pi.sh

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
VENV_DIR="${INSTALL_DIR}/venv"
VENV_PIP="${VENV_DIR}/bin/pip"
PYVENV_CFG="${VENV_DIR}/pyvenv.cfg"

pick_python_with_pam() {
  PICK_PAM_PY=""
  for cand in python3.13 python3.12 python3.11 python3.10 python3.14 python3; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import pam" 2>/dev/null; then
      PICK_PAM_PY="$(command -v "$cand")"
      return 0
    fi
  done
  return 1
}

echo "==> Instalando python3-pam (apt)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-pam

if ! pick_python_with_pam; then
  echo "==> Nenhum Python importou pam; a tentar python3.11 + venv (comum quando python3 aponta para 3.13)..."
  apt-get install -y -qq python3.11 python3.11-venv 2>/dev/null || true
fi
if ! pick_python_with_pam; then
  echo "ERRO: Apos apt install python3-pam, nenhum python3.X conseguiu 'import pam'."
  echo "      Ex.: sudo apt install python3.11 python3.11-venv && sudo bash $0"
  exit 1
fi
echo "==> Python do sistema com PAM OK: $PICK_PAM_PY"

needs_rebuild=false
if [ ! -x "${VENV_DIR}/bin/python" ]; then
  needs_rebuild=true
elif ! sudo -u administrador "${VENV_DIR}/bin/python" -c "import pam" 2>/dev/null; then
  echo "==> O venv atual NAO importa pam (versao do Python diferente do modulo apt)."
  needs_rebuild=true
fi

if [ "$needs_rebuild" = true ]; then
  echo "==> Recriando venv com: $PICK_PAM_PY"
  rm -rf "$VENV_DIR"
  sudo -u administrador "$PICK_PAM_PY" -m venv "$VENV_DIR" --system-site-packages
fi

if [ -f "$PYVENV_CFG" ] && grep -q '^include-system-site-packages = false' "$PYVENV_CFG" 2>/dev/null; then
  echo "==> Ativando heranca de site-packages do sistema no venv (pyvenv.cfg)..."
  sed -i 's/^include-system-site-packages = false/include-system-site-packages = true/' "$PYVENV_CFG"
fi

if [ -x "$VENV_PIP" ]; then
  echo "==> pip install -r requirements.txt (se existir)..."
  sudo -u administrador "$VENV_PIP" install --upgrade pip
  if [ -f "${INSTALL_DIR}/requirements.txt" ]; then
    sudo -u administrador "$VENV_PIP" install -r "${INSTALL_DIR}/requirements.txt"
  fi
  echo "==> Removendo pacote pip 'python-pam' do venv (se existir; 'Skipping' e normal)..."
  sudo -u administrador "$VENV_PIP" uninstall -y python-pam 2>/dev/null || true
  rm -rf "${INSTALL_DIR}/venv/lib"/python3.*/site-packages/pam "${INSTALL_DIR}/venv/lib"/python3.*/site-packages/pam-*.dist-info 2>/dev/null || true
else
  echo "ERRO: venv sem pip em $VENV_PIP"
  exit 1
fi

echo "==> Reiniciando servico..."
systemctl restart raspberry-pi-manager

echo "==> Teste de import (deve imprimir OK):"
sudo -u administrador "${VENV_DIR}/bin/python" -c "import pam; assert callable(getattr(pam,'authenticate',None)); print('OK')"

echo "Pronto. Acesse de novo a pagina de login."
