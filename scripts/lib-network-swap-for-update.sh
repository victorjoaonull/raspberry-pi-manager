#!/bin/bash
# Troca temporária de IPv4 (NetworkManager) para atualizações: guardar estado,
# aplicar IP manual, restaurar no fim ou em EXIT/INT/TERM.
#
# Ativar: PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1
# Opcional: PI_MANAGER_UPDATE_IPV4 (omissão 10.0.8.94), PI_MANAGER_UPDATE_PREFIX,
#           PI_MANAGER_UPDATE_GW (omissão 10.0.0.1), PI_MANAGER_UPDATE_DNS (omissão 8.8.8.8 8.8.4.4)
#
# Preferência: nmcli (NetworkManager). Se nmcli/NM não estiverem disponíveis, usa-se
# iproute2 (`ip`) para aplicar o range **antes** de qualquer apt instalar network-manager.
# shellcheck shell=bash

PI_MANAGER_NETWORK_SWAP_STATE="${PI_MANAGER_NETWORK_SWAP_STATE:-/run/pi-manager-network-swap.state}"
_PI_MANAGER_SWAP_ACTIVE=0

_pi_manager_nm_running() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet NetworkManager 2>/dev/null && return 0
    fi
    nmcli -t -f RUNNING general status 2>/dev/null | grep -q '^running'
}

_pi_manager_ensure_nm() {
    command -v nmcli >/dev/null 2>&1 || return 1
    if _pi_manager_nm_running; then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start NetworkManager 2>/dev/null || true
        sleep 2
    fi
    _pi_manager_nm_running
}

_pi_manager_first_connected_device() {
    local line d st
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        d="${line%%:*}"
        st="${line#*:}"
        [ "$d" = "lo" ] && continue
        [ "$st" = "connected" ] && echo "$d" && return 0
    done < <(nmcli -t -f DEVICE,STATE device status 2>/dev/null)
    return 1
}

_pi_manager_save_state() {
    local dev="$1" conn uuid method addrs gw dns
    conn="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1)"
    [ -n "$conn" ] || return 1
    uuid="$(nmcli -t -f UUID connection show "$conn" 2>/dev/null | head -n1)"
    [ -n "$uuid" ] || return 1
    method="$(nmcli -g ipv4.method connection show "$uuid" 2>/dev/null | head -n1)"
    addrs="$(nmcli -g ipv4.addresses connection show "$uuid" 2>/dev/null | head -n1)"
    gw="$(nmcli -g ipv4.gateway connection show "$uuid" 2>/dev/null | head -n1)"
    dns="$(nmcli -g ipv4.dns connection show "$uuid" 2>/dev/null | head -n1)"
    {
        echo "STATE_VERSION=1"
        echo "DEVICE=${dev}"
        echo "UUID=${uuid}"
        echo "METHOD=${method}"
        echo "ADDRS=${addrs}"
        echo "GW=${gw}"
        echo "DNS=${dns}"
    } >"$PI_MANAGER_NETWORK_SWAP_STATE"
    chmod 600 "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null || true
}

_pi_manager_apply_temp_ipv4() {
    local uuid="$1"
    local dev="$2"
    local ip prefix addr gw dns
    ip="${PI_MANAGER_UPDATE_IPV4:-10.0.8.94}"
    prefix="${PI_MANAGER_UPDATE_PREFIX:-24}"
    addr="${ip}/${prefix}"
    gw="${PI_MANAGER_UPDATE_GW:-10.0.0.1}"
    dns="${PI_MANAGER_UPDATE_DNS:-8.8.8.8 8.8.4.4}"
    nmcli connection modify "$uuid" ipv4.method manual ipv4.addresses "$addr" ipv4.dns "$dns" || return 1
    if [ -n "$gw" ]; then
        nmcli connection modify "$uuid" ipv4.gateway "$gw" || return 1
    else
        nmcli connection modify "$uuid" ipv4.gateway "" || true
    fi
    if ! nmcli connection up "$uuid" 2>/dev/null; then
        [ -n "$dev" ] && nmcli device reapply "$dev" 2>/dev/null || true
    fi
    sleep 2
}

# --- Fallback iproute2: sem network-manager; permite trocar de range antes do apt instalar NM ---
_pi_manager_find_default_iface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{if($1=="default"){print $5; exit}}')
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi
    iface=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi
    return 1
}

