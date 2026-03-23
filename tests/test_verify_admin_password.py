"""Testes leves de verify_admin_password com PAM simulado (sem módulo real)."""
from __future__ import annotations

import pytest

# Importa app depois de conftest ajustar sys.path
import app as app_module


def test_verify_fails_without_pam(monkeypatch):
    monkeypatch.setattr(app_module, "get_pam_module", lambda: None)
    assert app_module.verify_admin_password("anything") is False


def test_verify_debian_style_pam(monkeypatch):
    """authenticate(user, password, service=...) devolve bool."""

    class DebianStylePam:
        @staticmethod
        def authenticate(user, password, service=None):
            return user == "administrador" and password == "correct" and service == "login"

    monkeypatch.setattr(app_module, "get_pam_module", lambda: DebianStylePam)
    monkeypatch.setattr(app_module, "ADMIN_USERNAME", "administrador")
    monkeypatch.setattr(app_module, "_pam_service_names", lambda: ["login"])

    assert app_module.verify_admin_password("correct") is True
    assert app_module.verify_admin_password("wrong") is False
