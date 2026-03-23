"""
Lista segura de caminhos para executar update_app.sh (webhook / hardening).
"""
from __future__ import annotations

import os


def is_allowed_update_script(path: str, *, app_root_path: str) -> bool:
    """
    Evita executar bash em caminho arbitrário.
    O ficheiro tem de se chamar update_app.sh e estar sob uma raiz conhecida.
    """
    try:
        rp = os.path.realpath(path)
    except OSError:
        return False
    if os.path.basename(rp) != "update_app.sh":
        return False
    candidates: list[str] = [
        app_root_path,
        os.path.abspath(os.path.join(app_root_path, "..")),
        "/home/administrador/raspberry-pi-manager",
        "/opt/raspberry-pi-manager",
    ]
    for _key in ("APP_INSTALL_DIR", "PI_MANAGER_INSTALL_DIR"):
        _dir = os.environ.get(_key, "").strip()
        if _dir:
            candidates.append(_dir)
    for c in candidates:
        try:
            root = os.path.realpath(c)
        except OSError:
            continue
        if rp == root or rp.startswith(root + os.sep):
            return True
    return False
