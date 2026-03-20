#!/usr/bin/env bash
# Corrige login "PAM nao disponivel": remove wheel PyPI que sombreia python3-pam do apt.
# Uso no Raspberry (SSH): sudo bash scripts/fix-pam-on-pi.sh
#    ou, se ja estiver em /usr/local: copie o script e rode com sudo.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/home/administrador/raspberry-pi-manager}"
VENV_PIP="${INSTALL_DIR}/venv/bin/pip"

echo "==> Instalando python3-pam (apt)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-pam

if [ -x "$VENV_PIP" ]; then
  echo "==> Removendo pacote pip 'python-pam' do venv (se existir)..."
  sudo -u administrador "$VENV_PIP" uninstall -y python-pam 2>/dev/null || true
  # Restos de diretorio quebrado
  rm -rf "${INSTALL_DIR}/venv/lib"/python3.*/site-packages/pam "${INSTALL_DIR}/venv/lib"/python3.*/site-packages/pam-*.dist-info 2>/dev/null || true
else
  echo "AVISO: venv nao encontrado em $VENV_PIP"
fi

echo "==> Reiniciando servico..."
systemctl restart raspberry-pi-manager

echo "==> Teste de import (deve imprimir OK):"
sudo -u administrador "${INSTALL_DIR}/venv/bin/python" -c "import pam; assert callable(getattr(pam,'authenticate',None)); print('OK')"

echo "Pronto. Acesse de novo a pagina de login."
