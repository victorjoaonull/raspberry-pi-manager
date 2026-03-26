#!/usr/bin/env python3
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from urllib.parse import urlparse
import subprocess
import os
import sys
import glob
import json
import re
import threading
import time
import shutil
import hashlib
import signal
from pathlib import Path
from datetime import datetime
from collections import deque
from typing import Optional

try:
    import fcntl
except ImportError:
    fcntl = None  # type: ignore[assignment, misc]
import hmac
import secrets
import traceback

from lib.log_format import format_log_line
from lib.update_allowlist import is_allowed_update_script as _is_allowed_update_script_lib
from lib.url_utils import format_url, is_valid_url_or_ip

# Autenticação via PAM (senha real do Linux do usuário `administrador`).
# Preferir SEMPRE o pacote Debian python3-pam (venv com --system-site-packages).
# O wheel PyPI "python-pam" no site-packages do venv costuma sombrear o apt e falhar no import (ex.: Python 3.13).
_PAM_IMPORT_ERROR: Optional[Exception] = None


def _inject_debian_dist_packages_into_syspath() -> None:
    """
    Em venv no Debian Trixie/Bookworm, às vezes `python3-pam` (apt) não aparece no sys.path
    mesmo com --system-site-packages → ModuleNotFoundError: pam. Coloca dist-packages do
    sistema no *final* do path (Flask etc. do venv continuam prioritários).
    """
    vers = f"{sys.version_info.major}.{sys.version_info.minor}"
    for p in (
        f"/usr/lib/python{vers}/dist-packages",
        "/usr/lib/python3/dist-packages",
    ):
        if os.path.isdir(p) and p not in sys.path:
            sys.path.append(p)


def _load_pam_module():
    global _PAM_IMPORT_ERROR
    _inject_debian_dist_packages_into_syspath()
    try:
        import pam as m  # type: ignore

        if getattr(m, "authenticate", None) is None:
            raise ImportError("módulo pam sem authenticate")
        _PAM_IMPORT_ERROR = None
        return m
    except Exception as e:
        _PAM_IMPORT_ERROR = e
    # Fallback: carregar o pacote do apt diretamente (se o venv tiver um pam quebrado)
    try:
        import importlib.util

        # Caminhos dinâmicos (ex.: Python 3.11 no Bookworm, 3.13 no Trixie)
        fallback_paths = sorted(
            glob.glob("/usr/lib/python3.*/dist-packages/pam/__init__.py"),
            reverse=True,
        )
        for pkg in (
            *fallback_paths,
            "/usr/lib/python3/dist-packages/pam/__init__.py",
        ):
            if not os.path.isfile(pkg):
                continue
            spec = importlib.util.spec_from_file_location("_pi_manager_pam_apt", pkg)
            if spec is None or spec.loader is None:
                continue
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            if getattr(mod, "authenticate", None) is not None:
                _PAM_IMPORT_ERROR = None
                return mod
    except Exception as e2:
        _PAM_IMPORT_ERROR = e2
    return None


pam_module = _load_pam_module()
_PAM_RETRY_DONE = False


def get_pam_module():
    """
    Retorna o módulo pam. Se o arranque falhou, tenta uma vez limpar o cache de import
    (útil após `pip uninstall python-pam` sem reiniciar o serviço).
    """
    global pam_module, _PAM_IMPORT_ERROR, _PAM_RETRY_DONE
    if pam_module is not None:
        return pam_module
    if not _PAM_RETRY_DONE:
        _PAM_RETRY_DONE = True
        for k in list(sys.modules.keys()):
            if k == "pam" or k.startswith("pam."):
                del sys.modules[k]
        pam_module = _load_pam_module()
        if pam_module is None:
            print(f"⚠️ Nova tentativa de carregar PAM falhou: {_PAM_IMPORT_ERROR!r}")
    return pam_module


# Utilizador Linux cuja senha é validada por PAM (pode mudar em instalações não padrão)
ADMIN_USERNAME = (os.environ.get("PI_MANAGER_PAM_USER") or "administrador").strip() or "administrador"


def _pam_service_names() -> list[str]:
    """Serviços PAM a tentar (ordem). Override: PI_MANAGER_PAM_SERVICES=login,su,sudo"""
    raw = (os.environ.get("PI_MANAGER_PAM_SERVICES") or "").strip()
    if raw:
        return [s.strip() for s in raw.split(",") if s.strip()]
    return ["login", "sshd", "su", "sudo"]


# Versão da Aplicação
APP_VERSION = "2.5.4"

app = Flask(__name__)
# JSON com caracteres Unicode legíveis nos endpoints (Flask 2.2+)
try:
    app.json.ensure_ascii = False  # type: ignore[attr-defined]
except Exception:
    pass
# Cookies de sessão (opcional via env em produção com HTTPS)
if os.environ.get("SESSION_COOKIE_SECURE", "").lower() in ("1", "true", "yes"):
    app.config["SESSION_COOKIE_SECURE"] = True
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = os.environ.get("SESSION_COOKIE_SAMESITE", "Lax")
# Secret para sessões: definir FLASK_SECRET_KEY em /etc/default/... (install.sh gera se faltar).
# Sem chave persistente, sessões invalidam a cada restart do processo.
app.secret_key = os.environ.get("FLASK_SECRET_KEY")
if not app.secret_key:
    app.secret_key = os.urandom(32)
    print(
        "⚠️ FLASK_SECRET_KEY não definida; usando chave temporária (sessões expiram após reinício). "
        "Defina FLASK_SECRET_KEY no EnvironmentFile do systemd (ex.: install.sh ou /etc/default/raspberry-pi-manager)."
    )

if pam_module is None:
    print(
        "⚠️ AVISO raspberry-pi-manager: PAM indisponível — login por senha Linux não funcionará. "
        f"Causa: {_PAM_IMPORT_ERROR!r}"
    )


# Força UTF-8 no Content-Type (substitui charset errado de proxy/nginx, ex.: iso-8859-1).
@app.after_request
def _ensure_utf8_charset(response):
    ct = response.headers.get("Content-Type", "")
    if not ct:
        return response
    base = ct.split(";")[0].strip().lower()
    if base == "text/html":
        response.headers["Content-Type"] = "text/html; charset=utf-8"
    elif base == "application/json":
        response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response



# Pequeno log de eventos em memória para mostrar no dashboard
EVENT_LOG = deque(maxlen=200)

def add_event(msg):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    entry = f"[{ts}] {format_log_line(msg)}"
    try:
        EVENT_LOG.appendleft(entry)
    except Exception:
        pass
    print(entry)

# Caminho para o wrapper criado pelo instalador
NMCLI_WRAPPER = '/usr/local/bin/pi-manager-nmcli'
CHPASS_WRAPPER = '/usr/local/bin/pi-manager-chpasswd'
HOSTNAME_WRAPPER = '/usr/local/bin/pi-manager-hostname'
CHROMIUM_LOCKS_WRAPPER = '/usr/local/bin/pi-manager-chromium-clean-locks'
POWER_WRAPPER = '/usr/local/bin/pi-manager-power'
# Política mínima de senha (UI e API alinhadas)
MIN_PASSWORD_LENGTH = 8

def run_nmcli(args, capture_output=True, text=True, timeout=None):
    """Executa nmcli via wrapper seguro, com fallback para nmcli puro se necessário."""
    # cmd via wrapper (sudoers permite execução sem senha do wrapper)
    cmd = ['sudo', NMCLI_WRAPPER] + args
    try:
        return subprocess.run(cmd, capture_output=capture_output, text=text, timeout=timeout)
    except FileNotFoundError:
        # Fallback: tente chamar nmcli diretamente
        try:
            fb_cmd = ['sudo', 'nmcli'] + args
            return subprocess.run(fb_cmd, capture_output=capture_output, text=text, timeout=timeout)
        except Exception as e:
            raise

def run_chpasswd(user, password, capture_output=True, text=True, timeout=None):
    """Executa o wrapper seguro para alterar senha via stdin."""
    cmd = ['sudo', CHPASS_WRAPPER]
    inp = f"{user}:{password}\n"
    return subprocess.run(cmd, input=inp, capture_output=capture_output, text=text, timeout=timeout)

def run_hostname(new_hostname, capture_output=True, text=True, timeout=10):
    """Call the hostname wrapper to set persistent hostname."""
    cmd = ['sudo', HOSTNAME_WRAPPER, new_hostname]
    try:
        return subprocess.run(cmd, capture_output=capture_output, text=text, timeout=timeout)
    except FileNotFoundError:
        # Wrapper missing -> attempt direct call (may require password and fail)
        try:
            return subprocess.run(['sudo', 'hostnamectl', 'set-hostname', new_hostname], capture_output=capture_output, text=text, timeout=timeout)
        except Exception as e:
            raise

def run_power(action: str, capture_output=True, text=True, timeout=30):
    """
    Reinício/desligamento via wrapper com subcomandos fixos (sudoers).
    action: reboot-now, halt-now, reboot-1, halt-1
    """
    valid = frozenset({"reboot-now", "halt-now", "reboot-1", "halt-1"})
    if action not in valid:
        raise ValueError(f"acao de energia invalida: {action!r}")
    if os.path.isfile(POWER_WRAPPER) and os.access(POWER_WRAPPER, os.X_OK):
        return subprocess.run(
            ["sudo", "-n", POWER_WRAPPER, action],
            capture_output=capture_output,
            text=text,
            timeout=timeout,
        )
    fallback_map = {
        "reboot-now": ["shutdown", "-r", "now"],
        "halt-now": ["shutdown", "-h", "now"],
        "reboot-1": ["shutdown", "-r", "+1"],
        "halt-1": ["shutdown", "-h", "+1"],
    }
    return subprocess.run(
        ["sudo"] + fallback_map[action],
        capture_output=capture_output,
        text=text,
        timeout=timeout,
    )

# Configurações — sempre relativas à pasta de app.py (INSTALL_DIR na instalação, src/ em dev)
_APP_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = os.path.join(_APP_DIR, "config")
NETWORK_CONFIG = os.path.join(CONFIG_DIR, "network.conf")
AUTOSTART_CONFIG = os.path.join(CONFIG_DIR, "autostart.conf")
_LOG_OVERRIDE = os.environ.get("PI_MANAGER_LOG_DIR", "").strip()
LOG_DIR = _LOG_OVERRIDE if _LOG_OVERRIDE else os.path.join(_APP_DIR, "logs")
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(CONFIG_DIR, exist_ok=True)
BROWSER_LOG = os.path.join(LOG_DIR, "browser-launch.log")

