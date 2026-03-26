#!/bin/bash
# Verificações antes da instalação: locale UTF-8 (evita bugs na UI) e opcionais (disco, memória).
#
# PI_MANAGER_SKIP_PREFLIGHT=1      — ignora tudo
# PI_MANAGER_UTF8_AUTO_FIX=1       — configura UTF-8 sem perguntar
# PI_MANAGER_STRICT_LOCALE=1       — exit 1 se não for UTF-8 e o utilizador recusar corrigir
# PI_MANAGER_PREFLIGHT_BASIC=1     — executa extras sem perguntar (modo não interativo)
# shellcheck shell=bash

pi_manager_locale_is_utf8() {
    local cm
    cm="$(locale charmap 2>/dev/null || echo "")"
    [ "$cm" = "UTF-8" ] && return 0
    case "${LANG:-}${LC_ALL:-}" in
        *UTF-8*|*utf8*) return 0 ;;
    esac
    return 1
}

pi_manager_pick_utf8_locale() {
    local x
    for x in pt_PT.UTF-8 pt_BR.UTF-8 en_GB.UTF-8 en_US.UTF-8; do
        if locale -a 2>/dev/null | grep -qFx "$x"; then
            echo "$x"
            return 0
        fi
    done
    echo "en_US.UTF-8"
}

# Garante linhas em locale.gen e corre locale-gen (Debian/Raspberry Pi OS)
pi_manager_ensure_locale_entries() {
    if ! command -v locale-gen >/dev/null 2>&1; then
        apt-get update -qq || return 1
        apt-get install -y -qq locales || return 1
    fi
    for line in "pt_PT.UTF-8 UTF-8" "pt_BR.UTF-8 UTF-8" "en_US.UTF-8 UTF-8"; do
        if ! grep -Fxq "$line" /etc/locale.gen 2>/dev/null; then
            echo "$line" >>/etc/locale.gen
        fi
    done
    locale-gen 2>/dev/null || true
}

pi_manager_apply_utf8_locale() {
    local target
    echo "  → A instalar pacote locales e gerar UTF-8 (pt_PT / pt_BR / en_US)…"
    pi_manager_ensure_locale_entries || return 1
    target="$(pi_manager_pick_utf8_locale)"
    echo "  → A definir locale predefinido: $target"
    if command -v update-locale >/dev/null 2>&1; then
        update-locale LANG="$target" LC_ALL="$target" 2>/dev/null || update-locale LANG="$target" 2>/dev/null || true
    else
        {
            echo "LANG=$target"
            echo "LC_ALL=$target"
        } >/etc/default/locale 2>/dev/null || true
    fi
    export LANG="$target"
    export LC_ALL="$target"
    export LC_CTYPE="$target"
    return 0
}

_pi_preflight_yes_no() {
    local msg="$1"
    local def="${2:-s}"
    local r
    if [ "${PI_MANAGER_INSTALL_INTERACTIVE:-1}" = "0" ]; then
        [ "$def" = "s" ] && return 0
        return 1
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        [ "$def" = "s" ] && return 0
        return 1
    fi
    read -r -p "$msg [S/n] " r || true
    r="$(echo "${r:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    [ -z "$r" ] && r="$def"
    case "$r" in
        s|sim|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Opcional: espaço em disco e memória
pi_manager_preflight_basic_extras() {
    local avail avail_mb
    echo ""
    echo -e "${BLUE:-}  Verificações básicas (disco e memória)…${NC:-}"
    if command -v df >/dev/null 2>&1; then
        avail="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
        if [ -n "$avail" ] && [ "$avail" -lt 1048576 ] 2>/dev/null; then
            avail_mb=$((avail / 1024))
            echo -e "${YELLOW:-}  ⚠ Pouco espaço livre em / (cerca de ${avail_mb} MiB). Recomendado ≥ 1 GiB livre.${NC:-}"
        else
            echo -e "${GREEN:-}  ✓ Espaço em disco em / parece suficiente.${NC:-}"
        fi
    fi
    if [ -r /proc/meminfo ]; then
        avail_mb="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")"
        if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 256 ] 2>/dev/null; then
            echo -e "${YELLOW:-}  ⚠ Memória disponível baixa (~${avail_mb} MiB). Raspberry Pi com pouca RAM pode ficar lento.${NC:-}"
        else
            echo -e "${GREEN:-}  ✓ Memória disponível OK.${NC:-}"
        fi
    fi
}

