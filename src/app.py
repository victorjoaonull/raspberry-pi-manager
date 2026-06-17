#!/usr/bin/env python3
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from urllib.parse import urlparse
import subprocess
import os
import json
import re
import threading
import time
import shutil
from pathlib import Path
from datetime import datetime
from collections import deque

app = Flask(__name__)


def _load_secret_key():
    """Obtém a secret_key do Flask de forma segura.

    Ordem de prioridade:
    1. Variável de ambiente SECRET_KEY (definida em /etc/default/raspberry-pi-manager).
    2. Arquivo persistente em ~/.config/raspberry-pi-manager/secret_key.
    3. Gera uma nova chave aleatória e a persiste no arquivo acima.

    Persistir a chave evita invalidar todas as sessões a cada restart do serviço.
    """
    env_key = os.environ.get('SECRET_KEY')
    if env_key:
        return env_key

    key_dir = Path.home() / '.config' / 'raspberry-pi-manager'
    key_file = key_dir / 'secret_key'

    try:
        if key_file.exists():
            existing = key_file.read_text().strip()
            if existing:
                return existing
    except Exception as e:
        print(f"⚠️ Não foi possível ler secret_key existente: {e}")

    new_key = os.urandom(32).hex()
    try:
        key_dir.mkdir(parents=True, exist_ok=True)
        key_file.write_text(new_key)
        os.chmod(key_file, 0o600)
        print(f"🔐 Nova secret_key gerada e salva em {key_file}")
    except Exception as e:
        print(f"⚠️ Não foi possível persistir secret_key (usando apenas em memória): {e}")

    return new_key


app.secret_key = _load_secret_key()

# Blindagem dos cookies de sessão (login):
# - HTTPONLY: JavaScript da página não consegue ler o cookie (protege de XSS).
# - SAMESITE 'Lax': o cookie não é enviado em requisições vindas de outros sites
#   (protege de CSRF). 'Lax' mantém a navegação normal funcionando.
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',
)



# Pequeno log de eventos em memória para mostrar no dashboard
EVENT_LOG = deque(maxlen=200)

def add_event(msg):
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    entry = f"[{ts}] {msg}"
    try:
        EVENT_LOG.appendleft(entry)
    except Exception:
        pass
    print(entry)

# Caminho para o wrapper criado pelo instalador
NMCLI_WRAPPER = '/usr/local/bin/pi-manager-nmcli'
CHPASS_WRAPPER = '/usr/local/bin/pi-manager-chpasswd'
HOSTNAME_WRAPPER = '/usr/local/bin/pi-manager-hostname'

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

# Configurações
# IMPORTANTE: os caminhos são derivados da raiz do repositório (pasta-pai de src/),
# para ficarem sempre alinhados com install.sh (que cria $INSTALL_DIR/config).
# NÃO use caminhos absolutos hardcoded aqui — quebra o contrato com o instalador.
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_DIR = os.path.join(BASE_DIR, 'config')
NETWORK_CONFIG = os.path.join(CONFIG_DIR, 'network.conf')
AUTOSTART_CONFIG = os.path.join(CONFIG_DIR, 'autostart.conf')
LOG_DIR = os.path.join(BASE_DIR, 'logs')
os.makedirs(LOG_DIR, exist_ok=True)
BROWSER_LOG = os.path.join(LOG_DIR, 'browser-launch.log')

