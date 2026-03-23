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

INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
VENV_DIR="${INSTALL_DIR}/venv"
VENV_PY="${VENV_DIR}/bin/python"
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

ensure_pam_in_venv() {
  if sudo -u administrador "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None))" 2>/dev/null; then
    echo "==> PAM OK no venv (sistema/apt)."
    sudo -u administrador "$VENV_PIP" uninstall -y python-pam 2>/dev/null || true
    if sudo -u administrador "$VENV_PY" -c "import pam" 2>/dev/null; then
      return 0
    fi
    echo "==> pam sumiu apos pip uninstall — a instalar python-pam (PyPI)."
  else
    echo "==> pam nao importa no venv via apt."
  fi
  sudo -u administrador "$VENV_PIP" install --no-cache-dir 'python-pam>=2.0.2'
  sudo -u administrador "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None))"
  echo "==> PAM OK via pip (python-pam)."
}

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
  # Sem pam no venv: recriar com o melhor Python disponivel (ou mesmo python3)
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

ensure_pam_in_venv

echo "==> Reiniciando servico..."
systemctl restart raspberry-pi-manager

echo "==> Teste final:"
sudo -u administrador "$VENV_PY" -c "import pam; assert callable(getattr(pam,'authenticate',None)); print('OK')"

echo "Pronto. Teste: curl -s http://127.0.0.1:5000/api/health | python3 -m json.tool"
