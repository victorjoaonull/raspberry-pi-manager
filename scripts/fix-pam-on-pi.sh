#!/usr/bin/env bash
# Corrige login "PAM nao disponivel" no Raspberry Pi Manager.
#
# Ordem de preferencia:
# 1) python3-pam (apt) visivel no venv (system-site-packages + mesmo Python que tem o .so)
# 2) Se nenhum python3.X do sistema importa pam (ex.: Debian Trixie + 3.13): python-pam (PyPI) no venv
#
# Uso: sudo bash scripts/fix-pam-on-pi.sh
#      sudo INSTALL_DIR=/caminho/da/app bash scripts/fix-pam-on-pi.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-pam-venv.sh
source "${SCRIPT_DIR}/lib-pam-venv.sh"

INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
VENV_DIR="${INSTALL_DIR}/venv"
VENV_PY="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
PYVENV_CFG="${VENV_DIR}/pyvenv.cfg"

echo "==> apt: python3-pam..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-pam

if pick_python_with_pam; then
  VPY="$PICK_PAM_PY"
  echo "==> Sistema com import pam em: $VPY"
else
  VPY="$(command -v python3)"
  echo "==> Nenhum python3.X importa pam pelo apt; venv com $VPY + pip python-pam se preciso."
fi

needs_rebuild=false
if [ ! -x "$VENV_PY" ]; then
  needs_rebuild=true
elif ! sudo -u administrador "$VENV_PY" -c "import pam" 2>/dev/null; then
  needs_rebuild=true
fi

if [ "$needs_rebuild" = true ]; then
  echo "==> Recriando venv com: $VPY"
  rm -rf "$VENV_DIR"
  sudo -u administrador "$VPY" -m venv "$VENV_DIR" --system-site-packages
fi

if [ -f "$PYVENV_CFG" ] && grep -q '^include-system-site-packages = false' "$PYVENV_CFG" 2>/dev/null; then
  sed -i 's/^include-system-site-packages = false/include-system-site-packages = true/' "$PYVENV_CFG"
  echo "==> pyvenv.cfg: include-system-site-packages=true"
fi

if [ ! -x "$VENV_PIP" ]; then
  echo "ERRO: sem pip em $VENV_PIP"
  exit 1
fi

echo "==> pip install -r requirements.txt (se existir)..."
sudo -u administrador "$VENV_PIP" install --upgrade pip
if [ -f "${INSTALL_DIR}/requirements.txt" ]; then
  sudo -u administrador "$VENV_PIP" install -r "${INSTALL_DIR}/requirements.txt"
fi

ensure_pam_in_venv_for_path "$VENV_DIR" administrador

echo "==> Reiniciando servico..."
systemctl restart raspberry-pi-manager

echo "==> Teste final:"
sudo -u administrador "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None)); print('OK')"

echo "Pronto. Teste: curl -s http://127.0.0.1:5000/api/health | python3 -m json.tool"