# ========== GERENCIADOR DE FAVORITOS (INLINE) ==========
class ChromiumFavoritesManager:
    def __init__(self, username='administrador'):
        self.username = username
        self.home_dir = Path(f'/home/{username}')
        
        # Usa o diretório de perfil personalizado
        self.chromium_profile_dir = self.home_dir / 'chromium-profile'
        # Alias consistente usado pelo restante do código
        self.chromium_dir = self.chromium_profile_dir
        # Perfil ativo atual
        self.active_profile = 'Default'
        
        # Define o arquivo de bookmarks no perfil personalizado
        self.bookmarks_file = self.chromium_profile_dir / 'Default' / 'Bookmarks'
        self.backup_dir = self.chromium_profile_dir / 'bookmarks_backup'
        
        # Garante que o diretório existe
        self.bookmarks_file.parent.mkdir(parents=True, exist_ok=True)
        
        print(f"📁 Usando perfil personalizado: {self.chromium_profile_dir}")
    
    def detect_active_profile(self):
        """Para perfil personalizado, sempre usa 'Default'"""
        return 'Default'
    
    def find_all_profiles(self):
        """Encontra todos os perfis no diretório personalizado - VERSÃO CORRIGIDA"""
        profiles = []
        try:
            if self.chromium_profile_dir.exists():
                for item in os.listdir(self.chromium_profile_dir):
                    item_path = self.chromium_profile_dir / item
                    if item_path.is_dir() and not item.startswith('.') and item != 'bookmarks_backup':
                        has_bookmarks = (item_path / 'Bookmarks').exists()
                        has_preferences = (item_path / 'Preferences').exists()
                        if has_bookmarks or has_preferences:
                            profiles.append(item)
                        else:
                            # ignorar diretórios de cache
                            pass
        except Exception as e:
            print(f"Erro ao listar perfis: {e}")

        if not profiles:
            profiles = ['Default']

        print(f"🔍 Perfis encontrados: {profiles}")
        return profiles

    def sync_to_all_profiles(self, urls):
        """Sincroniza bookmarks em todos os perfis encontrados"""
        all_success = True
        messages = []
        profiles = self.find_all_profiles()
        if not profiles:
            profiles = ['Default']

        for profile in profiles:
            profile_bookmarks = self.chromium_profile_dir / profile / 'Bookmarks'
            profile_bookmarks.parent.mkdir(parents=True, exist_ok=True)

            backup_dir = self.chromium_profile_dir / 'bookmarks_backup' / profile
            backup_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = backup_dir / f'bookmarks_{timestamp}.bak'

            if profile_bookmarks.exists():
                try:
                    shutil.copy2(profile_bookmarks, backup_file)
                except Exception as e:
                    messages.append(f"⚠️ Erro no backup do perfil {profile}: {e}")
                    all_success = False

            try:
                bookmarks_data = self.create_bookmarks_structure(urls, "Sites Gerenciados")
                with open(profile_bookmarks, 'w', encoding='utf-8') as f:
                    json.dump(bookmarks_data, f, indent=2, ensure_ascii=False)

                try:
                    uid, gid = self.get_user_ids()
                    os.chown(profile_bookmarks, uid, gid)
                    os.chmod(profile_bookmarks, 0o644)
                except Exception as perm_error:
                    messages.append(f"⚠️ Aviso de permissões para {profile}: {perm_error}")

                messages.append(f"✅ Perfil {profile}: Sincronizado com {len(urls)} URLs")
            except Exception as e:
                messages.append(f"❌ Erro em {profile}: {e}")
                all_success = False

        return all_success, " | ".join(messages)
        
    def get_user_ids(self):
        """Obtém o UID e GID do usuário"""
        try:
            uid = int(subprocess.check_output(['id', '-u', self.username]).strip())
            gid = int(subprocess.check_output(['id', '-g', self.username]).strip())
            return uid, gid
        except:
            return 1000, 1000
    
    def backup_bookmarks(self):
        """Cria um backup dos bookmarks atuais"""
        try:
            if not self.backup_dir.exists():
                self.backup_dir.mkdir(parents=True, exist_ok=True)
            
            if self.bookmarks_file.exists():
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                backup_file = self.backup_dir / f'bookmarks_{timestamp}.bak'
                shutil.copy2(self.bookmarks_file, backup_file)
                print(f"✅ Backup criado: {backup_file}")
                return True
            return False
        except Exception as e:
            print(f"⚠️ Erro ao criar backup: {e}")
            return False
    
    def load_current_favorites(self):
        """Carrega os favoritos atuais do Chromium"""
        if not self.bookmarks_file.exists():
            print(f"📭 Arquivo de favoritos não encontrado: {self.bookmarks_file}")
            return []
        
        try:
            with open(self.bookmarks_file, 'r', encoding='utf-8') as f:
                data = json.load(f)
            
            favorites = []
            
            def extract_urls(node, folder_name=""):
                if 'children' in node:
                    for child in node.get('children', []):
                        extract_urls(child, node.get('name', folder_name))
                elif node.get('type') == 'url':
                    url = node.get('url', '')
                    name = node.get('name', '')
                    if url and not url.startswith('chrome://'):
                        favorites.append({
                            'url': url,
                            'name': name,
                            'folder': folder_name
                        })
            
            roots = data.get('roots', {})
            for root_key in ['bookmark_bar', 'other', 'synced']:
                if root_key in roots:
                    extract_urls(roots[root_key], root_key)
            
            print(f"📖 {len(favorites)} favoritos carregados")
            return favorites
        except Exception as e:
            print(f"❌ Erro ao carregar favoritos: {e}")
            return []
    
    def create_bookmarks_structure(self, urls, folder_name="Sites Gerenciados"):
        """Cria a estrutura JSON para os bookmarks - VERSÃO CORRIGIDA"""
        import uuid
        import time
        
        # Timestamp atual
        timestamp = int(time.time() * 1000000)
        
        # Cria os itens dos bookmarks
        children = []
        for idx, url in enumerate(urls):
            if not url or not url.strip():
                continue
            
            url = url.strip()
            # Formata o nome baseado na URL
            try:
                parsed = urlparse(url)
                if parsed.scheme and parsed.netloc:
                    name = parsed.netloc.replace('www.', '')
                else:
                    name = url.replace('http://', '').replace('https://', '').split('/')[0]
            except:
                name = f"Site {idx + 1}"
            
            # Cria GUID no formato correto (32 caracteres com hífens)
            guid = str(uuid.uuid4())
            
            children.append({
                "date_added": str(timestamp + idx),
                "guid": guid,
                "id": str(idx + 100),  # IDs únicos
                "meta_info": {"last_visited_desktop": "0"},
                "name": name,
                "type": "url",
                "url": url
            })
        
        if not children:
            # Se não houver URLs, retorna estrutura vazia
            bookmarks_bar = {
                "children": [],
                "date_added": "0",
                "date_modified": "0",
                "guid": "00000000-0000-4000-a000-000000000000",
                "id": "1",
                "name": "Barra de favoritos",
                "type": "folder"
            }
        else:
            # Cria pasta com os sites gerenciados
            managed_folder = {
                "children": children,
                "date_added": str(timestamp),
                "date_modified": str(timestamp),
                "guid": str(uuid.uuid4()),
                "id": "2",
                "name": folder_name,
                "type": "folder"
            }
            
            bookmarks_bar = {
                "children": [managed_folder],
                "date_added": "0",
                "date_modified": "0",
                "guid": "00000000-0000-4000-a000-000000000000",
                "id": "1",
                "name": "Barra de favoritos",
                "type": "folder"
            }
        
        other = {
            "children": [],
            "date_added": "0",
            "date_modified": "0",
            "guid": "00000000-0000-4000-a000-000000000001",
            "id": "3",
            "name": "Outros favoritos",
            "type": "folder"
        }
        
        synced = {
            "children": [],
            "date_added": "0",
            "date_modified": "0",
            "guid": "00000000-0000-4000-a000-000000000002",
            "id": "4",
            "name": "Dispositivos móveis",
            "type": "folder"
        }
        
        return {
            "checksum": "",
            "roots": {
                "bookmark_bar": bookmarks_bar,
                "other": other,
                "synced": synced
            },
            "version": 1
        }
    
    def update_favorites(self, urls, folder_name="Sites Gerenciados"):
        """Atualiza os favoritos do Chromium com as URLs configuradas"""
        try:
            print(f"🔄 Atualizando favoritos com {len(urls)} URLs...")
            
            # 1. Garante que o diretório existe
            self.bookmarks_file.parent.mkdir(parents=True, exist_ok=True)
            
            # 2. Backup dos favoritos atuais
            self.backup_bookmarks()
            
            # 3. Carrega favoritos existentes (para preservar outros)
            existing_favs = self.load_current_favorites()
            print(f"📖 {len(existing_favs)} favoritos existentes encontrados")
            
            # 4. Preserva favoritos que não estão na pasta gerenciada
            preserved_favs = []
            for fav in existing_favs:
                if fav.get('folder') != folder_name and fav.get('folder') != "Sites Gerenciados":
                    preserved_favs.append(fav)
            
            print(f"💾 Preservando {len(preserved_favs)} favoritos não gerenciados")
            
            # 5. Cria nova estrutura combinando preservados + novos
            all_urls = urls.copy()
            combined_favs = preserved_favs + [
                {'url': url, 'name': '', 'folder': folder_name} for url in urls
            ]
            
            # 6. Cria estrutura completa
            bookmarks_data = self.create_bookmarks_structure(all_urls, folder_name)
            
            # 7. Salva o arquivo
            with open(self.bookmarks_file, 'w', encoding='utf-8') as f:
                json.dump(bookmarks_data, f, indent=2, ensure_ascii=False)
            
            # 8. Ajusta permissões
            try:
                uid, gid = self.get_user_ids()
                os.chown(self.bookmarks_file, uid, gid)
                os.chmod(self.bookmarks_file, 0o644)
                
                # Ajusta permissões do diretório também
                for path in [self.bookmarks_file.parent, self.chromium_dir]:
                    if path.exists():
                        os.chown(path, uid, gid)
                        os.chmod(path, 0o755)
            except Exception as perm_error:
                print(f"⚠️ Aviso de permissões: {perm_error}")
            
            print(f"✅ Favoritos atualizados com sucesso")
            return True, f"Favoritos atualizados: {len(urls)} URLs adicionadas, {len(preserved_favs)} preservadas"
            
        except Exception as e:
            print(f"❌ Erro ao atualizar favoritos: {e}")
            import traceback
            traceback.print_exc()
            return False, f"Erro ao atualizar favoritos: {e}"
    
    def sync_favorites_with_config(self, config_urls):
        """Sincroniza favoritos com URLs da configuração"""
        try:
            if not config_urls:
                print("ℹ️ Nenhuma URL para sincronizar")
                # Se não há URLs, apenas garante que a pasta gerenciada existe (vazia)
                return self.update_favorites([], "Sites Gerenciados")
            
            # Garante que as URLs estão formatadas
            formatted_urls = [url.strip() for url in config_urls if url.strip()]
            print(f"🔄 Sincronizando {len(formatted_urls)} URLs...")
            
            # Atualiza favoritos
            success, message = self.update_favorites(formatted_urls)
            
            if success:
                print(f"✅ Favoritos sincronizados com sucesso")
            else:
                print(f"❌ Erro na sincronização: {message}")
            
            return success, message
            
        except Exception as e:
            print(f"❌ Erro na sincronização: {e}")
            import traceback
            traceback.print_exc()
            return False, f"Erro na sincronização: {e}"

