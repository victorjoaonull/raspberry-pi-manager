# ⚡ Guia Rápido de Recuperação

## 🔴 Você recebeu este erro?
```
❌ Unable to locate executable '/home/administrador/...'
Failed at step EXEC spawning
```

## ✅ Solução em 3 Passos

### Passo 1: Re-rodar o Instalador
```bash
cd ~/raspberry-pi-manager
sudo ./install.sh
```
Isso vai:
- Recriar o venv se necessário
- Regenerar o arquivo de serviço
- Reiniciar o serviço

### Passo 2: Verificar o Status
```bash
sudo systemctl status raspberry-pi-manager
```

Esperado:
```
● raspberry-pi-manager.service - Gerenciador Web Raspberry PI
     Loaded: loaded (/etc/systemd/system/raspberry-pi-manager.service; enabled)
     Active: active (running)
```

### Passo 3: Testar a Conexão
```bash
# Obter IP
hostname -I

# Acessar no navegador
http://<SEU_IP>:5000
```

---

## 🔍 Se Ainda Não Funcionar

### Diagnosticar
```bash
sudo ./troubleshoot.sh
```

Este script verifica tudo e fornece recomendações.

### Verificar Manualmente
```bash
# Ver o que está errado
sudo journalctl -u raspberry-pi-manager -f

# Testar Python
/home/administrador/raspberry-pi-manager/venv/bin/python --version

# Testar app.py
/home/administrador/raspberry-pi-manager/venv/bin/python \
  /home/administrador/raspberry-pi-manager/app.py
```

---

## 📞 Comandos Úteis

```bash
# Iniciar
sudo systemctl start raspberry-pi-manager

# Parar
sudo systemctl stop raspberry-pi-manager

# Reiniciar
sudo systemctl restart raspberry-pi-manager

# Ver status
sudo systemctl status raspberry-pi-manager

# Ver logs ao vivo
sudo journalctl -u raspberry-pi-manager -f

# Ver últimas 50 linhas
sudo journalctl -u raspberry-pi-manager -n 50

# Resetar erros
sudo systemctl reset-failed raspberry-pi-manager
```

---

## 🆘 Ainda Não Funciona?

1. Verifique espaço em disco:
   ```bash
   df -h /home/administrador/
   ```

2. Recrie o venv do zero:
   ```bash
   sudo rm -rf /home/administrador/raspberry-pi-manager/venv
   cd ~/raspberry-pi-manager
   sudo ./install.sh
   ```

3. Procure por erros em requirements.txt:
   ```bash
   cat /home/administrador/raspberry-pi-manager/requirements.txt
   ```

4. Procure por ajuda em:
   - [CORRECAO_ERRO_SERVICO.md](CORRECAO_ERRO_SERVICO.md)
   - [MELHORIAS.md](MELHORIAS.md)
   - [RESUMO_CORRECOES.md](RESUMO_CORRECOES.md)

---

**Última atualização:** 13 de Fevereiro de 2026