# Chamado pelo install.sh; cores opcionais RED GREEN YELLOW BLUE NC
pi_manager_run_preflight_checks() {
    if [ "${PI_MANAGER_SKIP_PREFLIGHT:-0}" = "1" ]; then
        return 0
    fi

    echo -e "${BLUE:-}[1.6/12]${NC:-} Ambiente: UTF-8 e verificações opcionais…"

    # --- UTF-8 (antes do resto da instalação) ---
    if pi_manager_locale_is_utf8; then
        echo -e "${GREEN:-}  ✓ Locale UTF-8 OK ($(locale charmap 2>/dev/null || echo '?')).${NC:-}"
    else
        echo -e "${YELLOW:-}  ⚠ O sistema não está a usar UTF-8 (charset: $(locale charmap 2>/dev/null || echo desconhecido)).${NC:-}"
        echo -e "${YELLOW:-}    Sem UTF-8, a interface e os logs podem mostrar caracteres incorretos.${NC:-}"

        _DO_FIX=0
        if [ "${PI_MANAGER_UTF8_AUTO_FIX:-0}" = "1" ]; then
            _DO_FIX=1
        elif [ "${PI_MANAGER_INSTALL_INTERACTIVE:-1}" = "0" ] || [ ! -t 0 ]; then
            # Não interativo: corrigir por omissão para evitar bugs
            _DO_FIX=1
        elif _pi_preflight_yes_no "  Configurar o sistema para UTF-8 agora (recomendado)?" "s"; then
            _DO_FIX=1
        fi

        if [ "$_DO_FIX" -eq 1 ]; then
            if pi_manager_apply_utf8_locale; then
                if pi_manager_locale_is_utf8; then
                    echo -e "${GREEN:-}  ✓ UTF-8 configurado (charset: $(locale charmap 2>/dev/null || echo '?')).${NC:-}"
                else
                    echo -e "${YELLOW:-}  ⚠ Locale alterado; pode ser necessário abrir uma nova sessão SSH para ver UTF-8 ativo em todo o sistema.${NC:-}"
                    export LANG="${LANG:-en_US.UTF-8}"
                    export LC_ALL="${LC_ALL:-$LANG}"
                fi
            else
                echo -e "${RED:-}  ❌ Não foi possível configurar UTF-8 automaticamente.${NC:-}"
                if [ "${PI_MANAGER_STRICT_LOCALE:-0}" = "1" ]; then
                    exit 1
                fi
            fi
        else
            echo -e "${YELLOW:-}  ⚠ A continuar sem corrigir UTF-8.${NC:-}"
            if [ "${PI_MANAGER_STRICT_LOCALE:-0}" = "1" ]; then
                echo -e "${RED:-}  ❌ PI_MANAGER_STRICT_LOCALE=1: abortar.${NC:-}"
                exit 1
            fi
        fi
    fi

    # --- Verificações básicas opcionais (Y/N) ---
    _RUN_BASIC=0
    if [ "${PI_MANAGER_PREFLIGHT_BASIC:-0}" = "1" ]; then
        _RUN_BASIC=1
    elif [ "${PI_MANAGER_INSTALL_INTERACTIVE:-1}" != "0" ] && [ -t 0 ] && [ -t 1 ]; then
        if _pi_preflight_yes_no "  Executar verificações básicas (disco e memória)?" "s"; then
            _RUN_BASIC=1
        fi
    fi
    if [ "$_RUN_BASIC" -eq 1 ]; then
        pi_manager_preflight_basic_extras || true
    fi

    echo ""
}
