#!/usr/bin/env bash
# Funções partilhadas: garantir `import pam` no venv (apt herdado ou pip python-pam + six).
#
# Uso (a partir de outro script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=scripts/lib-pam-venv.sh
#   source "$SCRIPT_DIR/lib-pam-venv.sh"
#   ensure_pam_in_venv_for_path "/caminho/venv" administrador
#
# Segundo argumento opcional: utilizador para sudo -u (ex.: administrador). Vazio = executar como utilizador atual.

ensure_pam_in_venv_for_path() {
  local VENV_DIR="${1:?venv dir}"
  local RUN_USER="${2:-}"
  local VENV_PY="${VENV_DIR}/bin/python"
  local VENV_PIP="${VENV_DIR}/bin/pip"

  if [ ! -x "$VENV_PY" ] || [ ! -x "$VENV_PIP" ]; then
    echo "ERRO: venv inválido (sem python/pip): $VENV_DIR" >&2
    return 1
  fi

  _pi_pam_py() {
    if [ -n "$RUN_USER" ]; then
      sudo -u "$RUN_USER" "$VENV_PY" "$@"
    else
      "$VENV_PY" "$@"
    fi
  }
  _pi_pam_pip() {
    if [ -n "$RUN_USER" ]; then
      sudo -u "$RUN_USER" "$VENV_PIP" "$@"
    else
      "$VENV_PIP" "$@"
    fi
  }

  if _pi_pam_py -c "import pam; assert callable(getattr(pam,'authenticate',None))" 2>/dev/null; then
    echo "==> PAM OK no venv (sistema/apt)."
    _pi_pam_pip uninstall -y python-pam 2>/dev/null || true
    if _pi_pam_py -c "import pam" 2>/dev/null; then
      return 0
    fi
    echo "==> pam sumiu após pip uninstall — a instalar python-pam (PyPI)."
  else
    echo "==> pam não importa no venv via apt."
  fi

  _pi_pam_pip install --no-cache-dir 'python-pam>=2.0.2' 'six>=1.16.0'
  if ! _pi_pam_py -c "import pam; assert callable(getattr(pam,'authenticate',None))" 2>/dev/null; then
    echo "ERRO: PAM continua indisponível após pip." >&2
    return 1
  fi
  echo "==> PAM OK via pip (python-pam)."
  return 0
}

pick_python_with_pam() {
  PICK_PAM_PY=""
  local cand
  for cand in python3.13 python3.12 python3.11 python3.10 python3.14 python3; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import pam" 2>/dev/null; then
      PICK_PAM_PY="$(command -v "$cand")"
      return 0
    fi
  done
  return 1
}
