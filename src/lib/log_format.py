"""
Formatação opcional de logs sem emoji (journalctl / terminais ASCII).
Ativar: PI_MANAGER_ASCII_LOGS=true
"""
from __future__ import annotations

import os

_EMOJI_ASCII_MAP: tuple[tuple[str, str], ...] = (
    ("✅", "[OK]"),
    ("❌", "[ERR]"),
    ("⚠️", "[WARN]"),
    ("🔄", "[..]"),
    ("📁", "[dir]"),
    ("🔍", "[?]"),
    ("📖", "[i]"),
    ("📭", "[ ]"),
    ("🧹", "[clean]"),
    ("🎯", "[>]"),
    ("🚀", "[go]"),
    ("📋", "[list]"),
    ("ℹ️", "[i]"),
    ("🗑️", "[del]"),
    ("⏰", "[time]"),
    ("⏳", "[wait]"),
    ("📝", "[cfg]"),
    ("🔒", "[lock]"),
    ("🌐", "[www]"),
    ("🔗", "[link]"),
    ("🟢", "[+]"),
    ("🔴", "[-]"),
    ("💾", "[mem]"),
    ("📶", "[wifi]"),
    ("🔌", "[eth]"),
    ("⊗", "[x]"),
    ("✓", "[v]"),
    ("▶", ">"),
    ("⏸", "||"),
    ("🎉", "[*]"),
    ("👋", "[bye]"),
    ("🖥️", "[pc]"),
    ("💡", "[tip]"),
    ("🔧", "[fix]"),
    ("📊", "[stat]"),
    ("🛠️", "[tool]"),
    ("🧪", "[test]"),
    ("📡", "[net]"),
    ("🖨️", "[prn]"),
    ("📂", "[dir]"),
    ("📄", "[doc]"),
    ("🐍", "[py]"),
    ("🔥", "[!]"),
    ("💿", "[disk]"),
    ("🎬", "[run]"),
    ("🏷️", "[ver]"),
    ("🧩", "[mod]"),
    ("🔐", "[key]"),
    ("📦", "[pkg]"),
    ("🧵", "[thr]"),
)


def ascii_logs_enabled() -> bool:
    return os.environ.get("PI_MANAGER_ASCII_LOGS", "").strip().lower() in ("1", "true", "yes", "on")


def format_log_line(msg: str) -> str:
    """Substitui emoji conhecidos por etiquetas ASCII; mensagens já ASCII mantêm-se."""
    if not ascii_logs_enabled() or not msg:
        return msg
    out = msg
    for em, rep in _EMOJI_ASCII_MAP:
        out = out.replace(em, rep)
    return out