# Inicializa o gerenciador
favorites_manager = ChromiumFavoritesManager()

# ========== FUNÇÕES AUXILIARES ==========
def check_auth():
    # Retorna True se a sessão atual estiver autenticada.
    # NÃO logar o conteúdo da sessão aqui (vaza cookies/sessão nos logs).
    return session.get('authenticated')

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
    try:
        if os.path.exists(AUTOSTART_CONFIG):
            with open(AUTOSTART_CONFIG, 'r') as f:
                # Ignora linhas vazias e comentários (começando com '#')
                urls = [
                    line.strip()
                    for line in f.readlines()
                    if line.strip() and not line.strip().startswith('#')
                ]
                print(f"📋 URLs carregadas do autostart.conf: {urls}")
                return urls
        print("📭 Arquivo autostart.conf não encontrado ou vazio")
        return []
        
    except Exception as e:
        print(f"Erro ao carregar URLs: {e}")
        return []

def is_valid_url_or_ip(url):
    url = url.strip()
    if not url:
        return True
    if url.startswith(('http://', 'https://')):
        try:
            result = urlparse(url)
            return all([result.scheme, result.netloc])
        except:
            return False
    ip_port_pattern = r'^(\d{1,3}\.){3}\d{1,3}:\d+$'
    if re.match(ip_port_pattern, url):
        ip_part = url.split(':')[0]; port_part = url.split(':')[1]
        parts = ip_part.split('.')
        if len(parts) == 4:
            for part in parts:
                if not part.isdigit() or not 0 <= int(part) <= 255:
                    return False
            if port_part.isdigit() and 1 <= int(port_part) <= 65535:
                return True
        return False
    ip_pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
    if re.match(ip_pattern, url):
        parts = url.split('.')
        if len(parts) == 4:
            for part in parts:
                if not part.isdigit() or not 0 <= int(part) <= 255:
                    return False
            return True
        return False
    hostname_port_pattern = r'^[a-zA-Z0-9][a-zA-Z0-9.-]*:\d+$'
    if re.match(hostname_port_pattern, url):
        port_part = url.split(':')[1]
        if port_part.isdigit() and 1 <= int(port_part) <= 65535:
            return True
    hostname_pattern = r'^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$'
    if re.match(hostname_pattern, url) or url == 'localhost':
        return True
    return False

