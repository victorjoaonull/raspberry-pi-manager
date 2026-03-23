"""Validação e normalização de URLs para autostart (testável sem Flask)."""
from __future__ import annotations

import re
from urllib.parse import urlparse


def format_url(url: str) -> str:
    if not url.strip():
        return url
    if url.startswith(("http://", "https://")):
        return url
    if "://" not in url:
        return "http://" + url
    return url


def is_valid_url_or_ip(url: str) -> bool:
    url = url.strip()
    if not url:
        return True
    if url.startswith(("http://", "https://")):
        try:
            result = urlparse(url)
            return bool(result.scheme and result.netloc)
        except ValueError:
            return False
    ip_port_pattern = r"^(\d{1,3}\.){3}\d{1,3}:\d+$"
    if re.match(ip_port_pattern, url):
        ip_part = url.split(":")[0]
        port_part = url.split(":")[1]
        parts = ip_part.split(".")
        if len(parts) == 4:
            for part in parts:
                if not part.isdigit() or not 0 <= int(part) <= 255:
                    return False
            if port_part.isdigit() and 1 <= int(port_part) <= 65535:
                return True
        return False
    ip_pattern = r"^(\d{1,3}\.){3}\d{1,3}$"
    if re.match(ip_pattern, url):
        parts = url.split(".")
        if len(parts) == 4:
            for part in parts:
                if not part.isdigit() or not 0 <= int(part) <= 255:
                    return False
            return True
        return False
    hostname_port_pattern = r"^[a-zA-Z0-9][a-zA-Z0-9.-]*:\d+$"
    if re.match(hostname_port_pattern, url):
        port_part = url.split(":")[1]
        if port_part.isdigit() and 1 <= int(port_part) <= 65535:
            return True
    hostname_pattern = r"^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$"
    if re.match(hostname_pattern, url) or url == "localhost":
        return True
    return False
