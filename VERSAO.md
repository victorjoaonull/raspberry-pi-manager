# 🏷️ Adição de Versão (v2.3.8)

## ✅ Alterações Realizadas

### 1. **app.py**
   - Adicionada constante `APP_VERSION = "2.3.8"` no início do arquivo
   - Criado `@app.context_processor` para disponibilizar `app_version` em todas as templates
   - Adicionado `app_version` à resposta de `/api/system/info`

### 2. **Templates HTML**
   Adicionada a versão em todos os templates:
   
   - **index.html**: Versão exibida no header (logo area) com `<small>v{{ app_version }}</small>`
   - **login.html**: Versão exibida abaixo do título
   - **network.html**: Versão no header
   - **system.html**: Versão no header
   - **autostart.html**: Versão no header
   - **about.html**: Versão exibida na seção "Informações"

### 3. **API Response**
   Agora a rota `/api/system/info` retorna:
   ```json
   {
     "hostname": "...",
     "model": "...",
     "uptime": "...",
     "temperature": "...",
     "cpu_usage": "...",
     "memory_usage": "...",
     "os_version": "...",
     "kernel": "...",
     "app_version": "2.3.8"
   }
   ```

## 🎯 Onde a Versão Aparece

1. **Dashboard Principal (index.html)**
   - Logo area: `Gerenciador Raspberry PI | v2.3.8`

2. **Página de Login**
   - Abaixo do título: `Gerenciador Raspberry PI | v2.3.8`

3. **Todas as Páginas (network, system, autostart)**
   - Header com versão

4. **Página Sobre**
   - Seção "Informações" mostra: `Versão: 2.3.8`

5. **API**
   - Endpoint `/api/system/info` inclui campo `app_version`

## 🚀 Como Atualizar Versão

Para alterar para outra versão no futuro:

```python
# Em app.py, linha 20
APP_VERSION = "X.Y.Z"  # Alterar apenas este valor
```

A versão será automaticamente propagada para:
- Todas as templates (via context processor)
- API responses
- Interface do usuário

## 📊 Estrutura de Versão

Usando **Semantic Versioning**:
- **2** = Major (mudanças grandes)
- **3** = Minor (novas funcionalidades)
- **8** = Patch (correções de bugs)

## ✨ Exemplo de Uso

Você pode acessar a versão de diferentes formas:

**HTML Template:**
```html
<p>Versão: {{ app_version }}</p>
```

**JavaScript/Fetch:**
```javascript
fetch('/api/system/info')
  .then(r => r.json())
  .then(data => console.log('Versão:', data.app_version))
```

---

**Data:** 13 de Fevereiro de 2026