def format_url(url):
    if not url.strip():
        return url
    if url.startswith(('http://', 'https://')):
        return url
    if '://' not in url:
        return 'http://' + url
    return url

def sync_chromium_favorites():
    """Sincroniza os favoritos do Chromium com as URLs configuradas em TODOS os perfis"""
    try:
        urls = load_autostart_urls()
        if not urls:
            add_event("ℹ️ Nenhuma URL configurada para sincronizar favoritos")
            return False, "Nenhuma URL configurada"
        
        # Formata URLs
        formatted_urls = [format_url(url.strip()) for url in urls if url.strip()]
        add_event(f"🔄 URLs para sincronizar: {formatted_urls}")
        
        # Sincroniza em TODOS os perfis
        success, message = favorites_manager.sync_to_all_profiles(formatted_urls)
        
        if success:
            add_event(f"✅ Favoritos sincronizados em todos os perfis")
        else:
            add_event(f"⚠️ Aviso: {message}")
        
        return success, message
        
    except Exception as e:
        add_event(f"❌ Erro na sincronização de favoritos: {e}")
        return False, str(e)

def cleanup_chromium_locks():
    """
    Remove todos os arquivos de lock do Chromium para evitar conflitos de hostname.
    Deve ser chamada após alterar o hostname e antes de iniciar o browser.
    """
    import glob

    try:
        add_event("🧹 Iniciando limpeza de locks do Chromium...")

        profile_dir = '/home/administrador/chromium-profile'
        default_profile_dir = '/home/administrador/.config/chromium'
        cache_dir = '/home/administrador/.cache/chromium'

        # 1. Mata processos do Chromium (precisa de sudo; permitido no sudoers)
        subprocess.run(['sudo', 'pkill', '-9', '-f', 'chromium'],
                      stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        time.sleep(1.5)

        # 2. Padrões de lock a remover. Os curingas são expandidos pelo glob do
        #    Python (passá-los direto ao 'rm' via subprocess NÃO expandia nada).
        lock_patterns = [
            'SingletonLock', 'SingletonLock-*', 'SingletonLock.*',
            'SingletonSocket', 'SingletonSocket-*', 'SingletonSocket.*',
            'SingletonCookie', '.com.google.Chrome*',
        ]
        # Diretórios onde procurar (o serviço roda como 'administrador', dono dos
        # arquivos, então os removemos diretamente — sem sudo).
        search_dirs = [
            profile_dir,
            os.path.join(profile_dir, 'Default'),
            default_profile_dir,
            cache_dir,
        ]

        removed = 0
        for d in search_dirs:
            if not os.path.isdir(d):
                continue
            for pattern in lock_patterns:
                for path in glob.glob(os.path.join(d, pattern)):
                    try:
                        os.remove(path)
                        removed += 1
                    except OSError as e:
                        add_event(f"⚠️ Não consegui remover {path}: {e}")

        # 3. Verifica se ainda restou algum lock
        residual = []
        for d in search_dirs:
            if not os.path.isdir(d):
                continue
            for pattern in lock_patterns:
                residual.extend(glob.glob(os.path.join(d, pattern)))

        if residual:
            add_event(f"⚠️ Aviso: locks residuais: {', '.join(residual)[:200]}")
        else:
            add_event(f"✅ Locks do Chromium removidos ({removed} arquivo(s))")

        add_event("🧹 Limpeza do Chromium finalizada")
        return True

    except Exception as e:
        add_event(f"❌ Erro ao limpar locks do Chromium: {e}")
        # Não levanta exceção - apenas loga e continua
        return False

def open_browser_with_urls():
    """Abre o browser com URLs configuradas e perfil específico"""
    time.sleep(10)  # Aguarda mais tempo para sistema estar pronto
    
    try:
        # 1. SEMPRE limpa locks antes de abrir (garantia)
        add_event("🧹 Executando limpeza preventiva de locks...")
        cleanup_chromium_locks()
        
        # 2. Primeiro garante que os favoritos estão sincronizados
        add_event("🔄 Sincronizando favoritos antes de abrir browser...")
        success, message = sync_chromium_favorites()
        add_event(f"📋 Resultado da sincronização: {message}")
        
        # 3. Carrega URLs
        urls = load_autostart_urls()
        if not urls:
            add_event("ℹ️ Nenhuma URL configurada no autostart.conf")
            return
        
        add_event(f"🎯 Abrindo {len(urls)} URLs no browser...")
        
        # 4. Verifica se o display está disponível
        display_check = subprocess.run(['sudo', '-u', 'administrador', 'env', 'DISPLAY=:0', 'xdpyinfo'],
                                     stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        if display_check.returncode != 0:
            add_event("⚠️ Display :0 não está disponível, tentando mesmo assim...")
        
        # 5. Comando para abrir Chromium COM FLAGS ANTILOCK
        cmd = [
            'sudo', '-u', 'administrador',
            'env', 'DISPLAY=:0',
            'chromium-browser' if os.path.exists('/usr/bin/chromium-browser') else 'chromium',
            '--user-data-dir=/home/administrador/chromium-profile',
            '--no-first-run',
            '--start-maximized',
            '--ignore-certificate-errors',
            '--noerrdialogs',
            '--disable-session-crashed-bubble',
            '--disable-single-process',
            '--disable-features=ChromeWhatsNewUI',
            '--disable-features=SingleProcess',
            '--disable-features=ProcessPerSite',
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
        
        # Adiciona URLs
        for url in urls:
            if url.strip():
                formatted_url = format_url(url.strip())
                cmd.append(formatted_url)
        
        add_event(f"🚀 Executando Chromium com perfil específico...")
        
        # Executa em background
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL
        )
        
        add_event(f"✅ Browser iniciado com PID {process.pid}")
        
        # Verifica se realmente abriu
        time.sleep(3)
        result = subprocess.run(['pgrep', '-f', 'chromium'], 
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if result.stdout.strip():
            pids = result.stdout.strip().split('\n')
            add_event(f"✅ Chromium está rodando ({len(pids)} processos)")
        else:
            add_event("⚠️ Chromium pode não ter iniciado corretamente")
        
    except Exception as e:
        add_event(f"❌ Erro ao abrir browser: {e}")
        import traceback
        traceback.print_exc()

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
        except:
            try:
                model = subprocess.check_output(['cat', '/sys/firmware/devicetree/base/model'], 
                                              text=True).strip('\x00')
            except:
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
        except:
            try:
                with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                    temp_raw = int(f.read().strip())
                    temperature = f"{temp_raw / 1000:.1f}°C"
            except:
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
        except:
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
            'kernel': kernel
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
                for line in ip_result.stdout.strip().split('\n'):
                    if line and ':' in line:
                        _, ip = line.split(':', 1)
                        ip = ip.strip()
                        if ip:
                            ip4 = ip.split('/')[0]
                            break
        
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
    data = request.json or {}
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
    """Altera o hostname do sistema e limpa os locks do Chromium"""
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    data = request.json
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
            # ✅ SUCESSO: Agora limpa os locks do Chromium
            add_event(f"✅ Hostname alterado para {new_hostname}. Iniciando limpeza do Chromium...")
            
            # Mata o Chromium se estiver rodando
            try:
                subprocess.run(['sudo', 'pkill', '-f', 'chromium'], 
                             stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
                time.sleep(1)
            except:
                pass
            
            # Limpa todos os locks
            cleanup_success = cleanup_chromium_locks()
            
            if cleanup_success:
                add_event(f"✅ Hostname alterado e Chromium limpo com sucesso")
                return jsonify({
                    'success': True, 
                    'message': 'Hostname alterado com sucesso. Chromium foi reiniciado e locks limpos.'
                })
            else:
                add_event(f"⚠️ Hostname alterado mas houve problemas na limpeza do Chromium")
                return jsonify({
                    'success': True, 
                    'warning': True,
                    'message': 'Hostname alterado, mas houve avisos na limpeza do Chromium. O browser pode precisar ser reiniciado manualmente.'
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
    data = request.json
    new_password = data.get('password')
    try:
        if not new_password or len(new_password) < 3:
            return jsonify({'error': 'Senha deve ter pelo menos 3 caracteres'}), 400
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
        subprocess.run(['sudo', 'shutdown', '-r', '+1'], capture_output=True)
        return jsonify({'success': True, 'message': 'Sistema será reiniciado em 1 minuto'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/shutdown', methods=['POST'])
def shutdown_system():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        subprocess.run(['sudo', 'shutdown', '-h', '+1'], capture_output=True)
        return jsonify({'success': True, 'message': 'Sistema será desligado em 1 minuto'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/reboot-now', methods=['POST'])
def reboot_now():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        subprocess.run(['sudo', 'shutdown', '-r', 'now'], capture_output=True)
        return jsonify({'success': True, 'message': 'Reiniciando agora...'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/shutdown-now', methods=['POST'])
def shutdown_now():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        subprocess.run(['sudo', 'shutdown', '-h', 'now'], capture_output=True)
        return jsonify({'success': True, 'message': 'Desligando agora...'})
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
        # Use fields supported by nmcli for device/general info and IP addresses
        ip_result = run_nmcli(['-t', '-f', 'GENERAL.DEVICE,IP4.ADDRESS,IP6.ADDRESS', 'dev', 'show'])
        
        # Build device->IP mapping
        device_ips = {}
        if ip_result.returncode == 0:
            current_device = None
            for line in ip_result.stdout.strip().split('\n'):
                if not line or ':' not in line:
                    continue
                key, val = line.split(':', 1)
                key = key.strip(); val = val.strip()
                if key.startswith('GENERAL.DEVICE'):
                    current_device = val
                    device_ips[current_device] = {}
                elif key.startswith('IP4.ADDRESS') and current_device:
                    if val and not device_ips[current_device].get('ip4'):
                        # Take only the first IP if multiple
                        device_ips[current_device]['ip4'] = val.split('/')[0] if val else ''
                elif key.startswith('IP6.ADDRESS') and current_device:
                    if val and not device_ips[current_device].get('ip6'):
                        # Take only the first IP if multiple
                        device_ips[current_device]['ip6'] = val.split('/')[0] if val else ''
        
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
                parts = line.split(':')
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
    data = request.json
    connection_type = data.get('type')
    connection_name = data.get('name')
    ip_type = data.get('ip_type', 'dhcp')
    
    try:
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
                # Connection exists, just modify IP settings
                result = run_nmcli(['connection', 'modify', connection_name])
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
        data = request.json
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
                except:
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
    
    data = request.json
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
        
        # 2. Formata URLs
        formatted_urls = [format_url(url.strip()) for url in urls if url.strip()]
        
        # 3. Atualiza diretamente (sem preservar)
        success, message = favorites_manager.update_favorites(formatted_urls)
        
        if success:
            # 4. Força recarregamento no Chromium
            try:
                # Envia sinal para Chromium recarregar favoritos
                subprocess.run(['sudo', 'pkill', '-HUP', 'chromium'], 
                              capture_output=True, stderr=subprocess.DEVNULL)
            except:
                pass
            
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
            cmd = [
                'sudo', '-u', 'administrador',
                'env', 'DISPLAY=:0',
                'chromium',
                '--user-data-dir=/home/administrador/chromium-profile',
                '--ignore-certificate-errors',
                '--start-maximized',
                '--no-first-run',
                '--disable-dbus',
                '--noerrdialogs',
                '--disable-infobars',
                '--disable-single-process',
                '--disable-features=SingleProcess'
            ]
            formatted_urls = [format_url(url) for url in urls if url.strip()]
            cmd.extend(formatted_urls)
            subprocess.Popen(cmd)
            add_event("✅ Browser reiniciado com perfil específico e locks limpos")
            return jsonify({
                'success': True, 
                'message': 'Browser reiniciado com locks limpos e favoritos sincronizados'
            })
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
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401

    wrappers = [NMCLI_WRAPPER, CHPASS_WRAPPER, HOSTNAME_WRAPPER]
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


# (Removido) /api/diagnostic/session: endpoint de debug que expunha sessão e
# cookies sem autenticação. Não tem uso em produção e era um risco de segurança.

# ========== PÁGINAS WEB (ROTAS SIMPLES) ==========
@app.route('/login', methods=['GET', 'POST'])
def login():
    """Rota de login simples. Usa `ADMIN_PASSWORD` no ambiente ou 'admin' por padrão."""
    if request.method == 'POST':
        # aceita formulário ou JSON
        password = request.form.get('password') if request.form else None
        if not password and request.is_json:
            password = (request.get_json() or {}).get('password')

        # Por padrão, use a senha esperada para o usuário 'administrador'
        admin_pass = os.environ.get('ADMIN_PASSWORD', 'sil123')
        if password and password == admin_pass:
            session['authenticated'] = True
            return redirect(url_for('index'))
        # mostrar página com erro
        return render_template('login.html', error='Senha inválida')
    return render_template('login.html')


@app.route('/logout')
def logout():
    session.pop('authenticated', None)
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
        formatted_urls = [format_url(url.strip()) for url in urls if url.strip()]
        success, message = favorites_manager.sync_favorites_with_config(formatted_urls)
        if success:
            print(f"✅ {message}")
        else:
            print(f"❌ Erro: {message}")
    
    # Fallback para abrir URLs
    print("⏰ Iniciando thread para abrir browser em 10 segundos...")
    time.sleep(3)  # Aguarda mais para sincronização terminar
    browser_thread = threading.Thread(target=open_browser_with_urls)
    browser_thread.daemon = True
    browser_thread.start()

with app.app_context():
    startup_tasks()


@app.route('/about')
def about():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('about.html')


# NOTA: o endpoint /webhook (modelo PUSH via GitHub Actions) foi removido.
# A atualização agora é feita pelo modelo PULL: cada Pi verifica o GitHub 1x por
# semana, em dia aleatório (raspberry-pi-manager-update.timer / update_app.sh).

if __name__ == '__main__':
    debug_mode = os.environ.get('DEBUG', 'False').lower() == 'true'
    # Por padrão o Flask escuta só em 127.0.0.1 (localhost), porque o acesso
    # externo passa pelo nginx em HTTPS. Para rodar sem nginx (dev), defina
    # FLASK_HOST=0.0.0.0 no ambiente.
    host = os.environ.get('FLASK_HOST', '127.0.0.1')
    port = int(os.environ.get('FLASK_PORT', '5000'))
    print(f"🚀 Iniciando servidor Flask em modo {'debug' if debug_mode else 'produção'}...")
    print(f"🌐 Escutando em: http://{host}:{port} (acesso externo via nginx/HTTPS)")
    app.run(host=host, port=port, debug=debug_mode, threaded=True)