# Perfil Chromium (autostart, favoritos, locks). Override: PI_MANAGER_CHROMIUM_USER_DATA_DIR
_DEFAULT_CHROMIUM_USER_DATA_DIR = "/home/administrador/chromium-profile"
_CHROMIUM_UDD_OVERRIDE = os.environ.get("PI_MANAGER_CHROMIUM_USER_DATA_DIR", "").strip()
CHROMIUM_USER_DATA_DIR = (
    os.path.normpath(os.path.abspath(os.path.expanduser(_CHROMIUM_UDD_OVERRIDE)))
    if _CHROMIUM_UDD_OVERRIDE
    else _DEFAULT_CHROMIUM_USER_DATA_DIR
)

# Evita duas threads/processos a lançarem Chromium em simultâneo (startup_tasks + reload).
_CHROMIUM_LAUNCH_LOCK_PATH = os.environ.get(
    "PI_MANAGER_CHROMIUM_LAUNCH_LOCK",
    os.path.join(os.getenv("XDG_RUNTIME_DIR") or "/tmp", "pi-manager-chromium-launch.lock"),
)


def _chromium_managed_cmdline_regex() -> str:
    """
    Padrão ERE para pgrep/pkill -f: restringe ao Chromium que usa o perfil gerido
    (--user-data-dir), evitando afetar outras instâncias.
    """
    return "--user-data-dir=" + re.escape(str(CHROMIUM_USER_DATA_DIR))


def _pgrep_managed_args() -> list:
    """pgrep -f com -- antes do padrão (padrões que começam por -- são senão tratados como opções)."""
    return ["pgrep", "-f", "--", _chromium_managed_cmdline_regex()]


def _pkill_managed_args(sig: str) -> list:
    """pkill com -- antes do padrão (evita ambiguidade com --user-data-dir=...)."""
    return ["sudo", "pkill", sig, "-f", "--", _chromium_managed_cmdline_regex()]


