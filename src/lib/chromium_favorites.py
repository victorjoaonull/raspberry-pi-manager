"""
Sincronização de favoritos do Chromium com a pasta gerida (sem sobrescrever Bookmarks inteiro).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse


class ChromiumFavoritesManager:
    def __init__(self, username: str = "administrador", chromium_user_data_dir: str | None = None):
        self.username = username
        self.home_dir = Path(f"/home/{username}")
        # Mesmo caminho que --user-data-dir no autostart (env PI_MANAGER_CHROMIUM_USER_DATA_DIR)
        self.chromium_profile_dir = Path(
            chromium_user_data_dir or "/home/administrador/chromium-profile"
        )
        self.chromium_dir = self.chromium_profile_dir
        self.active_profile = "Default"

        self.bookmarks_file = self.chromium_profile_dir / "Default" / "Bookmarks"
        self.backup_dir = self.chromium_profile_dir / "bookmarks_backup"

        self.bookmarks_file.parent.mkdir(parents=True, exist_ok=True)

        print(f"📁 Usando perfil personalizado: {self.chromium_profile_dir}")

    def detect_active_profile(self):
        """Para perfil personalizado, sempre usa 'Default'"""
        return "Default"

    def find_all_profiles(self):
        """Encontra todos os perfis no diretório personalizado - VERSÃO CORRIGIDA"""
        profiles = []
        try:
            if self.chromium_profile_dir.exists():
                for item in os.listdir(self.chromium_profile_dir):
                    item_path = self.chromium_profile_dir / item
                    if item_path.is_dir() and not item.startswith(".") and item != "bookmarks_backup":
                        has_bookmarks = (item_path / "Bookmarks").exists()
                        has_preferences = (item_path / "Preferences").exists()
                        if has_bookmarks or has_preferences:
                            profiles.append(item)
        except OSError as e:
            print(f"Erro ao listar perfis: {e}")

        if not profiles:
            profiles = ["Default"]

        print(f"🔍 Perfis encontrados: {profiles}")
        return profiles

    def sync_to_all_profiles(self, urls):
        """Sincroniza bookmarks em todos os perfis encontrados"""
        all_success = True
        messages = []
        profiles = self.find_all_profiles()
        if not profiles:
            profiles = ["Default"]

        folder_name = "Sites Gerenciados"

        for profile in profiles:
            profile_bookmarks = self.chromium_profile_dir / profile / "Bookmarks"
            profile_bookmarks.parent.mkdir(parents=True, exist_ok=True)

            backup_dir = self.chromium_profile_dir / "bookmarks_backup" / profile
            backup_dir.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = backup_dir / f"bookmarks_{timestamp}.bak"

            if profile_bookmarks.exists():
                try:
                    shutil.copy2(profile_bookmarks, backup_file)
                except OSError as e:
                    messages.append(f"⚠️ Erro no backup do perfil {profile}: {e}")
                    all_success = False

            try:
                if profile_bookmarks.exists():
                    with open(profile_bookmarks, "r", encoding="utf-8") as f:
                        bookmarks_data = json.load(f)
                else:
                    bookmarks_data = self.create_bookmarks_structure([], folder_name)

                bookmarks_data = self._upsert_managed_folder_in_bookmarks(
                    bookmarks_data, urls, folder_name
                )
                with open(profile_bookmarks, "w", encoding="utf-8") as f:
                    json.dump(bookmarks_data, f, indent=2, ensure_ascii=False)

                try:
                    uid, gid = self.get_user_ids()
                    os.chown(profile_bookmarks, uid, gid)
                    os.chmod(profile_bookmarks, 0o644)
                except OSError as perm_error:
                    messages.append(f"⚠️ Aviso de permissões para {profile}: {perm_error}")

                messages.append(f"✅ Perfil {profile}: Sincronizado com {len(urls)} URLs")
            except (OSError, json.JSONDecodeError, TypeError, ValueError) as e:
                messages.append(f"❌ Erro em {profile}: {e}")
                all_success = False

        return all_success, " | ".join(messages)

    def get_user_ids(self):
        """Obtém o UID e GID do usuário"""
        try:
            uid = int(subprocess.check_output(["id", "-u", self.username]).strip())
            gid = int(subprocess.check_output(["id", "-g", self.username]).strip())
            return uid, gid
        except (subprocess.CalledProcessError, ValueError, OSError):
            return 1000, 1000

    def backup_bookmarks(self):
        """Cria um backup dos bookmarks atuais"""
        try:
            if not self.backup_dir.exists():
                self.backup_dir.mkdir(parents=True, exist_ok=True)

            if self.bookmarks_file.exists():
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                backup_file = self.backup_dir / f"bookmarks_{timestamp}.bak"
                shutil.copy2(self.bookmarks_file, backup_file)
                print(f"✅ Backup criado: {backup_file}")
                return True
            return False
        except OSError as e:
            print(f"⚠️ Erro ao criar backup: {e}")
            return False

    def load_current_favorites(self):
        """Carrega os favoritos atuais do Chromium"""
        if not self.bookmarks_file.exists():
            print(f"📭 Arquivo de favoritos não encontrado: {self.bookmarks_file}")
            return []

        try:
            with open(self.bookmarks_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            favorites = []

            def extract_urls(node, folder_name=""):
                if "children" in node:
                    for child in node.get("children", []):
                        extract_urls(child, node.get("name", folder_name))
                elif node.get("type") == "url":
                    url = node.get("url", "")
                    name = node.get("name", "")
                    if url and not url.startswith("chrome://"):
                        favorites.append({"url": url, "name": name, "folder": folder_name})

            roots = data.get("roots", {})
            for root_key in ["bookmark_bar", "other", "synced"]:
                if root_key in roots:
                    extract_urls(roots[root_key], root_key)

            print(f"📖 {len(favorites)} favoritos carregados")
            return favorites
        except (OSError, json.JSONDecodeError, TypeError) as e:
            print(f"❌ Erro ao carregar favoritos: {e}")
            return []

    def create_bookmarks_structure(self, urls, folder_name="Sites Gerenciados"):
        """Cria a estrutura JSON para os bookmarks - VERSÃO CORRIGIDA"""
        timestamp = int(time.time() * 1000000)

        children = []
        for idx, url in enumerate(urls):
            if not url or not url.strip():
                continue

            url = url.strip()
            try:
                parsed = urlparse(url)
                if parsed.scheme and parsed.netloc:
                    name = parsed.netloc.replace("www.", "")
                else:
                    name = url.replace("http://", "").replace("https://", "").split("/")[0]
            except (ValueError, TypeError):
                name = f"Site {idx + 1}"

            guid = str(uuid.uuid4())

            children.append(
                {
                    "date_added": str(timestamp + idx),
                    "guid": guid,
                    "id": str(idx + 100),
                    "meta_info": {"last_visited_desktop": "0"},
                    "name": name,
                    "type": "url",
                    "url": url,
                }
            )

        if not children:
            bookmarks_bar = {
                "children": [],
                "date_added": "0",
                "date_modified": "0",
                "guid": "00000000-0000-4000-a000-000000000000",
                "id": "1",
                "name": "Barra de favoritos",
                "type": "folder",
            }
        else:
            managed_folder = {
                "children": children,
                "date_added": str(timestamp),
                "date_modified": str(timestamp),
                "guid": str(uuid.uuid4()),
                "id": "2",
                "name": folder_name,
                "type": "folder",
            }

            bookmarks_bar = {
                "children": [managed_folder],
                "date_added": "0",
                "date_modified": "0",
                "guid": "00000000-0000-4000-a000-000000000000",
                "id": "1",
                "name": "Barra de favoritos",
                "type": "folder",
            }

        other = {
            "children": [],
            "date_added": "0",
            "date_modified": "0",
            "guid": "00000000-0000-4000-a000-000000000001",
            "id": "3",
            "name": "Outros favoritos",
            "type": "folder",
        }

        synced = {
            "children": [],
            "date_added": "0",
            "date_modified": "0",
            "guid": "00000000-0000-4000-a000-000000000002",
            "id": "4",
            "name": "Dispositivos móveis",
            "type": "folder",
        }

        return {
            "checksum": "",
            "roots": {
                "bookmark_bar": bookmarks_bar,
                "other": other,
                "synced": synced,
            },
            "version": 1,
        }

    def _upsert_managed_folder_in_bookmarks(self, bookmarks_data, urls, folder_name):
        """
        Atualiza SOMENTE a pasta gerenciada (folder_name) dentro de um JSON de Bookmarks do Chromium,
        preservando o restante (roots 'other' e 'synced' e outros favoritos).
        """
        roots = bookmarks_data.setdefault("roots", {})
        bookmark_bar = roots.setdefault("bookmark_bar", {})

        children = bookmark_bar.get("children")
        if not isinstance(children, list):
            children = []
        bookmark_bar["children"] = children

        managed_node = None
        for node in children:
            if node.get("type") == "folder" and node.get("name") == folder_name:
                managed_node = node
                break

        if not urls:
            if managed_node:
                managed_node["children"] = []
                managed_node["date_modified"] = str(int(time.time() * 1000000))
            return bookmarks_data

        temp = self.create_bookmarks_structure(urls, folder_name)
        temp_children = temp.get("roots", {}).get("bookmark_bar", {}).get("children", [])

        new_managed_node = None
        for node in temp_children:
            if node.get("type") == "folder" and node.get("name") == folder_name:
                new_managed_node = node
                break

        if new_managed_node is None and temp_children:
            new_managed_node = temp_children[0]

        if new_managed_node is None:
            return bookmarks_data

        if managed_node:
            idx = children.index(managed_node)
            children[idx] = new_managed_node
        else:
            children.append(new_managed_node)

        bookmark_bar["children"] = children
        return bookmarks_data

    def update_favorites(self, urls, folder_name="Sites Gerenciados"):
        """Atualiza os favoritos do Chromium com as URLs configuradas"""
        try:
            print(f"🔄 Atualizando favoritos com {len(urls)} URLs...")

            self.bookmarks_file.parent.mkdir(parents=True, exist_ok=True)

            self.backup_bookmarks()

            if self.bookmarks_file.exists():
                with open(self.bookmarks_file, "r", encoding="utf-8") as f:
                    bookmarks_data = json.load(f)
            else:
                bookmarks_data = self.create_bookmarks_structure([], folder_name)

            try:
                existing_favs = self.load_current_favorites()
                preserved_count = sum(
                    1
                    for fav in existing_favs
                    if fav.get("folder") != folder_name and fav.get("folder") != "Sites Gerenciados"
                )
            except (OSError, TypeError):
                preserved_count = 0

            bookmarks_data = self._upsert_managed_folder_in_bookmarks(
                bookmarks_data, urls, folder_name
            )

            with open(self.bookmarks_file, "w", encoding="utf-8") as f:
                json.dump(bookmarks_data, f, indent=2, ensure_ascii=False)

            try:
                uid, gid = self.get_user_ids()
                os.chown(self.bookmarks_file, uid, gid)
                os.chmod(self.bookmarks_file, 0o644)

                for path in [self.bookmarks_file.parent, self.chromium_dir]:
                    if path.exists():
                        os.chown(path, uid, gid)
                        os.chmod(path, 0o755)
            except OSError as perm_error:
                print(f"⚠️ Aviso de permissões: {perm_error}")

            print("✅ Favoritos atualizados com sucesso")
            return True, (
                f"Favoritos atualizados: {len(urls)} URLs definidas, {preserved_count} preservadas"
            )

        except (OSError, json.JSONDecodeError, TypeError, ValueError) as e:
            print(f"❌ Erro ao atualizar favoritos: {e}")
            import traceback

            traceback.print_exc()
            return False, f"Erro ao atualizar favoritos: {e}"

    def sync_favorites_with_config(self, config_urls):
        """Sincroniza favoritos com URLs da configuração"""
        try:
            if not config_urls:
                print("ℹ️ Nenhuma URL para sincronizar")
                return self.update_favorites([], "Sites Gerenciados")

            formatted_urls = [url.strip() for url in config_urls if url.strip()]
            print(f"🔄 Sincronizando {len(formatted_urls)} URLs...")

            success, message = self.update_favorites(formatted_urls)

            if success:
                print("✅ Favoritos sincronizados com sucesso")
            else:
                print(f"❌ Erro na sincronização: {message}")

            return success, message

        except (OSError, TypeError, ValueError) as e:
            print(f"❌ Erro na sincronização: {e}")
            import traceback

            traceback.print_exc()
            return False, f"Erro na sincronização: {e}"
