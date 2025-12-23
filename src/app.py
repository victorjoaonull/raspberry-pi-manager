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
import hashlib
from pathlib import Path
from datetime import datetime

app = Flask(__name__)
app.secret_key = 'sua_chave_secreta_aqui_altere_para_uma_chave_segura'

# Configurações
CONFIG_DIR = '/home/administrador/pi-manager/config'
NETWORK_CONFIG = os.path.join(CONFIG_DIR, 'network.conf')
AUTOSTART_CONFIG = os.path.join(CONFIG_DIR, 'autostart.conf')

# ========== GERENCIADOR DE FAVORITOS (INLINE) ==========
class ChromiumFavoritesManager:
    def __init__(self, username='administrador'):
        self.username = username
        self.home_dir = Path(f'/home/{username}')
        
        # Usa o diretório de perfil personalizado
        self.chromium_profile_dir = self.home_dir / 'chromium-profile'
        
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
                        # Verifica se parece ser um perfil (tem Bookmarks ou Preferences)
                        has_bookmarks = (item_path / 'Bookmarks').exists()
                        has_preferences = (item_path / 'Preferences').exists()
                        
                        # Só inclui se for um perfil real, não cache
                        if has_bookmarks or has_preferences:
                            profiles.append(item)
                            print(f"  ✅ Perfil válido: {item}")
                        else:
                            print(f"  ⚠️ Ignorando diretório de cache: {item}")
        except Exception as e:
            print(f"Erro ao listar perfis: {e}")
        
        # Se não encontrar nenhum, usa Default
        if not profiles:
            profiles = ['Default']
        
        print(f"🔍 Perfis encontrados: {profiles}")
        return profiles
    
    def sync_to_all_profiles(self, urls):
        """Sincroniza favoritos em TODOS os perfis encontrados - VERSÃO CORRIGIDA"""
        all_success = True
        messages = []
        
        profiles = self.find_all_profiles()
        print(f"🔍 Encontrados {len(profiles)} perfis válidos")
        
        if not profiles:
            print("⚠️ Nenhum perfil encontrado, usando Default")
            profiles = ['Default']
        
        for profile in profiles:
            print(f"🔄 Sincronizando perfil: {profile}")
            profile_bookmarks = self.chromium_profile_dir / profile / 'Bookmarks'
            
            # Cria diretório se não existir
            profile_bookmarks.parent.mkdir(parents=True, exist_ok=True)
            
            # Cria backup
            backup_dir = self.chromium_profile_dir / 'bookmarks_backup' / profile
            backup_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = backup_dir / f'bookmarks_{timestamp}.bak'
            
            if profile_bookmarks.exists():
                try:
                    shutil.copy2(profile_bookmarks, backup_file)
                except Exception as e:
                    print(f"⚠️ Erro no backup do perfil {profile}: {e}")
            
            # Atualiza favoritos neste perfil
            try:
                # Salva estrutura de bookmarks
                bookmarks_data = self.create_bookmarks_structure(urls, "Sites Gerenciados")
                
                with open(profile_bookmarks, 'w', encoding='utf-8') as f:
                    json.dump(bookmarks_data, f, indent=2, ensure_ascii=False)
                
                # Ajusta permissões
                uid, gid = self.get_user_ids()
                os.chown(profile_bookmarks, uid, gid)
                os.chmod(profile_bookmarks, 0o644)
                
                messages.append(f"✅ Perfil {profile}: Sincronizado com {len(urls)} URLs")
                print(f"✅ Perfil {profile} sincronizado")
                
            except Exception as e:
                error_msg = f"❌ Erro em {profile}: {str(e)}"
                messages.append(error_msg)
                print(error_msg)
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
                urls = [line.strip() for line in f.readlines() if line.strip()]
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
            print("ℹ️ Nenhuma URL configurada para sincronizar favoritos")
            return False, "Nenhuma URL configurada"
        
        # Formata URLs
        formatted_urls = [format_url(url.strip()) for url in urls if url.strip()]
        print(f"🔄 URLs para sincronizar: {formatted_urls}")
        
        # Sincroniza em TODOS os perfis
        success, message = favorites_manager.sync_to_all_profiles(formatted_urls)
        
        if success:
            print(f"✅ Favoritos sincronizados em todos os perfis")
        else:
            print(f"⚠️ Aviso: {message}")
        
        return success, message
        
    except Exception as e:
        print(f"❌ Erro na sincronização de favoritos: {e}")
        return False, str(e)
    
