#!/usr/bin/env bash
# Corrige login "PAM nao disponivel" no Raspberry Pi Manager.
#
# Contexto (APT vs pip vs venv):
# - python3-pam (apt) instala o modulo em site-packages DO SISTEMA.
# - Um venv e isolado por defeito: NAO ve esses pacotes salvo com --system-site-packages
#   ou pyvenv.cfg com include-system-site-packages = true.
# - python-pam (PyPI) e OUTRO pacote; no venv pode sombreiar/confundir o apt — removemos se existir.
#
# Uso no Raspberry (SSH): sudo bash scripts/fix-pam-on-pi.sh
#    ou: sudo INSTALL_DIR=/caminho/da/app bash scripts/fix-pam-on-pi.sh

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
VENV_DIR="${INSTALL_DIR}/venv"
VENV_PIP="${VENV_DIR}/bin/pip"
PYVENV_CFG="${VENV_DIR}/pyvenv.cfg"

echo "==> Instalando python3-pam (apt)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-pam

if [ -f "$PYVENV_CFG" ] && grep -q '^include-system-site-packages = false' "$PYVENV_CFG" 2>/dev/null; then
  echo "==> Ativando heranca de site-packages do sistema no venv (pyvenv.cfg)..."
  sed -i 's/^include-system-site-packages = false/include-system-site-packages = true/' "$PYVENV_CFG"
  echo "    Sem isto, o Python do venv nao ve o python3-pam do apt."
fi

if [ -x "$VENV_PIP" ]; then
  echo "==> Removendo pacote pip 'python-pam' do venv (se existir; mensagem 'Skipping' e normal)..."
  sudo -u administrador "$VENV_PIP" uninstall -y python-pam 2>/dev/null || true
  # Restos de diretorio quebrado
  rm -rf "${INSTALL_DIR}/venv/lib"/python3.*/site-packages/pam "${INSTALL_DIR}/venv/lib"/python3.*/site-packages/pam-*.dist-info 2>/dev/null || true
else
  echo "AVISO: venv nao encontrado em $VENV_PIP"
fi

echo "==> Reiniciando servico..."
systemctl restart raspberry-pi-manager

echo "==> Teste de import (deve imprimir OK):"
sudo -u administrador "${VENV_DIR}/bin/python" -c "import pam; assert callable(getattr(pam,'authenticate',None)); print('OK')"

echo "Pronto. Acesse de novo a pagina de login."
