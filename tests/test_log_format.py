import os

from lib.log_format import ascii_logs_enabled, format_log_line


def test_format_passthrough_when_disabled(monkeypatch):
    monkeypatch.delenv("PI_MANAGER_ASCII_LOGS", raising=False)
    assert format_log_line("✅ ok") == "✅ ok"


def test_format_replaces_when_enabled(monkeypatch):
    monkeypatch.setenv("PI_MANAGER_ASCII_LOGS", "1")
    assert "[OK]" in format_log_line("✅ ok")
    assert "✅" not in format_log_line("✅ ok")


def test_ascii_logs_enabled(monkeypatch):
    monkeypatch.setenv("PI_MANAGER_ASCII_LOGS", "true")
    assert ascii_logs_enabled() is True
