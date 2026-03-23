"""Garante que `src/` está no path para importar `app` e `lib`."""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Evita startup_tasks() (sleeps, threads) ao importar app.py durante os testes
os.environ.setdefault("SKIP_STARTUP_TASKS", "1")

_ROOT = Path(__file__).resolve().parent.parent
_SRC = _ROOT / "src"
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))
