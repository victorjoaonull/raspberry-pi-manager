#!/usr/bin/env bash
# Valida sintaxe do instalador (executar na raiz do repositório ou em CI).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/install.sh"
echo "✅ install.sh: sintaxe bash OK"
bash -n "$ROOT/uninstall.sh"
echo "✅ uninstall.sh: sintaxe bash OK"
bash -n "$ROOT/scripts/fix-pam-on-pi.sh"
echo "✅ scripts/fix-pam-on-pi.sh: sintaxe bash OK"