def open_browser_with_urls():
    """Abre o browser com URLs configuradas e perfil específico"""
    time.sleep(10)  # Aguarda mais tempo para sistema estar pronto
    
    try:
        # 1. Primeiro garante que os favoritos estão sincronizados
        print("🔄 Sincronizando favoritos antes de abrir browser...")
        success, message = sync_chromium_favorites()
        print(f"📋 Resultado da sincronização: {message}")
        
        # 2. Carrega URLs
        urls = load_autostart_urls()
        if not urls:
            print("ℹ️ Nenhuma URL configurada no autostart.conf")
            return
        
        print(f"🎯 Abrindo {len(urls)} URLs no browser...")
        
        # 3. Comando para abrir Chromium COM DIRETÓRIO DE PERFIL ESPECÍFICO
        cmd = [
            'sudo', '-u', 'administrador',
            'env', 'DISPLAY=:0',
            'chromium',
            '--user-data-dir=/home/administrador/chromium-profile',  # DIRETÓRIO ESPECÍFICO
            '--no-first-run',
            '--start-maximized',
            '--ignore-certificate-errors',
            '--noerrdialogs',
            '--disable-session-crashed-bubble'
        ]
        
        # Adiciona URLs
        for url in urls:
            if url.strip():
                formatted_url = format_url(url.strip())
                cmd.append(formatted_url)
        
        print(f"🚀 Executando com perfil específico: {' '.join(cmd[:10])}...")
        
        # Executa em background
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL
        )
        
        print(f"✅ Browser iniciado com PID {process.pid}")
        
        # Verifica se realmente abriu
        time.sleep(3)
        result = subprocess.run(['pgrep', '-f', 'chromium'], capture_output=True, text=True)
        if result.stdout.strip():
            print(f"✅ Chromium está rodando (PIDs: {result.stdout.strip()})")
        else:
            print("⚠️ Chromium pode não ter iniciado corretamente")
        
    except Exception as e:
        print(f"❌ Erro ao abrir browser: {e}")
        import traceback
        traceback.print_exc()