_pi_manager_swap_begin_ip_cmd() {
    local iface temp prefix gw dns i line old_gw resolv_bak
    command -v ip >/dev/null 2>&1 || return 1
    iface="$(_pi_manager_find_default_iface)" || return 1

    temp="${PI_MANAGER_UPDATE_IPV4:-10.0.8.94}"
    prefix="${PI_MANAGER_UPDATE_PREFIX:-24}"
    gw="${PI_MANAGER_UPDATE_GW:-10.0.0.1}"
    dns="${PI_MANAGER_UPDATE_DNS:-8.8.8.8 8.8.4.4}"
    mkdir -p "$(dirname "$PI_MANAGER_NETWORK_SWAP_STATE")" 2>/dev/null || true

    i=0
    old_gw="$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{if($1=="default"){print $3; exit}}')"
    {
        echo "STATE_VERSION=2"
        echo "MODE=ip"
        echo "IFACE=$iface"
        echo "OLD_GW=${old_gw}"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            i=$((i + 1))
            echo "ADDR_$i=$line"
        done < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}')
    } >"$PI_MANAGER_NETWORK_SWAP_STATE"
    chmod 600 "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null || true

    if [ "$i" -eq 0 ]; then
        echo "pi-manager: sem endereços IPv4 em $iface para guardar; swap IP (iproute2) abortado." >&2
        rm -f "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null || true
        return 1
    fi

    resolv_bak="${PI_MANAGER_NETWORK_SWAP_STATE}.resolv.bak"
    if [ -f /etc/resolv.conf ]; then
        cp -a /etc/resolv.conf "$resolv_bak" 2>/dev/null || true
    fi

    if ! ip -4 addr flush dev "$iface" 2>/dev/null; then
        echo "pi-manager: falha ao limpar IPv4 em $iface." >&2
        rm -f "$PI_MANAGER_NETWORK_SWAP_STATE" "$resolv_bak" 2>/dev/null || true
        return 1
    fi

    if ! ip addr add "${temp}/${prefix}" dev "$iface" scope global; then
        echo "pi-manager: falha ao adicionar IPv4 temporário." >&2
        _pi_manager_restore_ip_cmd || true
        rm -f "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null || true
        return 1
    fi

    if ! ip route replace default via "$gw" dev "$iface" 2>/dev/null && ! ip route add default via "$gw" dev "$iface" 2>/dev/null; then
        echo "pi-manager: falha ao definir rota padrão." >&2
        _pi_manager_restore_ip_cmd || true
        rm -f "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null || true
        return 1
    fi

    for ns in $dns; do
        echo "nameserver $ns"
    done >/etc/resolv.conf

    sleep 1
    echo "pi-manager: IPv4 temporário aplicado via iproute2 (${temp}/${prefix}); estado anterior guardado."
    return 0
}

_pi_manager_restore_ip_cmd() {
    local iface old_gw resolv_bak line k v
    resolv_bak="${PI_MANAGER_NETWORK_SWAP_STATE}.resolv.bak"
    [ -f "$PI_MANAGER_NETWORK_SWAP_STATE" ] || return 1
    iface="$(grep -m1 '^IFACE=' "$PI_MANAGER_NETWORK_SWAP_STATE" | cut -d= -f2-)"
    old_gw="$(grep -m1 '^OLD_GW=' "$PI_MANAGER_NETWORK_SWAP_STATE" | cut -d= -f2-)"
    [ -n "$iface" ] || return 1

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl stop NetworkManager 2>/dev/null || true
    fi
    ip -4 addr flush dev "$iface" 2>/dev/null || true
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        k="${line%%=*}"
        v="${line#*=}"
        case "$k" in
            ADDR_*)
                [ -n "$v" ] && ip addr add "$v" dev "$iface" scope global 2>/dev/null || true
                ;;
        esac
    done <"$PI_MANAGER_NETWORK_SWAP_STATE"

    if [ -n "$old_gw" ]; then
        ip route replace default via "$old_gw" dev "$iface" 2>/dev/null || \
        ip route add default via "$old_gw" dev "$iface" 2>/dev/null || true
    fi
    if [ -f "$resolv_bak" ]; then
        cp -a "$resolv_bak" /etc/resolv.conf 2>/dev/null || true
        rm -f "$resolv_bak" 2>/dev/null || true
    fi
    sleep 1
    return 0
}

_pi_manager_swap_begin_nm() {
    if ! command -v nmcli >/dev/null 2>&1; then
        return 1
    fi
    if ! _pi_manager_ensure_nm; then
        return 1
    fi

    local dev
    dev="$(_pi_manager_first_connected_device)" || return 1

    if ! _pi_manager_save_state "$dev"; then
        return 1
    fi

    local uuid
    uuid="$(awk -F= '$1=="UUID"{print $2;exit}' "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null)"
    if [ -z "$uuid" ]; then
        rm -f "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null || true
        return 1
    fi

    if ! _pi_manager_apply_temp_ipv4 "$uuid" "$dev"; then
        echo "pi-manager: falha ao aplicar IPv4 temporário (nmcli); a restaurar estado anterior…" >&2
        _pi_manager_restore_from_state || true
        rm -f "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null || true
        return 1
    fi

    echo "pi-manager: IPv4 temporário aplicado (${PI_MANAGER_UPDATE_IPV4:-10.0.8.94}); estado anterior guardado."
    return 0
}