def _try_acquire_chromium_launch_lock() -> Optional[int]:
    """
    Lock não bloqueante. None = já existe outro lançamento em curso.
    -1 = lock desativado (sem fcntl ou PI_MANAGER_SKIP_CHROMIUM_LAUNCH_LOCK).
    """
    if os.environ.get("PI_MANAGER_SKIP_CHROMIUM_LAUNCH_LOCK", "").lower() in ("1", "true", "yes"):
        return -1
    if fcntl is None:
        return -1
    try:
        fd = os.open(_CHROMIUM_LAUNCH_LOCK_PATH, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as e:
        _log_unexpected(e, "_try_acquire_chromium_launch_lock open")
        return -1
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BlockingIOError:
        pass
    except OSError as e:
        _log_unexpected(e, "_try_acquire_chromium_launch_lock flock")
    try:
        os.close(fd)
    except OSError:
        pass
    return None


def _release_chromium_launch_lock(fd: Optional[int]) -> None:
    if fd is None or fd < 0:
        return
    if fcntl is None:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass


def _log_unexpected(exc: BaseException, where: str) -> None:
    """Log de exceções inesperadas quando PI_MANAGER_DEBUG_TRACEBACK está ativo."""
    if os.environ.get("PI_MANAGER_DEBUG_TRACEBACK", "").lower() in ("1", "true", "yes"):
        print(f"⚠️ [{where}] {exc!r}", flush=True)
        traceback.print_exc()


from lib.chromium_favorites import ChromiumFavoritesManager

# Gerenciador de favoritos (implementação em lib/chromium_favorites.py)
favorites_manager = ChromiumFavoritesManager(
    username=ADMIN_USERNAME,
    chromium_user_data_dir=str(CHROMIUM_USER_DATA_DIR),
)

# ========== FUNÇÕES AUXILIARES ==========
def check_auth():
    auth = session.get('authenticated')
    if os.environ.get('DEBUG_AUTH', '').lower() == 'true':
        print(f"DEBUG check_auth: authenticated={auth}", flush=True)
    return auth


def _diagnostics_enabled() -> bool:
    """
    /api/diagnostic/* e /api/favorites/diagnostic só respondem se PI_MANAGER_DIAGNOSTICS=true
    ou se Flask estiver em debug (desenvolvimento). Por omissão: desligado em produção.
    """
    raw = (os.environ.get("PI_MANAGER_DIAGNOSTICS") or "").strip().lower()
    if raw in ("1", "true", "yes", "on"):
        return True
    if raw in ("0", "false", "no", "off"):
        return False
    return bool(app.debug)


def _require_diagnostics_json():
    """Retorna resposta 404 mínima se diagnóstico não permitido; senão None."""
    if not _diagnostics_enabled():
        return jsonify({"ok": False}), 404
    return None


def _client_ip_for_rate_limit() -> str:
    """IP do cliente; opcionalmente X-Forwarded-For se PI_MANAGER_TRUST_PROXY estiver ativo."""
    if os.environ.get("PI_MANAGER_TRUST_PROXY", "").lower() in ("1", "true", "yes"):
        xff = (request.headers.get("X-Forwarded-For") or "").strip()
        if xff:
            return xff.split(",")[0].strip() or "unknown"
    return (request.remote_addr or "").strip() or "unknown"


_login_rate_lock = threading.Lock()
# ip -> {"until": float, "fails": list[float]}
_login_attempt_state: dict[str, dict] = {}


def _login_rate_limit_config() -> tuple[bool, int, float, float]:
    """
    Retorna (ativo, max_falhas_na_janela, janela_seg, lockout_seg).
    PI_MANAGER_LOGIN_RATE_LIMIT=0 desliga. max_falhas <= 0 desliga.
    """
    if os.environ.get("PI_MANAGER_LOGIN_RATE_LIMIT", "1").lower() in ("0", "false", "no", "off"):
        return False, 0, 900.0, 600.0
    try:
        max_fails = int(os.environ.get("PI_MANAGER_LOGIN_MAX_FAILS", "8"))
    except ValueError:
        max_fails = 8
    try:
        window = float(os.environ.get("PI_MANAGER_LOGIN_WINDOW_SEC", "900"))
    except ValueError:
        window = 900.0
    try:
        lockout = float(os.environ.get("PI_MANAGER_LOGIN_LOCKOUT_SEC", "600"))
    except ValueError:
        lockout = 600.0
    if max_fails <= 0:
        return False, 0, window, lockout
    return True, max_fails, window, lockout


def _login_rate_limited_response():
    """Se o IP está em lockout, retorna (template_html, status); senão None."""
    enabled, _, _, _ = _login_rate_limit_config()
    if not enabled:
        return None
    ip = _client_ip_for_rate_limit()
    now = time.time()
    with _login_rate_lock:
        st = _login_attempt_state.get(ip)
        if not st:
            return None
        until = float(st.get("until") or 0)
        if now < until:
            wait_s = max(1, int(until - now) + 1)
            return (
                render_template(
                    "login.html",
                    error=(
                        f"Muitas tentativas de login. Aguarde cerca de {wait_s} segundos "
                        "antes de tentar novamente."
                    ),
                ),
                429,
            )
    return None


def _login_record_auth_failure() -> None:
    """Regista falha de palavra-passe (não chamar para erro CSRF ou PAM indisponível)."""
    enabled, max_fails, window_sec, lockout_sec = _login_rate_limit_config()
    if not enabled:
        return
    ip = _client_ip_for_rate_limit()
    now = time.time()
    with _login_rate_lock:
        st = _login_attempt_state.setdefault(ip, {"until": 0.0, "fails": []})
        until = float(st.get("until") or 0)
        if now < until:
            return
        fails: list = st.setdefault("fails", [])
        fails.append(now)
        st["fails"] = [t for t in fails if now - t < window_sec]
        if len(st["fails"]) >= max_fails:
            st["until"] = now + lockout_sec
            st["fails"] = []


def _login_clear_rate_limit() -> None:
    with _login_rate_lock:
        _login_attempt_state.pop(_client_ip_for_rate_limit(), None)


def _is_safe_nm_connection_name(name: str) -> bool:
    """Evita injeção de argumentos / metacaracteres em nmcli via nome na URL."""
    if not name or len(name) > 256:
        return False
    forbidden = set(';|&$`<>\\"\n\r\t\x00')
    if any(c in forbidden for c in name):
        return False
    if name.startswith((".", "/")) or ".." in name:
        return False
    return True


@app.before_request
def _csrf_middleware():
    path = request.path or ""
    if path.startswith("/static"):
        return None

    if request.endpoint == "login" and request.method == "GET":
        if not session.get("_csrf_token"):
            session["_csrf_token"] = secrets.token_hex(32)
            session.modified = True
        return None

    if session.get("authenticated") and not session.get("_csrf_token"):
        session["_csrf_token"] = secrets.token_hex(32)
        session.modified = True

    if request.method not in ("POST", "PUT", "PATCH", "DELETE"):
        return None

    if path.startswith("/webhook"):
        return None
    if path == "/api/health":
        return None

    if path == "/login" and request.method == "POST":
        if session.get("authenticated"):
            return None
        tok = session.get("_csrf_token")
        sent = request.form.get("csrf_token") if request.form else None
        if not tok or not sent or not hmac.compare_digest(str(sent), str(tok)):
            return (
                render_template(
                    "login.html",
                    error="Pedido invalido (CSRF). Atualize a pagina e tente de novo.",
                ),
                403,
            )
        return None

    if path.startswith("/api/") and check_auth():
        tok = session.get("_csrf_token")
        if not tok:
            return jsonify({"error": "CSRF: faca login novamente ou recarregue a pagina."}), 403
        sent = request.headers.get("X-CSRF-Token") or request.headers.get("X-XSRF-Token")
        if not sent or not hmac.compare_digest(str(sent), str(tok)):
            return jsonify({"error": "Token CSRF invalido ou ausente. Recarregue a pagina."}), 403

    return None


def get_cpu_usage():
    try:
        with open('/proc/stat', 'r') as f:
            lines = f.readlines()
        for line in lines:
            if line.startswith('cpu '):
                parts = line.split()
                user = int(parts[1]); nice = int(parts[2]); system = int(parts[3])
                idle = int(parts[4]); iowait = int(parts[5]); irq = int(parts[6]); softirq = int(parts[7])
                total = user + nice + system + idle + iowait + irq + softirq
                used = total - idle
                if total > 0:
                    usage_percent = (used / total) * 100
                    return f"{usage_percent:.1f}%"
        return "N/A"
    except Exception as e:
        print(f"Erro ao obter uso de CPU: {e}")
        return "N/A"

def get_memory_usage():
    try:
        with open('/proc/meminfo', 'r') as f:
            lines = f.readlines()
        mem_total = 0; mem_available = 0
        for line in lines:
            if line.startswith('MemTotal:'):
                mem_total = int(line.split()[1])
            elif line.startswith('MemAvailable:'):
                mem_available = int(line.split()[1])
        if mem_total > 0 and mem_available > 0:
            mem_used = mem_total - mem_available
            mem_used_mb = mem_used // 1024
            mem_total_mb = mem_total // 1024
            percentage = (mem_used / mem_total) * 100
            return f"{mem_used_mb}MB/{mem_total_mb}MB ({percentage:.1f}%)"
        return "N/A"
    except Exception as e:
        print(f"Erro ao obter uso de memória: {e}")
        return "N/A"

def load_autostart_urls():
    """
    Lê autostart.conf: ignora linhas vazias e comentários (# ...).
    Devolve URLs já normalizadas com format_url e validadas com is_valid_url_or_ip.
    """
    try:
        if not os.path.exists(AUTOSTART_CONFIG):
            print(format_log_line("📭 Arquivo autostart.conf não encontrado ou vazio"))
            return []
        with open(AUTOSTART_CONFIG, "r", encoding="utf-8", errors="replace") as f:
            candidates: list[str] = []
            for line in f:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                candidates.append(s)
        urls: list[str] = []
        for item in candidates:
            fu = format_url(item)
            if is_valid_url_or_ip(fu):
                urls.append(fu)
            else:
                print(
                    format_log_line(
                        f"⚠️ autostart.conf: linha ignorada (URL inválida): {item[:80]!r}"
                    )
                )
        print(format_log_line(f"📋 URLs carregadas do autostart.conf: {urls}"))
        return urls
    except Exception as e:
        print(f"Erro ao carregar URLs: {e}")
        return []


def _pam_call_returns_bool(auth_fn, *args, **kwargs) -> Optional[bool]:
    """
    Chama pam.authenticate.
    True = autenticado, False = falha explícita, None = TypeError (assinatura não suporta estes args).
    Excepções PAM/outras → False.
    """
    try:
        result = auth_fn(*args, **kwargs)
    except TypeError:
        return None
    except Exception:
        return False
    if result is False:
        return False
    if result is True:
        return True
    # Alguns bindings devolvem None ou outro valor em sucesso sem excepção
    return True


def verify_admin_password(password: str) -> bool:
    """
    Verifica a senha REAL do utilizador Linux (ADMIN_USERNAME / PI_MANAGER_PAM_USER) via PAM.
    Compatível com python3-pam (Debian: costuma devolver True/False) e python-pam (PyPI 2.x).
    """
    mod = get_pam_module()
    if mod is None:
        return False

    auth_fn = getattr(mod, "authenticate", None)
    if not callable(auth_fn):
        return False

    user = ADMIN_USERNAME
    services = _pam_service_names()

    # PyPI python-pam 2.x: authenticate() sem args → objeto com .authenticate(user, pwd, ...)
    ctx = None
    try:
        ctx = auth_fn()
    except TypeError:
        ctx = None
    except Exception:
        ctx = None

    if ctx is not None and hasattr(ctx, "authenticate"):
        inner = getattr(ctx, "authenticate", None)
        if callable(inner):
            for service in services:
                r = _pam_call_returns_bool(inner, user, password, service=service)
                if r is None:
                    break
                if r is True:
                    return True
            r2 = _pam_call_returns_bool(inner, user, password)
            return r2 is True

    # Debian python3-pam: authenticate(user, password, service=...) → True/False ou só excepções
    for service in services:
        r = _pam_call_returns_bool(auth_fn, user, password, service=service)
        if r is None:
            break
        if r is True:
            return True

    r = _pam_call_returns_bool(auth_fn, user, password)
    return r is True

def sync_chromium_favorites():
    """Sincroniza os favoritos do Chromium com as URLs configuradas em TODOS os perfis"""
    try:
        urls = load_autostart_urls()
        if not urls:
            add_event("ℹ️ Nenhuma URL configurada para sincronizar favoritos")
            return False, "Nenhuma URL configurada"
        
        # load_autostart_urls já devolve URLs formatadas e válidas
        formatted_urls = [u for u in urls if u.strip()]
        add_event(f"🔄 URLs para sincronizar: {formatted_urls}")
        
        # Sincroniza em TODOS os perfis
        success, message = favorites_manager.sync_to_all_profiles(formatted_urls)
        
        if success:
            add_event(f"✅ Favoritos sincronizados em todos os perfis")
        else:
            add_event(f"⚠️ Aviso: {message}")
        
        return success, message
        
    except Exception as e:
        _log_unexpected(e, "sync_chromium_favorites")
        add_event(f"❌ Erro na sincronização de favoritos: {e}")
        return False, str(e)

def _remove_chromium_singleton_files() -> None:
    """
    Preferir wrapper do instalador (sudoers NOPASSWD). Senão tenta find+rm como root
    (só funciona se administrador tiver sudo genérico).
    """
    if os.path.isfile(CHROMIUM_LOCKS_WRAPPER) and os.access(CHROMIUM_LOCKS_WRAPPER, os.X_OK):
        subprocess.run(
            ["sudo", "-n", CHROMIUM_LOCKS_WRAPPER],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=90,
        )
        return
    _sudo_rm_chromium_singleton_artifacts(CHROMIUM_USER_DATA_DIR)
    _sudo_rm_chromium_singleton_artifacts("/home/administrador/.config/chromium")
    _sudo_rm_chromium_singleton_artifacts("/home/administrador/.cache/chromium")


def _sudo_rm_chromium_singleton_artifacts(base_dir: str, max_depth: str = "4") -> None:
    """
    Apaga Singleton* e .com.google.Chrome* com rm como root.
    Ficheiros criados por `sudo chromium` (sem -u) pertencem a root e o utilizador
    da app não consegue apagar — daí locks 'fantasma' e find ainda a listar ficheiros.
    """
    if not base_dir or not os.path.isdir(base_dir):
        return
    try:
        subprocess.run(
            [
                "sudo",
                "find",
                base_dir,
                "-maxdepth",
                max_depth,
                "(",
                "-name",
                "Singleton*",
                "-o",
                "-name",
                ".com.google.Chrome*",
                ")",
                "-exec",
                "rm",
                "-f",
                "{}",
                ";",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as e:
        _log_unexpected(e, "_remove_chromium_singleton_files")


def cleanup_chromium_locks():
    """
    Remove todos os arquivos de lock do Chromium para evitar conflitos de hostname.
    Deve ser chamada após alterar o hostname e antes de iniciar o browser.
    """
    try:
        add_event("🧹 Iniciando limpeza de locks do Chromium...")
        
        profile_dir = CHROMIUM_USER_DATA_DIR
        use_wrapper = os.path.isfile(CHROMIUM_LOCKS_WRAPPER) and os.access(
            CHROMIUM_LOCKS_WRAPPER, os.X_OK
        )
        # 1. Sem wrapper: tenta pkill (só funciona se sudo o permitir). Com wrapper, o pkill é feito lá como root.
        if not use_wrapper:
            subprocess.run(
                _pkill_managed_args("-9"),
                stderr=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
            )
            time.sleep(1.5)

        # 2–4. Remoção de Singleton* (wrapper sudoers inclui pkill+rm, ou fallback)
        _remove_chromium_singleton_files()
        if use_wrapper:
            time.sleep(0.5)
        
        # 5. Verifica se ainda existem locks residuais (agora sem capture_output)
        try:
            check = subprocess.run([
                'sudo', '-u', 'administrador',
                'find',
                profile_dir,
                '(', '-name', "Singleton*", '-o', '-name', ".com.google.Chrome*",
                ')'
            ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
            
            if check.stdout and check.stdout.strip():
                add_event(f"⚠️ Aviso: locks residuais encontrados: {check.stdout.strip()[:200]}...")
            else:
                add_event("✅ Todos os locks do Chromium foram removidos")
        except Exception:
            add_event("✅ Verificação de locks concluída")
            
        add_event("🧹 Limpeza do Chromium finalizada")
        return True
        
    except Exception as e:
        _log_unexpected(e, "cleanup_chromium_locks")
        add_event(f"❌ Erro ao limpar locks do Chromium: {e}")
        # Não levanta exceção - apenas loga e continua
        return False

def _read_log_tail(path: str, max_chars: int = 2000) -> str:
    try:
        if not os.path.exists(path):
            return ""
        # Lê de trás para frente (via seek) sem precisar carregar o arquivo inteiro.
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            seek_back = max(size - (max_chars * 4), 0)
            f.seek(seek_back)
            data = f.read()
            return data[-max_chars:]
    except Exception:
        return ""


def _chromium_probable_singleton_issue(log_text: str) -> bool:
    if not log_text:
        return False
    text = log_text.lower()
    # Palavras típicas de erro de Singleton nos logs do Chromium.
    keywords = [
        "singletonlock",
        "singletonsocket",
        "another instance of chromium",
        "another instance is running",
        "chromium is already running",
        "singleton",
        ".com.google.chrome",
    ]
    return any(k in text for k in keywords)


def _chromium_is_running() -> bool:
    try:
        r = subprocess.run(
            _pgrep_managed_args(),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        return bool(r.stdout and r.stdout.strip())
    except (OSError, subprocess.SubprocessError) as e:
        _log_unexpected(e, "_chromium_is_running")
        return False


def _chromium_managed_profile_running() -> bool:
    """
    True se já existe processo Chromium usando o perfil gerido (CHROMIUM_USER_DATA_DIR).
    Evita segunda abertura no boot (ex.: autostart legado + serviço) e evita cleanup de locks
    com o browser aberto.
    """
    try:
        r = subprocess.run(
            _pgrep_managed_args(),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        return r.returncode == 0 and bool(r.stdout and r.stdout.strip())
    except (OSError, subprocess.SubprocessError) as e:
        _log_unexpected(e, "_chromium_managed_profile_running")
        return False


def _popen_chromium_logged(cmd: list, log_label: str):
    """Inicia Chromium com stdout/stderr no browser-launch.log. Retorna (process, fh ou None)."""
    fh = None
    try:
        fh = open(BROWSER_LOG, "a", encoding="utf-8", errors="replace")
        fh.write(f"\n[{datetime.now().isoformat()}] {log_label} cmd: {' '.join(cmd)}\n")
    except Exception:
        fh = None
    proc = subprocess.Popen(
        cmd,
        stdout=fh if fh else subprocess.DEVNULL,
        stderr=fh if fh else subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
    )
    return proc, fh


def open_browser_with_urls():
    """
    Abre o Chromium uma vez com as URLs de autostart.conf (via systemd → Flask → thread).

    Fluxo de boot: após o serviço subir, startup_tasks() espera ~5s e dispara esta função;
    aqui aguardamos mais ~10s para X11 (:0) e sessão gráfica estabilizarem, depois:
    - se o perfil gerenciado já estiver em uso → não relança nem limpa locks (fica estável);
    - senão → limpa locks, sincroniza favoritos, inicia Chromium com as URLs.

    Lock em ficheiro (fcntl) evita duas threads a lançarem em simultâneo (ex.: reload do Flask).
    """
    _lk = _try_acquire_chromium_launch_lock()
    if _lk is None:
        add_event(
            "ℹ️ Outro lançamento do Chromium já está em curso (lock em "
            f"{_CHROMIUM_LAUNCH_LOCK_PATH}). A ignorar esta chamada."
        )
        return

    try:
        time.sleep(10)  # Aguarda X11 / autologin / display :0

        urls = load_autostart_urls()
        if not urls:
            add_event("ℹ️ Nenhuma URL configurada no autostart.conf — sem abrir browser")
            return

        if _chromium_managed_profile_running():
            add_event(
                "ℹ️ Chromium já está em execução com o perfil gerenciado "
                f"({CHROMIUM_USER_DATA_DIR}). Pulando nova abertura e limpeza de locks."
            )
            add_event("🔄 Sincronizando favoritos (instância já aberta)...")
            success, message = sync_chromium_favorites()
            add_event(f"📋 Resultado da sincronização: {message}")
            return

        # 1. Limpeza de locks só quando vamos abrir nós mesmos (evita derrubar instância ativa)
        add_event("🧹 Executando limpeza preventiva de locks...")
        cleanup_chromium_locks()

        # 2. Favoritos alinhados ao autostart.conf antes das abas
        add_event("🔄 Sincronizando favoritos antes de abrir browser...")
        success, message = sync_chromium_favorites()
        add_event(f"📋 Resultado da sincronização: {message}")

        add_event(f"🎯 Abrindo {len(urls)} URLs no browser...")
        
        # 4. Verifica se o display está disponível
        display_check = subprocess.run(['sudo', '-u', 'administrador', 'env', 'DISPLAY=:0', 'xdpyinfo'],
                                     stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        if display_check.returncode != 0:
            add_event("⚠️ Display :0 não está disponível, tentando mesmo assim...")
        
        # 5. Comando para abrir Chromium COM FLAGS ANTILOCK
        # Atalho da área de trabalho (install.sh → Chromium-Raspberry.desktop): manter flags alinhadas.
        cmd = [
            'sudo', '-u', 'administrador',
            'env', 'DISPLAY=:0',
            'chromium-browser' if os.path.exists('/usr/bin/chromium-browser') else 'chromium',
            f'--user-data-dir={CHROMIUM_USER_DATA_DIR}',
            '--no-first-run',
            '--start-maximized',
            '--ignore-certificate-errors',
            '--noerrdialogs',
            '--disable-session-crashed-bubble',
            '--disable-single-process',
            '--disable-features=ChromeWhatsNewUI,SingleProcess,ProcessPerSite',
            '--disable-gpu',
            '--disable-dbus',
            '--disable-background-networking',
            '--disable-sync',
            '--disable-default-apps',
            '--disable-extensions',
            '--disable-component-extensions-with-background-pages',
            '--disable-client-side-phishing-detection',
            '--disable-crash-reporter',
            '--disable-ipc-flooding-protection',
            '--disable-prompt-on-repost',
            '--disable-renderer-backgrounding',
            '--disable-hang-monitor',
            '--no-sandbox',  # Adicionado para evitar problemas de permissão
            '--test-type',   # Adicionado para ignorar erros de sandbox
            '--force-device-scale-factor=1'
        ]
        
        # URLs já validadas em load_autostart_urls()
        for url in urls:
            if url.strip():
                cmd.append(url.strip())
        
        add_event(f"🚀 Executando Chromium com perfil específico...")

        process, browser_log_fh = _popen_chromium_logged(cmd, "LAUNCH")
        add_event(f"✅ Browser iniciado com PID {process.pid}")

        time.sleep(3)
        if _chromium_is_running():
            result = subprocess.run(
                _pgrep_managed_args(),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            pids = result.stdout.strip().split("\n") if result.stdout else []
            add_event(f"✅ Chromium está rodando ({len(pids)} processos)")
        else:
            tail = _read_log_tail(BROWSER_LOG, 2500)
            singleton_hint = _chromium_probable_singleton_issue(tail)
            if singleton_hint:
                add_event(
                    "⚠️ Chromium não abriu (indícios de SingletonLock/SingletonSocket). "
                    "Resetando locks e tentando novamente..."
                )
            else:
                add_event(
                    "⚠️ Chromium não abriu na primeira tentativa. "
                    "Resetando locks (singleton) e tentando novamente..."
                )

            if browser_log_fh:
                try:
                    browser_log_fh.close()
                except Exception:
                    pass
                browser_log_fh = None

            # Entretanto o Chromium pode ter arrancado devagar; não matar nem duplicar.
            if _chromium_managed_profile_running():
                add_event(
                    "ℹ️ Chromium já está em execução com o perfil gerido "
                    f"({CHROMIUM_USER_DATA_DIR}). A saltar segundo lançamento e reset de singleton."
                )
            else:
                cleanup_chromium_locks()
                time.sleep(1)

                process2, browser_log_fh = _popen_chromium_logged(cmd, "LAUNCH_RETRY_AFTER_SINGLETON_RESET")
                add_event(f"🔄 Nova tentativa após reset (PID {process2.pid})")
                time.sleep(3)

                if _chromium_is_running():
                    result = subprocess.run(
                        _pgrep_managed_args(),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        text=True,
                    )
                    pids = result.stdout.strip().split("\n") if result.stdout else []
                    add_event(f"✅ Chromium está rodando após reset de singleton ({len(pids)} processos)")
                else:
                    tail2 = _read_log_tail(BROWSER_LOG, 2500)
                    if _chromium_probable_singleton_issue(tail2):
                        add_event(
                            "❌ Chromium ainda não abriu após reset de Singleton. "
                            "Verifique `browser-launch.log` e se há outra instância ativa."
                        )
                    else:
                        trimmed = tail2.replace("\n", " ")[:300]
                        add_event(f"⚠️ Chromium não abriu após retry. Log (trecho): {trimmed}...")

        if browser_log_fh:
            try:
                browser_log_fh.close()
            except Exception:
                pass
        
    except Exception as e:
        _log_unexpected(e, "open_browser_with_urls")
        add_event(f"❌ Erro ao abrir browser: {e}")
        traceback.print_exc()
    finally:
        _release_chromium_launch_lock(_lk)

# ========== CONTEXT PROCESSOR - Disponibiliza variáveis em todas as templates ==========
@app.context_processor
def inject_version():
    """Disponibiliza APP_VERSION e token CSRF nas templates"""
    return dict(app_version=APP_VERSION, csrf_token=session.get("_csrf_token", ""))


def _pyvenv_includes_system_site_packages() -> Optional[bool]:
    """Lê pyvenv.cfg ao lado do Python do venv (se aplicável)."""
    try:
        venv_dir = os.path.dirname(os.path.dirname(os.path.abspath(sys.executable)))
        cfg_path = os.path.join(venv_dir, "pyvenv.cfg")
        if not os.path.isfile(cfg_path):
            return None
        with open(cfg_path, "r", encoding="utf-8", errors="replace") as cf:
            for line in cf:
                s = line.strip()
                if s.lower().startswith("include-system-site-packages"):
                    return "true" in s.lower()
        return None
    except Exception:
        return None


@app.route("/api/health")
def api_health():
    """
    Estado mínimo sem autenticação — útil quando o login PAM falha no Raspberry.
    Não expõe segredos; mensagem de erro de import é truncada.
    Opcional: PI_MANAGER_HEALTH_SECRET — exige cabeçalho X-Health-Secret com o mesmo valor.
    """
    health_secret = (os.environ.get("PI_MANAGER_HEALTH_SECRET") or "").strip()
    if health_secret:
        cand = (request.headers.get("X-Health-Secret") or "").strip()
        a, b = cand.encode("utf-8"), health_secret.encode("utf-8")
        if len(a) != len(b) or not hmac.compare_digest(a, b):
            return jsonify({"ok": False}), 404

    pam_loaded = get_pam_module() is not None
    err = _PAM_IMPORT_ERROR
    err_short = (str(err)[:240] + "…") if err and len(str(err)) > 240 else (str(err) if err else None)
    venv_sys = _pyvenv_includes_system_site_packages()

    pam_hint: Optional[str] = None
    if not pam_loaded and err_short and "No module named 'pam'" in err_short:
        if venv_sys is True:
            _fix_pam_script = os.path.join(_APP_DIR, "scripts", "fix-pam-on-pi.sh")
            pam_hint = (
                "Sem modulo pam no venv: em Debian Trixie + Python 3.13 o apt pode nao expor pam ao venv. "
                f"Rode no Pi (reinstala pip python-pam se necessario): sudo bash {_fix_pam_script} "
                "ou reexecute install.sh atualizado (passo [7] instala python-pam via PyPI)."
            )

    admin_user_exists: Optional[bool] = None
    try:
        import pwd

        pwd.getpwnam(ADMIN_USERNAME)
        admin_user_exists = True
    except ImportError:
        admin_user_exists = None
    except KeyError:
        admin_user_exists = False
    except Exception:
        admin_user_exists = None

    return jsonify(
        {
            "ok": True,
            "app_version": APP_VERSION,
            "python_version": sys.version.split()[0],
            "python_executable": sys.executable,
            "pam_module_loaded": pam_loaded,
            "pam_import_error_class": type(err).__name__ if err else None,
            "pam_import_error": err_short,
            "pam_user": ADMIN_USERNAME,
            "pam_services": _pam_service_names(),
            "venv_include_system_site_packages": venv_sys,
            "pam_hint": pam_hint,
            "linux_user_exists": admin_user_exists,
            "dist_packages_in_path": any(
                p in sys.path
                for p in (
                    f"/usr/lib/python{sys.version_info.major}.{sys.version_info.minor}/dist-packages",
                    "/usr/lib/python3/dist-packages",
                )
            ),
        }
    )


@app.route('/api/system/info')
def get_system_info():
    """Retorna informações detalhadas do sistema"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        # Hostname
        hostname = subprocess.check_output(['hostname'], text=True).strip()
        
        # Modelo do Raspberry Pi
        model = "N/A"
        try:
            with open('/proc/device-tree/model', 'r') as f:
                model = f.read().strip('\x00')
        except Exception:
            try:
                model = subprocess.check_output(['cat', '/sys/firmware/devicetree/base/model'], 
                                              text=True).strip('\x00')
            except Exception:
                model = "Raspberry PI"
        
        # Uptime
        uptime = "N/A"
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.read().split()[0])
                days = int(uptime_seconds // 86400)
                hours = int((uptime_seconds % 86400) // 3600)
                minutes = int((uptime_seconds % 3600) // 60)
                
                if days > 0:
                    uptime = f"{days}d {hours}h {minutes}m"
                elif hours > 0:
                    uptime = f"{hours}h {minutes}m"
                else:
                    uptime = f"{minutes}m"
        except Exception as e:
            print(f"Erro ao obter uptime: {e}")
        
        # Temperatura
        temperature = "N/A"
        try:
            temp_output = subprocess.check_output(['vcgencmd', 'measure_temp'], 
                                                 text=True).strip()
            temp_match = re.search(r'(\d+\.?\d*)', temp_output)
            if temp_match:
                temperature = f"{temp_match.group(1)}°C"
        except Exception:
            try:
                with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                    temp_raw = int(f.read().strip())
                    temperature = f"{temp_raw / 1000:.1f}°C"
            except Exception:
                pass
        
        # CPU Usage
        cpu_usage = get_cpu_usage()
        
        # Memory Usage
        memory_usage = get_memory_usage()
        
        # Versão do Sistema
        os_version = "N/A"
        try:
            with open('/etc/os-release', 'r') as f:
                for line in f:
                    if line.startswith('PRETTY_NAME='):
                        os_version = line.split('=')[1].strip('"\'')
                        break
        except Exception:
            pass
        
        # Versão do Kernel
        kernel = subprocess.check_output(['uname', '-r'], text=True).strip()
        
        return jsonify({
            'hostname': hostname,
            'model': model,
            'uptime': uptime,
            'temperature': temperature,
            'cpu_usage': cpu_usage,
            'memory_usage': memory_usage,
            'os_version': os_version,
            'kernel': kernel,
            'app_version': APP_VERSION
        })
        
    except Exception as e:
        print(f"Erro ao obter informações do sistema: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/events')
def get_system_events():
    """Retorna os eventos recentes do servidor (in-memory)"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        return jsonify({'events': list(EVENT_LOG)})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/network/connection/<name>', methods=['GET'])
def get_connection_detail(name):
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    if not _is_safe_nm_connection_name(name):
        return jsonify({'error': 'Nome de conexão inválido'}), 400
    try:
        # Get connection properties
        result = run_nmcli(['-t', '-f', 'all', 'connection', 'show', name])
        if result.returncode != 0:
            stderr = (result.stderr or '').strip()
            return jsonify({'error': f'Conexão não encontrada'}), 404
        
        props = {}
        for line in result.stdout.strip().split('\n'):
            if not line or ':' not in line:
                continue
            k, v = line.split(':', 1)
            props[k.strip()] = v.strip()
        
        # Get device name from connection
        device = props.get('connection.interface-name', '')
        
        # Get current IP if connection is active
        ip4 = ''
        if device:
            ip_result = run_nmcli(['-t', '-f', 'IP4.ADDRESS', 'dev', 'show', device], capture_output=True)
            if ip_result.returncode == 0:
                # Com -t/-f apenas IP4.ADDRESS, a saída costuma ser uma linha com o valor (ex: 192.168.1.10/24)
                ip4_raw = ''
                for line in (ip_result.stdout or '').splitlines():
                    if line and line.strip():
                        ip4_raw = line.strip()
                        break
                if ip4_raw:
                    ip4 = ip4_raw.split('/')[0]
        
        # Parse connection data in a structured way
        conn_data = {
            'name': name,
            'type': props.get('connection.type', 'ethernet'),
            'device': device,
            'ip_type': 'dhcp' if props.get('ipv4.method') == 'auto' else 'static',
            'ip_address': props.get('ipv4.addresses', ''),
            'gateway': props.get('ipv4.gateway', ''),
            'dns': props.get('ipv4.dns', ''),
            'ssid': props.get('802-11-wireless.ssid', ''),
            'ip4': ip4
        }
        
        return jsonify({'success': True, **conn_data})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/network/connection/<name>', methods=['POST'])
def update_connection(name):
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    if not _is_safe_nm_connection_name(name):
        return jsonify({'error': 'Nome de conexão inválido'}), 400
    data = request.get_json(silent=True) or {}
    try:
        connection_type = data.get('type', '')
        ip_type = data.get('ip_type')
        
        # Se type='ip_only', apenas alterar as configurações de IP (modo edição)
        if connection_type == 'ip_only':
            if ip_type == 'dhcp':
                args = ['connection', 'modify', name, 'ipv4.method', 'auto']
                res = run_nmcli(args)
            elif ip_type == 'static':
                ip_address = data.get('ip_address', '') or ''
                gateway = data.get('gateway', '') or ''
                dns = data.get('dns', '') or ''
                
                if not ip_address:
                    return jsonify({'error': 'Endereço IP é obrigatório'}), 400
                
                args = ['connection', 'modify', name, 'ipv4.method', 'manual', 'ipv4.addresses', ip_address]
                if gateway:
                    args.extend(['ipv4.gateway', gateway])
                if dns:
                    # Convert comma-separated to space-separated for nmcli
                    dns_list = dns.replace(',', ' ')
                    args.extend(['ipv4.dns', dns_list])
                res = run_nmcli(args)
            else:
                return jsonify({'error': 'ip_type inválido'}), 400

            if res.returncode != 0:
                stderr = (res.stderr or '').strip()
                return jsonify({'error': f'nmcli error: {stderr}'}), 500

            # Try to reactivate the connection with new settings
            run_nmcli(['connection', 'down', name], capture_output=True)
            time.sleep(0.5)
            run_nmcli(['connection', 'up', name], capture_output=True)
            return jsonify({'success': True, 'message': 'Configuração IP atualizada com sucesso'})
        
        # Modo legado (não deve ser usado em edição segura)
        if ip_type == 'dhcp':
            args = ['connection', 'modify', name, 'ipv4.method', 'auto']
            res = run_nmcli(args)
        elif ip_type == 'static':
            ip_address = data.get('ip_address') or ''
            gateway = data.get('gateway') or ''
            dns = data.get('dns') or ''
            args = ['connection', 'modify', name, 'ipv4.method', 'manual', 'ipv4.addresses', ip_address]
            if gateway:
                args.extend(['ipv4.gateway', gateway])
            if dns:
                args.extend(['ipv4.dns', dns])
            res = run_nmcli(args)
        else:
            return jsonify({'error': 'ip_type inválido'}), 400

        if res.returncode != 0:
            stderr = (res.stderr or '').strip()
            return jsonify({'error': f'nmcli error: {stderr}'}), 500

        # Try to bring the connection up
        run_nmcli(['connection', 'down', name], capture_output=True)
        time.sleep(0.5)
        run_nmcli(['connection', 'up', name], capture_output=True)
        return jsonify({'success': True, 'message': 'Conexão atualizada com sucesso'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/network/connection/<name>', methods=['DELETE'])
def delete_connection_api(name):
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    if not _is_safe_nm_connection_name(name):
        return jsonify({'error': 'Nome de conexão inválido'}), 400
    try:
        res = run_nmcli(['connection', 'delete', name])
        if res.returncode != 0:
            stderr = (res.stderr or '').strip()
            return jsonify({'error': f'nmcli error: {stderr}'}), 500
        return jsonify({'success': True, 'message': 'Conexão deletada'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/network/connection/<name>/test', methods=['POST'])
def test_connection_api(name):
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    if not _is_safe_nm_connection_name(name):
        return jsonify({'error': 'Nome de conexão inválido'}), 400
    try:
        res = run_nmcli(['connection', 'up', name])
        if res.returncode != 0:
            stderr = (res.stderr or '').strip()
            return jsonify({'error': f'nmcli error: {stderr}'}), 500
        return jsonify({'success': True, 'message': 'Conexão ativada com sucesso'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ========== /api/system/hostname ==========
@app.route('/api/system/hostname', methods=['POST'])
def change_hostname():
    """
    Altera o hostname do sistema.

    Importante: não mexe em processos/locks do Chromium durante a troca,
    para evitar erros relacionados a SingletonLock/SingletonSocket.
    """
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    data = request.get_json(silent=True) or {}
    new_hostname = data.get('hostname')
    
    try:
        # Validação do hostname
        if not new_hostname or len(new_hostname) < 2:
            return jsonify({'error': 'Hostname deve ter pelo menos 2 caracteres'}), 400
        
        if len(new_hostname) > 63:
            return jsonify({'error': 'Hostname deve ter no máximo 63 caracteres'}), 400
        
        if not re.match(r'^[a-zA-Z0-9-]+$', new_hostname):
            return jsonify({'error': 'Hostname inválido. Use apenas letras, números e hífens'}), 400
        
        if new_hostname.startswith('-') or new_hostname.endswith('-'):
            return jsonify({'error': 'Hostname não pode começar ou terminar com hífen'}), 400
        
        add_event(f"🔄 Alterando hostname para: {new_hostname}")
        
        # Usa o wrapper seguro para aplicar hostname persistente
        result = run_hostname(new_hostname)
        
        if result.returncode == 0:
            # ✅ SUCESSO: Não mexer no Chromium/locks para preservar operação e evitar erros.
            add_event(f"✅ Hostname alterado para {new_hostname}. Preservando Chromium/locks.")

            chromium_running = _chromium_managed_profile_running()

            if chromium_running:
                return jsonify({
                    'success': True,
                    'warning': True,
                    'message': 'Hostname alterado com sucesso. Chromium estava rodando e foi preservado (locks mantidos).'
                })

            return jsonify({
                'success': True,
                'message': 'Hostname alterado com sucesso.'
            })
        else:
            stderr = (result.stderr or '').strip()
            error_msg = f"Falha ao alterar hostname: {stderr}" if stderr else "Falha ao alterar hostname (código de erro desconhecido)"
            add_event(f"❌ {error_msg}")
            return jsonify({'error': error_msg}), 500
            
    except subprocess.TimeoutExpired:
        add_event(f"❌ Timeout ao alterar hostname")
        return jsonify({'error': 'Timeout ao executar comando'}), 500
    except Exception as e:
        add_event(f"❌ Erro ao alterar hostname: {str(e)}")
        return jsonify({'error': str(e)}), 500
    


@app.route('/api/system/password', methods=['POST'])
def change_password():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    data = request.get_json(silent=True) or {}
    new_password = data.get('password')
    try:
        if not new_password or len(new_password) < MIN_PASSWORD_LENGTH:
            return jsonify({'error': f'Senha deve ter pelo menos {MIN_PASSWORD_LENGTH} caracteres'}), 400
        result = run_chpasswd('administrador', new_password)
        if result.returncode == 0:
            return jsonify({'success': True, 'message': 'Senha alterada com sucesso'})
        else:
            return jsonify({'error': f'Erro ao alterar senha: {result.stderr}'}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/reboot', methods=['POST'])
def reboot_system():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        run_power('reboot-1', capture_output=True)
        return jsonify({'success': True, 'message': 'Sistema será reiniciado em 1 minuto'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/shutdown', methods=['POST'])
def shutdown_system():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        run_power('halt-1', capture_output=True)
        return jsonify({'success': True, 'message': 'Sistema será desligado em 1 minuto'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/reboot-now', methods=['POST'])
def reboot_now():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        run_power('reboot-now', capture_output=True)
        return jsonify({'success': True, 'message': 'Reiniciando agora...'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/shutdown-now', methods=['POST'])
def shutdown_now():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        run_power('halt-now', capture_output=True)
        return jsonify({'success': True, 'message': 'Desligando agora...'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/system/restart-service', methods=['POST'])
def restart_service():
    """
    Reinicia o serviço forçando a finalização do processo Flask.
    O systemd com Restart=always é responsável por subir novamente a aplicação.
    """
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401

    try:
        def do_restart():
            # Pequena folga para o client receber a resposta HTTP
            time.sleep(0.5)
            try:
                add_event("🔄 Reinício do serviço solicitado via API (systemd irá reiniciar o processo).")
            except Exception:
                pass
            os.kill(os.getpid(), signal.SIGTERM)

        t = threading.Thread(target=do_restart, daemon=True)
        t.start()

        return jsonify({'success': True, 'message': 'Reiniciando o serviço...'}), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ========== API - REDE ==========
@app.route('/api/network/current')
def get_network_info():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        # Get ALL connections (not just active ones)
        # Using both the NAME:DEVICE and connection details
        result = run_nmcli(['-t', '-f', 'NAME,DEVICE,TYPE,ACTIVE,STATE', 'con', 'show'])
        if result.returncode != 0:
            stderr = (result.stderr or '').strip()
            return jsonify({'error': f'nmcli error: {stderr}'}), 500
        connections = []
        connection_details = {}
        
        for line in result.stdout.strip().split('\n'):
            if line:
                parts = line.split(':')
                # Handle variable number of parts (some may be empty)
                name = parts[0] if len(parts) > 0 else ''
                device = parts[1] if len(parts) > 1 else ''
                con_type = parts[2] if len(parts) > 2 else 'ethernet'
                active = parts[3] if len(parts) > 3 else 'no'
                state = parts[4] if len(parts) > 4 else ''
                
                # Skip loopback connections
                if con_type == 'loopback':
                    continue
                
                # If device is empty, try to get it from connection.interface-name
                if not device:
                    detail_result = run_nmcli(['-t', '-f', 'connection.interface-name', 'connection', 'show', name], capture_output=True)
                    if detail_result.returncode == 0 and detail_result.stdout.strip():
                        device = detail_result.stdout.strip().split(':')[1].strip() if ':' in detail_result.stdout.strip() else ''
                
                # Determine the state: "ativado" if active, "desativado" if not
                connection_state = 'ativado' if active.strip().lower() == 'yes' else 'desativado'
                connections.append({
                    'name': name.strip(), 
                    'device': device.strip(), 
                    'type': con_type.strip(), 
                    'state': connection_state,
                    'active': active.strip()
                })

        # Build device->IP mapping (robusto para IPv6, sem depender de separadores ':')
        device_set = {c.get('device') for c in connections if c.get('device')}
        device_ips = {}

        for dev in device_set:
            device_ips[dev] = {'ip4': '', 'ip6': ''}

            ip4_res = run_nmcli(['-t', '-f', 'IP4.ADDRESS', 'dev', 'show', dev], capture_output=True)
            if ip4_res.returncode == 0:
                ip4_raw = ''
                for line in (ip4_res.stdout or '').splitlines():
                    if line and line.strip():
                        ip4_raw = line.strip()
                        break
                if ip4_raw:
                    device_ips[dev]['ip4'] = ip4_raw.split('/')[0]

            ip6_res = run_nmcli(['-t', '-f', 'IP6.ADDRESS', 'dev', 'show', dev], capture_output=True)
            if ip6_res.returncode == 0:
                ip6_raw = ''
                for line in (ip6_res.stdout or '').splitlines():
                    if line and line.strip():
                        ip6_raw = line.strip()
                        break
                if ip6_raw:
                    device_ips[dev]['ip6'] = ip6_raw.split('/')[0]

        # Add IP information to each connection
        for conn in connections:
            device = conn.get('device', '')
            if device in device_ips:
                conn['ip4'] = device_ips[device].get('ip4', '')
                conn['ip6'] = device_ips[device].get('ip6', '')
            else:
                conn['ip4'] = ''
                conn['ip6'] = ''
        
        # Also prepare devices list for backward compatibility
        devices = []
        for device, ips in device_ips.items():
            dev_info = {'device': device}
            if ips.get('ip4'):
                dev_info['ip4'] = ips['ip4']
            if ips.get('ip6'):
                dev_info['ip6'] = ips['ip6']
            devices.append(dev_info)
        return jsonify({'connections': connections, 'devices': devices})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/network/wifi/list')
def scan_wifi():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        result = run_nmcli(['-t', '-f', 'SSID,SIGNAL,SECURITY', 'dev', 'wifi', 'list'])
        if result.returncode != 0:
            stderr = (result.stderr or '').strip()
            return jsonify({'error': f'nmcli error: {stderr}'}), 500
        networks = []
        for line in result.stdout.strip().split('\n'):
            if line:
                # Segurança/SSID pode ter ':'; limitar split evita quebrar o parse
                parts = line.split(':', 2)
                if len(parts) >= 3:
                    ssid, signal, security = parts[0], parts[1], parts[2]
                    networks.append({'ssid': ssid, 'signal': signal, 'security': security})
        return jsonify({'networks': networks})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/network/configure', methods=['POST'])
def configure_network():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    data = request.get_json(silent=True) or {}
    connection_type = data.get('type')
    connection_name = data.get('name')
    ip_type = data.get('ip_type', 'dhcp')
    
    try:
        if not connection_type or not connection_name:
            return jsonify({'error': 'Parâmetros inválidos'}), 400

        # Handle toggle (ativar/desativar)
        if connection_type == 'toggle':
            action = data.get('action', 'up')
            result = run_nmcli(['connection', action, connection_name])
            if result.returncode == 0:
                return jsonify({'success': True, 'message': f'Conexão {action}da com sucesso'})
            else:
                stderr = (result.stderr or '').strip()
                return jsonify({'error': f'Erro: {stderr}'}), 500
        
        if connection_type == 'wifi':
            ssid = data.get('ssid')
            password = data.get('password', '')
            
            if not ssid:
                return jsonify({'error': 'SSID é obrigatório'}), 400
            
            # Create or modify Wi-Fi connection
            # First, check if connection exists
            check_result = run_nmcli(['connection', 'show', connection_name], capture_output=True)
            
            if check_result.returncode == 0:
                # Connection exists, modify it
                args = ['connection', 'modify', connection_name, 
                        '802-11-wireless.ssid', ssid]
                if password:
                    args.extend(['802-11-wireless-security.psk', password])
                result = run_nmcli(args)
            else:
                # Create new connection
                args = ['connection', 'add', 'type', 'wifi', 'ifname', 'wlan0',
                        'con-name', connection_name,
                        '802-11-wireless.ssid', ssid]
                if password:
                    args.extend(['802-11-wireless-security.key-mgmt', 'wpa-psk',
                               '802-11-wireless-security.psk', password])
                result = run_nmcli(args)
        
        elif connection_type == 'ethernet':
            device = data.get('device', 'eth0')
            
            # Check if connection exists
            check_result = run_nmcli(['connection', 'show', connection_name], capture_output=True)
            
            if check_result.returncode == 0:
                # Connection exists: apenas mantém o "result" para seguir o fluxo
                # (as configurações de IP serão aplicadas abaixo na mesma rota)
                result = check_result
            else:
                # Create new connection
                result = run_nmcli(['connection', 'add', 'type', 'ethernet', 
                                   'ifname', device, 'con-name', connection_name])
        
        if result.returncode != 0:
            stderr = (result.stderr or '').strip()
            return jsonify({'error': f'Erro: {stderr}'}), 500
        
        # Configure IP settings
        if ip_type == 'static':
            ip_address = data.get('ip_address', '')
            gateway = data.get('gateway', '')
            dns = data.get('dns', '')
            
            if not ip_address:
                return jsonify({'error': 'Endereço IP é obrigatório'}), 400
            
            args = ['connection', 'modify', connection_name, 
                   'ipv4.method', 'manual',
                   'ipv4.addresses', ip_address]
            
            if gateway:
                args.extend(['ipv4.gateway', gateway])
            if dns:
                args.extend(['ipv4.dns', dns.replace(',', ' ')])
            
            result = run_nmcli(args)
            if result.returncode != 0:
                stderr = (result.stderr or '').strip()
                return jsonify({'error': f'Erro ao configurar IP: {stderr}'}), 500
        else:
            # DHCP
            result = run_nmcli(['connection', 'modify', connection_name, 
                              'ipv4.method', 'auto'])
            if result.returncode != 0:
                stderr = (result.stderr or '').strip()
                return jsonify({'error': f'Erro ao configurar DHCP: {stderr}'}), 500
        
        # Try to activate connection
        run_nmcli(['connection', 'down', connection_name], capture_output=True)
        time.sleep(0.5)
        run_nmcli(['connection', 'up', connection_name], capture_output=True)
        
        return jsonify({'success': True, 'message': 'Conexão configurada com sucesso'})
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ========== API - AUTOSTART ==========
@app.route('/api/autostart/urls', methods=['GET', 'POST'])
def manage_autostart():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    if request.method == 'GET':
        try:
            urls = load_autostart_urls()
            return jsonify({'urls': urls})
        except Exception as e:
            return jsonify({'error': str(e)}), 500
    
    elif request.method == 'POST':
        data = request.get_json(silent=True) or {}
        urls = data.get('urls', [])
        try:
            # Valida URLs
            for url in urls:
                if url.strip() and not is_valid_url_or_ip(url.strip()):
                    return jsonify({'error': f'URL ou IP inválido: {url}'}), 400
            
            # Salva URLs
            with open(AUTOSTART_CONFIG, 'w') as f:
                for url in urls:
                    if url.strip():
                        formatted_url = format_url(url.strip())
                        f.write(formatted_url + '\n')
            
            # Sincroniza favoritos do Chromium
            success, message = sync_chromium_favorites()
            
            if success:
                return jsonify({
                    'success': True, 
                    'message': 'URLs salvas e favoritos sincronizados com sucesso',
                    'sync_message': message
                })
            else:
                return jsonify({
                    'success': True, 
                    'message': 'URLs salvas, mas erro ao sincronizar favoritos',
                    'sync_message': message
                })
                
        except Exception as e:
            return jsonify({'error': str(e)}), 500

# ========== API - FAVORITOS (NOVA) ==========
@app.route('/api/favorites/sync', methods=['POST'])
def sync_favorites():
    """Sincroniza manualmente os favoritos"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        success, message = sync_chromium_favorites()
        if success:
            return jsonify({'success': True, 'message': message})
        else:
            return jsonify({'error': message}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/favorites/current', methods=['GET'])
def get_current_favorites():
    """Obtém os favoritos atuais do Chromium"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        favorites = favorites_manager.load_current_favorites()
        return jsonify({
            'success': True,
            'favorites': favorites,
            'count': len(favorites)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500
@app.route('/api/favorites/diagnostic', methods=['GET'])
def diagnostic_favorites():
    """Diagnóstico completo dos favoritos"""
    gate = _require_diagnostics_json()
    if gate is not None:
        return gate
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        info = {
            'bookmarks_path': str(favorites_manager.bookmarks_file),
            'bookmarks_exists': favorites_manager.bookmarks_file.exists(),
            'chromium_dir_exists': favorites_manager.chromium_dir.exists(),
            'username': favorites_manager.username,
            'permissions': {}
        }
        
        # Verifica permissões
        if favorites_manager.bookmarks_file.exists():
            import stat
            st = os.stat(favorites_manager.bookmarks_file)
            info['permissions']['bookmarks'] = {
                'uid': st.st_uid,
                'gid': st.st_gid,
                'mode': stat.filemode(st.st_mode)
            }
        
        # Carrega favoritos atuais
        current_favs = favorites_manager.load_current_favorites()
        info['current_favorites'] = {
            'count': len(current_favs),
            'sample': current_favs[:5] if current_favs else []
        }
        
        # Carrega URLs configuradas
        config_urls = load_autostart_urls()
        info['config_urls'] = {
            'count': len(config_urls),
            'urls': config_urls
        }
        
        return jsonify({'success': True, 'diagnostic': info})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    
@app.route('/api/favorites/profiles', methods=['GET'])
def get_chromium_profiles():
    """Lista todos os perfis do Chromium"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        profiles = favorites_manager.find_all_profiles()
        active_profile = favorites_manager.active_profile
        
        # Verifica conteúdo de cada perfil
        profiles_info = []
        for profile in profiles:
            profile_path = favorites_manager.chromium_dir / profile
            bookmarks_file = profile_path / 'Bookmarks'
            has_bookmarks = bookmarks_file.exists()
            bookmarks_count = 0
            
            if has_bookmarks:
                try:
                    with open(bookmarks_file, 'r') as f:
                        data = json.load(f)
                        # Conta URLs
                        def count_urls(node):
                            count = 0
                            if 'children' in node:
                                for child in node.get('children', []):
                                    count += count_urls(child)
                            elif node.get('type') == 'url':
                                count += 1
                            return count
                        
                        roots = data.get('roots', {})
                        for root in roots.values():
                            bookmarks_count += count_urls(root)
                except Exception:
                    bookmarks_count = 0
            
            profiles_info.append({
                'name': profile,
                'active': (profile == active_profile),
                'has_bookmarks': has_bookmarks,
                'bookmarks_count': bookmarks_count,
                'path': str(profile_path)
            })
        
        return jsonify({
            'success': True,
            'profiles': profiles_info,
            'active_profile': active_profile,
            'count': len(profiles)
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/favorites/set-profile', methods=['POST'])
def set_chromium_profile():
    """Define o perfil ativo para sincronização"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    data = request.get_json(silent=True) or {}
    profile_name = data.get('profile')
    
    if not profile_name:
        return jsonify({'error': 'Nome do perfil não fornecido'}), 400
    
    try:
        # Verifica se o perfil existe
        profile_path = favorites_manager.chromium_dir / profile_name
        if not profile_path.exists():
            return jsonify({'error': f'Perfil {profile_name} não existe'}), 404
        
        # Atualiza o perfil ativo
        favorites_manager.active_profile = profile_name
        favorites_manager.bookmarks_file = profile_path / 'Bookmarks'
        
        # Cria arquivo de bookmarks se não existir
        if not favorites_manager.bookmarks_file.exists():
            favorites_manager.bookmarks_file.parent.mkdir(parents=True, exist_ok=True)
            empty_structure = favorites_manager.create_bookmarks_structure([])
            with open(favorites_manager.bookmarks_file, 'w') as f:
                json.dump(empty_structure, f, indent=2)
        
        return jsonify({
            'success': True,
            'message': f'Perfil alterado para {profile_name}',
            'active_profile': favorites_manager.active_profile
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/favorites/force-sync', methods=['POST'])
def force_sync_favorites():
    """Força sincronização completa dos favoritos"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        # 1. Carrega URLs
        urls = load_autostart_urls()
        
        if not urls:
            return jsonify({'success': True, 'message': 'Nenhuma URL para sincronizar'})
        
        formatted_urls = [u.strip() for u in urls if u.strip()]
        
        # 3. Atualiza diretamente (sem preservar)
        success, message = favorites_manager.update_favorites(formatted_urls)
        
        if success:
            # 4. Força recarregamento no Chromium
            try:
                # Envia sinal para Chromium recarregar favoritos
                subprocess.run(
                    _pkill_managed_args("-HUP"),
                    capture_output=True,
                    stderr=subprocess.DEVNULL,
                )
            except (OSError, subprocess.SubprocessError) as e:
                _log_unexpected(e, "force_sync_favorites pkill")
            
            return jsonify({
                'success': True,
                'message': f'Favoritos forçadamente sincronizados: {message}',
                'urls_count': len(formatted_urls)
            })
        else:
            return jsonify({'error': message}), 500
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500
        
@app.route('/api/favorites/test', methods=['GET'])
def test_favorites():
    """Testa a funcionalidade de favoritos"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        # Testa com URLs de exemplo
        test_urls = [
            'https://www.google.com',
            'https://github.com',
            'http://localhost:5000'
        ]
        
        print(f"🧪 Testando com {len(test_urls)} URLs...")
        success, message = favorites_manager.update_favorites(test_urls, "TESTE")
        
        return jsonify({
            'success': success,
            'message': message,
            'test_urls': test_urls
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ========== LOGO APÓS /api/system/events, ADICIONE ISSO ==========


    
# ========== ENDPOINT PARA LIMPEZA MANUAL ==========
@app.route('/api/system/cleanup-chromium', methods=['POST'])
def manual_cleanup_chromium():
    """Endpoint para limpeza manual dos locks do Chromium"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        add_event("🧹 Limpeza manual de locks do Chromium solicitada")
        success = cleanup_chromium_locks()
        if success:
            add_event("✅ Limpeza manual de locks concluída com sucesso")
            return jsonify({
                'success': True,
                'message': 'Locks do Chromium limpos com sucesso'
            })
        else:
            add_event("⚠️ Limpeza manual de locks concluída com avisos")
            return jsonify({
                'success': True,
                'warning': True,
                'message': 'Locks limpos, mas alguns arquivos podem não ter sido removidos'
            })
    except Exception as e:
        add_event(f"❌ Erro na limpeza manual de locks: {str(e)}")
        return jsonify({'error': str(e)}), 500

# ========== API - SISTEMA (MODIFICADA) ==========
@app.route('/api/system/restart-browser', methods=['POST'])
def restart_browser():
    """Reinicia o Chromium com limpeza prévia de locks"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        add_event("🔄 Reiniciando browser...")
        
        # 1. Sincroniza favoritos primeiro
        sync_chromium_favorites()
        
        # 2. Limpa todos os locks
        cleanup_chromium_locks()
        
        # 3. Reabre com perfil específico
        urls = load_autostart_urls()
        if urls:
            chromium_bin = (
                "chromium-browser"
                if os.path.exists("/usr/bin/chromium-browser")
                else "chromium"
            )
            cmd = [
                "sudo",
                "-u",
                "administrador",
                "env",
                "DISPLAY=:0",
                chromium_bin,
                f"--user-data-dir={CHROMIUM_USER_DATA_DIR}",
                "--ignore-certificate-errors",
                "--start-maximized",
                "--no-first-run",
                "--disable-dbus",
                "--noerrdialogs",
                "--disable-infobars",
                "--disable-single-process",
                "--disable-features=SingleProcess",
            ]
            cmd.extend(u for u in urls if u.strip())

            browser_log_fh = None
            try:
                _, browser_log_fh = _popen_chromium_logged(cmd, "RESTART")
            except Exception:
                try:
                    subprocess.Popen(cmd)
                except Exception:
                    pass

            time.sleep(2)

            if _chromium_is_running():
                add_event("✅ Browser reiniciado e Chromium está rodando")
                if browser_log_fh:
                    try:
                        browser_log_fh.close()
                    except Exception:
                        pass
                return jsonify(
                    {"success": True, "message": "Browser reiniciado com sucesso"}
                )

            tail = _read_log_tail(BROWSER_LOG, 2500)
            if _chromium_probable_singleton_issue(tail):
                add_event(
                    "⚠️ Chromium não subiu (possível Singleton). Resetando locks e tentando novamente..."
                )
            else:
                add_event(
                    "⚠️ Chromium não ficou rodando. Resetando locks (singleton) e nova tentativa..."
                )

            if browser_log_fh:
                try:
                    browser_log_fh.close()
                except Exception:
                    pass
                browser_log_fh = None

            cleanup_chromium_locks()
            time.sleep(1)

            try:
                _, browser_log_fh = _popen_chromium_logged(
                    cmd, "RESTART_RETRY_AFTER_SINGLETON_RESET"
                )
            except Exception:
                try:
                    subprocess.Popen(cmd)
                except Exception:
                    pass

            time.sleep(2)

            if _chromium_is_running():
                add_event("✅ Browser reiniciado após reset de singleton")
                if browser_log_fh:
                    try:
                        browser_log_fh.close()
                    except Exception:
                        pass
                return jsonify(
                    {
                        "success": True,
                        "message": "Browser reiniciado após limpeza de SingletonLock/SingletonSocket",
                    }
                )

            tail2 = _read_log_tail(BROWSER_LOG, 2500)
            if _chromium_probable_singleton_issue(tail2):
                add_event(
                    "❌ Chromium ainda não subiu após reset de Singleton. Ver browser-launch.log."
                )
                error_msg = (
                    "Chromium falhou após reset de SingletonLock/SingletonSocket. "
                    "Consulte browser-launch.log."
                )
            else:
                trimmed = tail2.replace("\n", " ")[:300]
                error_msg = (
                    f"Chromium não ficou rodando após retry. Log (trecho): {trimmed}..."
                )

            if browser_log_fh:
                try:
                    browser_log_fh.close()
                except Exception:
                    pass

            return jsonify({"success": False, "error": error_msg})
        else:
            add_event("✅ Browser fechado (nenhuma URL configurada)")
            return jsonify({
                'success': True, 
                'message': 'Browser fechado (nenhuma URL configurada)'
            })
    except Exception as e:
        add_event(f"❌ Erro ao reiniciar browser: {e}")
        return jsonify({'error': str(e)}), 500

# ========== DIAGNÓSTICO ==========
@app.route('/api/diagnostic/browser', methods=['GET'])
def diagnostic_browser():
    """Verifica se o browser pode ser aberto"""
    gate = _require_diagnostics_json()
    if gate is not None:
        return gate
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        # Verifica se Chromium está instalado
        chromium_installed = os.path.exists('/usr/bin/chromium') or os.path.exists('/usr/bin/chromium-browser')
        
        # Verifica DISPLAY
        display = os.environ.get('DISPLAY', 'N/A')
        
        # Verifica XAUTHORITY
        xauth = os.path.exists('/home/administrador/.Xauthority')
        
        # Verifica URLs configuradas
        urls = load_autostart_urls()
        
        return jsonify({
            'success': True,
            'chromium_installed': chromium_installed,
            'display': display,
            'xauthority_exists': xauth,
            'urls_configured': len(urls),
            'urls': urls
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/diagnostic/wrappers', methods=['GET'])
def diagnostic_wrappers():
    """Relata existência, permissões e tentativa de execução via sudo -n dos wrappers"""
    gate = _require_diagnostics_json()
    if gate is not None:
        return gate
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401

    wrappers = [NMCLI_WRAPPER, CHPASS_WRAPPER, HOSTNAME_WRAPPER, CHROMIUM_LOCKS_WRAPPER, POWER_WRAPPER]
    info = {}
    for w in wrappers:
        item = {
            'path': w,
            'exists': os.path.exists(w),
            'is_file': os.path.isfile(w),
            'is_executable': os.access(w, os.X_OK)
        }
        try:
            st = os.stat(w)
            item.update({'uid': st.st_uid, 'gid': st.st_gid, 'mode': oct(st.st_mode & 0o777)})
        except Exception as e:
            item['stat_error'] = str(e)

        # Tenta executar via sudo sem prompt (-n) para verificar se sudoers permite
        try:
            proc = subprocess.run(['sudo', '-n', w, '--version'], capture_output=True, text=True, timeout=5)
            item['sudo_returncode'] = proc.returncode
            item['sudo_stdout'] = proc.stdout.strip()
            item['sudo_stderr'] = proc.stderr.strip()
        except Exception as e:
            item['sudo_error'] = str(e)

        info[w] = item

    info['nmcli_exists'] = shutil.which('nmcli') is not None
    return jsonify({'success': True, 'wrappers': info})


@app.route('/api/diagnostic/session', methods=['GET'])
def diagnostic_session():
    """Debug endpoint: mostra o conteúdo da sessão e cookies recebidos (apenas local)."""
    gate = _require_diagnostics_json()
    if gate is not None:
        return gate
    try:
        if not check_auth():
            # Mantém o endpoint mais seguro: exige autenticação
            return jsonify({'error': 'Não autenticado'}), 401
        sess = dict(session)
        cookies = {k: v for k, v in request.cookies.items()}
        return jsonify({'success': True, 'session': sess, 'cookies': cookies})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# ========== PÁGINAS WEB (ROTAS SIMPLES) ==========
@app.route('/login', methods=['GET', 'POST'])
def login():
    """Rota de login simples autenticando a senha REAL do usuário `administrador` via PAM."""
    if request.method == 'POST':
        blocked = _login_rate_limited_response()
        if blocked is not None:
            return blocked

        # aceita formulário ou JSON
        password = request.form.get('password') if request.form else None
        if not password and request.is_json:
            password = (request.get_json() or {}).get('password')
        password = (password or "").strip()

        if not password:
            _login_record_auth_failure()
            return render_template('login.html', error='Senha invalida.')

        mod = get_pam_module()
        if mod is None:
            # Texto sem acentos: continua legivel se o navegador usar charset errado (Mojibake).
            return render_template(
                'login.html',
                error=(
                    "PAM nao carregou neste Python.\n\n"
                    "No Pi (SSH), execute:\n"
                    "  sudo apt install -y python3-pam\n"
                    "  sudo -u administrador /home/administrador/raspberry-pi-manager/venv/bin/pip uninstall -y python-pam\n"
                    "  sudo systemctl restart raspberry-pi-manager\n\n"
                    "Ou: sudo /usr/local/bin/update_app.sh\n\n"
                    "Ver erro exato: journalctl -u raspberry-pi-manager -b -n 30 --no-pager"
                ),
            )

        if verify_admin_password(password):
            _login_clear_rate_limit()
            session['authenticated'] = True
            session['_csrf_token'] = secrets.token_hex(32)
            session.modified = True
            return redirect(url_for('index'))
        # mostrar página com erro
        _login_record_auth_failure()
        return render_template('login.html', error='Senha invalida.')
    return render_template('login.html')


@app.route('/logout')
def logout():
    session.pop('authenticated', None)
    session.pop('_csrf_token', None)
    return redirect(url_for('login'))


@app.route('/')
def index():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('index.html')


@app.route('/network', endpoint='network')
def network_page():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('network.html')


@app.route('/system', endpoint='system')
def system_page():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('system.html')


@app.route('/autostart', endpoint='autostart')
def autostart_page():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('autostart.html')


# ========== INICIALIZAÇÃO ==========
def startup_tasks():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    
    # Verifica se o arquivo autostart.conf existe
    if not os.path.exists(AUTOSTART_CONFIG) or os.path.getsize(AUTOSTART_CONFIG) == 0:
        print("📝 Criando autostart.conf com URLs padrão...")
        default_urls = [
            'http://localhost:5000',
            'https://www.google.com'
        ]
        with open(AUTOSTART_CONFIG, 'w') as f:
            for url in default_urls:
                f.write(url + '\n')
        print(f"✅ autostart.conf criado com {len(default_urls)} URLs padrão")
    
    # Aguarda um pouco para garantir que o sistema está pronto
    time.sleep(2)
    
    # Sincroniza favoritos
    print("🔄 Sincronizando favoritos do Chromium...")
    urls = load_autostart_urls()
    if urls:
        formatted_urls = [u.strip() for u in urls if u.strip()]
        success, message = favorites_manager.sync_favorites_with_config(formatted_urls)
        if success:
            print(f"✅ {message}")
        else:
            print(f"❌ Erro: {message}")
    
    # Uma thread dispara open_browser_with_urls (mais ~10s dentro dela para X11 :0)
    print("⏰ Agendando abertura única do Chromium (URLs em autostart.conf)...")
    time.sleep(3)  # Aguarda mais para sincronização terminar
    browser_thread = threading.Thread(target=open_browser_with_urls)
    browser_thread.daemon = True
    browser_thread.start()

# Testes: definir SKIP_STARTUP_TASKS=1 (pytest em tests/conftest.py) para evitar sleeps/threads na importação.
if os.environ.get("SKIP_STARTUP_TASKS", "").lower() not in ("1", "true", "yes"):
    with app.app_context():
        startup_tasks()


@app.route('/about')
def about():
    return render_template('about.html')


def _is_allowed_update_script(path: str) -> bool:
    """Delega para lib.update_allowlist (testável)."""
    return _is_allowed_update_script_lib(path, app_root_path=app.root_path)


@app.route('/webhook', methods=['POST'])
def webhook():
    """Endpoint to receive GitHub webhook and trigger update script.

    Expects header 'X-Hub-Signature-256: sha256=...' and secret in env WEBHOOK_SECRET.
    """
    secret = os.environ.get('WEBHOOK_SECRET')
    if not secret:
        add_event('Webhook called but WEBHOOK_SECRET not set')
        return 'Server misconfigured', 500

    signature = request.headers.get('X-Hub-Signature-256', '')
    body = request.get_data()

    mac = hmac.new(secret.encode(), msg=body, digestmod=hashlib.sha256)
    expected = f'sha256={mac.hexdigest()}'

    if not hmac.compare_digest(expected, signature):
        add_event('Webhook signature mismatch')
        return 'Unauthorized', 401

    # Run update script in background so we respond quickly
    def run_update():
        try:
            # Instalação: app.py e update_app.sh na mesma pasta (INSTALL_DIR).
            # Desenvolvimento: app em src/ e update na raiz do repositório.
            script_path = os.path.join(app.root_path, 'update_app.sh')
            if not os.path.isfile(script_path):
                alt = os.path.abspath(os.path.join(app.root_path, '..', 'update_app.sh'))
                if os.path.isfile(alt):
                    script_path = alt
            add_event('Webhook validated — running update script')
            if not os.path.isfile(script_path):
                add_event(f'Update script missing: {script_path}')
                return
            if not _is_allowed_update_script(script_path):
                add_event(f'Update script path rejected: {script_path}')
                return
            script_abs = os.path.realpath(script_path)
            proc = subprocess.run(['/bin/bash', script_abs], capture_output=True, text=True, timeout=600)
            add_event(f'Update stdout: {proc.stdout[:1000]}')
            if proc.stderr:
                add_event(f'Update stderr: {proc.stderr[:1000]}')
        except Exception as e:
            add_event(f'Error running update: {e}')

    t = threading.Thread(target=run_update)
    t.daemon = True
    t.start()

    return 'OK', 200

if __name__ == '__main__':
    debug_mode = os.environ.get('DEBUG', 'False').lower() == 'true'
    print(
        format_log_line(
            f"🚀 Iniciando servidor Flask em modo {'debug' if debug_mode else 'produção'}..."
        )
    )
    print(format_log_line("🌐 Acesse em: http://0.0.0.0:5000"))
    app.run(host='0.0.0.0', port=5000, debug=debug_mode, threaded=True)