# ========== ROTAS ==========
@app.route('/')
def index():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('index.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        password = request.form.get('password')
        try:
            result = subprocess.run(
                ['sudo', '-k', '-S', 'echo', 'success'],
                input=password + '\n',
                text=True,
                capture_output=True
            )
            if result.returncode == 0:
                session['authenticated'] = True
                return redirect(url_for('index'))
            else:
                return render_template('login.html', error='Senha incorreta')
        except Exception:
            return render_template('login.html', error='Erro ao verificar senha')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('authenticated', None)
    return redirect(url_for('login'))

@app.route('/network')
def network():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('network.html')

@app.route('/system')
def system():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('system.html')

@app.route('/autostart')
def autostart():
    if not check_auth():
        return redirect(url_for('login'))
    return render_template('autostart.html')

# ========== API - SISTEMA ==========
@app.route('/api/system/info')
def get_system_info():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        hostname_result = subprocess.run(['hostname'], capture_output=True, text=True)
        hostname = hostname_result.stdout.strip() if hostname_result.returncode == 0 else "N/A"
        model_result = subprocess.run(['cat', '/proc/device-tree/model'], capture_output=True, text=True)
        model = model_result.stdout.strip() if model_result.returncode == 0 else "Raspberry Pi"
        uptime_result = subprocess.run(['uptime', '-p'], capture_output=True, text=True)
        uptime = uptime_result.stdout.strip() if uptime_result.returncode == 0 else "N/A"
        temp_result = subprocess.run(['cat', '/sys/class/thermal/thermal_zone0/temp'], capture_output=True, text=True)
        if temp_result.returncode == 0 and temp_result.stdout.strip():
            temp_c = int(temp_result.stdout.strip()) / 1000.0
            temperature = f"{temp_c:.1f}°C"
        else:
            temperature = "N/A"
        cpu_usage = get_cpu_usage()
        memory_usage = get_memory_usage()
        return jsonify({
            'hostname': hostname,
            'model': model,
            'uptime': uptime,
            'temperature': temperature,
            'cpu_usage': cpu_usage,
            'memory_usage': memory_usage
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/system/hostname', methods=['POST'])
def change_hostname():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    data = request.json
    new_hostname = data.get('hostname')
    try:
        if not new_hostname or len(new_hostname) < 2:
            return jsonify({'error': 'Hostname deve ter pelo menos 2 caracteres'}), 400
        if not re.match(r'^[a-zA-Z0-9-]{1,63}$', new_hostname):
            return jsonify({'error': 'Hostname inválido. Use apenas letras, números e hífens'}), 400
        subprocess.run(['sudo', 'hostnamectl', 'set-hostname', new_hostname], capture_output=True, text=True)
        subprocess.run(['sudo', 'sed', '-i', f's/.*/{new_hostname}/', '/etc/hostname'], capture_output=True, text=True)
        subprocess.run(['sudo', 'sed', '-i', f's/127.0.1.1.*/127.0.1.1\\t{new_hostname}/', '/etc/hosts'], capture_output=True, text=True)
        return jsonify({'success': True, 'message': 'Hostname alterado com sucesso. Reinicie o sistema para aplicar completamente.'})
    except Exception as e:
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
        result = subprocess.run(['sudo', 'chpasswd'], input=f'administrador:{new_password}', text=True, capture_output=True)
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
        result = subprocess.run(['sudo', 'nmcli', '-t', '-f', 'NAME,DEVICE,TYPE,STATE', 'con', 'show', '--active'], capture_output=True, text=True)
        connections = []
        for line in result.stdout.strip().split('\n'):
            if line:
                parts = line.split(':')
                if len(parts) >= 4:
                    name, device, con_type, state = parts[:4]
                    connections.append({'name': name, 'device': device, 'type': con_type, 'state': state})
        ip_result = subprocess.run(['sudo', 'nmcli', '-t', '-f', 'IP4,IP6,DEVICE', 'dev', 'show'], capture_output=True, text=True)
        devices = []; current_device = {}
        for line in ip_result.stdout.strip().split('\n'):
            if line:
                if line.startswith('IP4'):
                    ip_info = line.split(':',1)[1]
                    if '[' in ip_info:
                        current_device['ip4'] = ip_info.split('/')[0]
                elif line.startswith('DEVICE'):
                    if current_device:
                        devices.append(current_device)
                    current_device = {'device': line.split(':',1)[1]}
        if current_device:
            devices.append(current_device)
        return jsonify({'connections': connections, 'devices': devices})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/network/wifi/list')
def scan_wifi():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    try:
        result = subprocess.run(['sudo', 'nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'dev', 'wifi', 'list'], capture_output=True, text=True)
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
    try:
        if connection_type == 'wifi':
            ssid = data.get('ssid'); password = data.get('password')
            cmd = ['sudo', 'nmcli', 'dev', 'wifi', 'connect', ssid]
            if password: cmd.extend(['password', password])
            if connection_name: cmd.extend(['name', connection_name])
            result = subprocess.run(cmd, capture_output=True, text=True)
        elif connection_type == 'ethernet':
            if connection_name:
                cmd = ['sudo', 'nmcli', 'con', 'add', 'type', 'ethernet', 'con-name', connection_name, 'ifname', 'eth0']
            else:
                cmd = ['sudo', 'nmcli', 'con', 'add', 'type', 'ethernet', 'ifname', 'eth0']
            result = subprocess.run(cmd, capture_output=True, text=True)
        elif connection_type == 'static':
            ip_address = data.get('ip_address'); gateway = data.get('gateway'); dns = data.get('dns')
            cmd = [
                'sudo', 'nmcli', 'con', 'modify', connection_name,
                'ipv4.addresses', ip_address,
                'ipv4.gateway', gateway,
                'ipv4.dns', dns,
                'ipv4.method', 'manual'
            ]
            result = subprocess.run(cmd, capture_output=True, text=True)
        elif connection_type == 'toggle':
            action = data.get('action', 'up')
            result = subprocess.run(['sudo', 'nmcli', 'con', action, connection_name], capture_output=True, text=True)
        else:
            return jsonify({'error': 'Tipo de configuração inválido'}), 400
        if result.returncode == 0:
            if connection_name and connection_type in ('ethernet', 'static'):
                subprocess.run(['sudo', 'nmcli', 'con', 'down', connection_name], capture_output=True)
                subprocess.run(['sudo', 'nmcli', 'con', 'up', connection_name], capture_output=True)
            return jsonify({'success': True, 'message': 'Rede configurada com sucesso'})
        else:
            return jsonify({'error': result.stderr}), 500
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

# ========== API - SISTEMA (MODIFICADA) ==========
@app.route('/api/system/restart-browser', methods=['POST'])
def restart_browser():
    if not check_auth():
        return jsonify({'error': 'Não autenticado'}), 401
    
    try:
        # 1. Sincroniza favoritos primeiro
        sync_chromium_favorites()
        
        # 2. Mata processo do Chromium
        subprocess.run(['sudo', 'pkill', '-f', 'chromium'], capture_output=True)
        time.sleep(2)
        
        # 3. Reabre com perfil específico
        urls = load_autostart_urls()
        if urls:
            cmd = [
                'sudo', '-u', 'administrador',
                'env', 'DISPLAY=:0',
                'chromium',
                '--user-data-dir=/home/administrador/chromium-profile',  # DIRETÓRIO ESPECÍFICO
                '--ignore-certificate-errors',
                '--start-maximized',
                '--no-first-run',
                '--disable-dbus',
                '--noerrdialogs',
                '--disable-infobars'
            ]
            formatted_urls = [format_url(url) for url in urls if url.strip()]
            cmd.extend(formatted_urls)
            subprocess.Popen(cmd)
            return jsonify({'success': True, 'message': 'Browser reiniciado com perfil específico e favoritos sincronizados'})
        else:
            return jsonify({'success': True, 'message': 'Browser fechado (nenhuma URL configurada)'})
    except Exception as e:
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

if __name__ == '__main__':
    debug_mode = os.environ.get('DEBUG', 'False').lower() == 'true'
    print(f"🚀 Iniciando servidor Flask em modo {'debug' if debug_mode else 'produção'}...")
    print(f"🌐 Acesse em: http://0.0.0.0:5000")
    app.run(host='0.0.0.0', port=5000, debug=debug_mode, threaded=True)