# Lê estado (uma chave=valor por linha; valor pode conter '='; DNS pode ter espaços)
_pi_manager_read_state_kv() {
    local line k v
    _PI_MANAGER_ST_UUID=""
    _PI_MANAGER_ST_DEVICE=""
    _PI_MANAGER_ST_METHOD=""
    _PI_MANAGER_ST_ADDRS=""
    _PI_MANAGER_ST_GW=""
    _PI_MANAGER_ST_DNS=""
    [ -f "$PI_MANAGER_NETWORK_SWAP_STATE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        k="${line%%=*}"
        v="${line#*=}"
        case "$k" in
            UUID) _PI_MANAGER_ST_UUID="$v" ;;
            DEVICE) _PI_MANAGER_ST_DEVICE="$v" ;;
            METHOD) _PI_MANAGER_ST_METHOD="$v" ;;
            ADDRS) _PI_MANAGER_ST_ADDRS="$v" ;;
            GW) _PI_MANAGER_ST_GW="$v" ;;
            DNS) _PI_MANAGER_ST_DNS="$v" ;;
        esac
    done < "$PI_MANAGER_NETWORK_SWAP_STATE"
}

_pi_manager_restore_from_state() {
    local uuid method addrs gw dns dev
    [ -f "$PI_MANAGER_NETWORK_SWAP_STATE" ] || return 0
    _pi_manager_read_state_kv || return 1
    uuid="${_PI_MANAGER_ST_UUID:-}"
    [ -n "$uuid" ] || return 1
    method="${_PI_MANAGER_ST_METHOD:-auto}"
    addrs="${_PI_MANAGER_ST_ADDRS:-}"
    gw="${_PI_MANAGER_ST_GW:-}"
    dns="${_PI_MANAGER_ST_DNS:-}"
    dev="${_PI_MANAGER_ST_DEVICE:-}"

    case "$method" in
        auto|dhcp)
            nmcli connection modify "$uuid" ipv4.method auto || true
            nmcli connection modify "$uuid" ipv4.addresses "" || true
            nmcli connection modify "$uuid" ipv4.gateway "" || true
            nmcli connection modify "$uuid" ipv4.dns "" || true
            ;;
        manual|link-local)
            nmcli connection modify "$uuid" ipv4.method "$method" || true
            nmcli connection modify "$uuid" ipv4.addresses "${addrs}" || true
            nmcli connection modify "$uuid" ipv4.gateway "${gw}" || true
            nmcli connection modify "$uuid" ipv4.dns "${dns}" || true
            ;;
        disabled)
            nmcli connection modify "$uuid" ipv4.method disabled || true
            ;;
        *)
            nmcli connection modify "$uuid" ipv4.method auto || true
            nmcli connection modify "$uuid" ipv4.addresses "" || true
            nmcli connection modify "$uuid" ipv4.gateway "" || true
            nmcli connection modify "$uuid" ipv4.dns "" || true
            ;;
    esac
    if ! nmcli connection up "$uuid" 2>/dev/null; then
        [ -n "$dev" ] && nmcli device reapply "$dev" 2>/dev/null || true
    fi
    sleep 2
}

# Chamado por trap: não falhar o processo pai
pi_manager_network_swap_cleanup() {
    if [ "$_PI_MANAGER_SWAP_ACTIVE" != "1" ]; then
        return 0
    fi
    pi_manager_network_swap_end || true
}

# Restaura rede e remove trap; idempotente
pi_manager_network_swap_end() {
    if [ "$_PI_MANAGER_SWAP_ACTIVE" != "1" ]; then
        return 0
    fi
    trap - EXIT INT TERM HUP 2>/dev/null || true
    local ver
    ver="$(grep -m1 '^STATE_VERSION=' "$PI_MANAGER_NETWORK_SWAP_STATE" 2>/dev/null | cut -d= -f2)"
    if [ "$ver" = "2" ]; then
        _pi_manager_restore_ip_cmd || echo "pi-manager: aviso — falha ao restaurar IPv4 (iproute2)." >&2
    else
        _pi_manager_restore_from_state || echo "pi-manager: aviso — falha ao restaurar IPv4 (verifique nmcli)." >&2
    fi
    rm -f "$PI_MANAGER_NETWORK_SWAP_STATE" "${PI_MANAGER_NETWORK_SWAP_STATE}.resolv.bak" 2>/dev/null || true
    _PI_MANAGER_SWAP_ACTIVE=0
}

# Inicia swap se PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1; devolve 0 se swap ativo, 1 se ignorado
pi_manager_network_swap_begin() {
    if [ "${PI_MANAGER_NETWORK_SWAP_FOR_UPDATE:-0}" != "1" ]; then
        return 1
    fi
    if _pi_manager_swap_begin_nm; then
        _PI_MANAGER_SWAP_ACTIVE=1
        trap 'pi_manager_network_swap_cleanup' EXIT INT TERM HUP
        return 0
    fi
    if _pi_manager_swap_begin_ip_cmd; then
        _PI_MANAGER_SWAP_ACTIVE=1
        trap 'pi_manager_network_swap_cleanup' EXIT INT TERM HUP
        return 0
    fi
    echo "pi-manager: swap de IPv4 não aplicado (NetworkManager indisponível e iproute2 falhou ou incompleto)." >&2
    return 1
}
