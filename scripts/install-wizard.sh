#!/bin/bash
# Assistente simples para o install.sh (leigos: Enter = recomendado).
# Ativar/desativar: PI_MANAGER_INSTALL_INTERACTIVE=0 desliga (CI, cron).
# shellcheck shell=bash

pi_manager_install_run_wizard() {
    if [ "${PI_MANAGER_INSTALL_INTERACTIVE:-1}" = "0" ]; then
        return 0
    fi
    if [ -n "${CI:-}" ] && [ "$CI" != "0" ] && [ "$CI" != "false" ]; then
        return 0
    fi
    if [ "${DEBIAN_FRONTEND:-}" = "noninteractive" ]; then
        return 0
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return 0
    fi

    local line
    local _DEF_INSTALL="/home/administrador/raspberry-pi-manager"
    local _id="${INSTALL_DIR:-$_DEF_INSTALL}"

    echo ""
    echo -e "\033[0;34m────────────────────────────────────────────────────────\033[0m"
    echo -e "\033[0;34m  Configuração rápida\033[0m"
    echo ""
    echo "  Recomendado para a maioria dos casos:"
    echo "  • Instala a partir desta pasta (cópia local)"
    echo "  • Pasta da aplicação: ${_id}"
    echo ""
    echo -e "  \033[1;33mPressione ENTER\033[0m para continuar com estas opções."
    echo -e "  Digite \033[1;33mo\033[0m e ENTER para outras opções simples: "
    read -r line || true
    line="$(echo "${line:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

    if [ "$line" != "o" ] && [ "$line" != "opcoes" ] && [ "$line" != "opções" ]; then
        echo -e "  \033[0;32m✓\033[0m A usar configuração recomendada."
        echo ""
        # Troca de IP para o apt: redes que devolvem 403 em deb.debian.org (só com ENTER; não exige menu "o")
        if [ "${PI_MANAGER_NETWORK_SWAP_FOR_UPDATE:-0}" != "1" ]; then
            echo "  Se o apt não conseguir aceder aos espelhos Debian (erro 403 em HTTP), pode usar"
            echo "  IPv4 temporário 10.0.8.94/16 e gateway 10.0.0.1 só durante o passo [2/12], depois repõe."
            echo "  Requer NetworkManager (nmcli). O SSH pode cortar se o IP não for acessível ao seu PC."
            echo -ne "  Ativar troca de IPv4 temporária para o apt? [s/N]: "
            read -r _swap_ans || true
            _swap_ans="$(echo "${_swap_ans:-}" | tr '[:upper:]' '[:lower:]')"
            case "${_swap_ans:-}" in
                s|sim|y|yes)
                    export PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1
                    export PI_MANAGER_UPDATE_IPV4="${PI_MANAGER_UPDATE_IPV4:-10.0.8.94}"
                    export PI_MANAGER_UPDATE_PREFIX="${PI_MANAGER_UPDATE_PREFIX:-16}"
                    export PI_MANAGER_UPDATE_GW="${PI_MANAGER_UPDATE_GW:-10.0.0.1}"
                    echo -e "  \033[0;32m✓\033[0m Troca ativada: 10.0.8.94/16 via 10.0.0.1 (sobrepor com PI_MANAGER_UPDATE_* no ambiente)."
                    ;;
            esac
        fi
        echo ""
        return 0
    fi

    echo ""
    echo "  --- Opções ---"
    echo ""

    # 1) Origem
    echo "  De onde instalar o programa?"
    echo "    1) Desta pasta (recomendado) — cópia dos ficheiros que tem aqui"
    echo "    2) Clonar do GitHub (precisa de Internet estável)"
    echo -ne "  Escolha [1]: "
    read -r line || true
    line="${line:-1}"
    case "$line" in
        2)
            export CLONE_FROM_GITHUB=true
            echo -ne "  URL do repositório [Enter = predefinida]: "
            read -r _url || true
            if [ -n "${_url:-}" ]; then
                export GIT_REPO="$_url"
            fi
            ;;
        *)
            export CLONE_FROM_GITHUB=false
            ;;
    esac

    # 2) Pasta de instalação
    echo -ne "  Pasta onde instalar [${_id}]: "
    read -r _dir || true
    if [ -n "${_dir:-}" ]; then
        export INSTALL_DIR="$_dir"
    else
        export INSTALL_DIR="$_id"
    fi

    # 3) Rede temporária durante o apt (avançado)
    echo ""
    if [ "${PI_MANAGER_NETWORK_SWAP_FOR_UPDATE:-0}" = "1" ]; then
        echo "  Rede temporária durante o apt: já ativa (PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1)."
    else
        echo "  Durante a atualização do sistema, usar um IP fixo temporário?"
        echo "  (Só necessário em redes de gestão/VPN; pode cortar o SSH se mal configurado.)"
        echo -ne "  Ativar? [s/N]: "
        read -r line || true
        line="$(echo "${line:-}" | tr '[:upper:]' '[:lower:]')"
        case "$line" in
            s|sim|y|yes)
                export PI_MANAGER_NETWORK_SWAP_FOR_UPDATE=1
                export PI_MANAGER_UPDATE_IPV4="${PI_MANAGER_UPDATE_IPV4:-10.0.8.94}"
                export PI_MANAGER_UPDATE_PREFIX="${PI_MANAGER_UPDATE_PREFIX:-16}"
                export PI_MANAGER_UPDATE_GW="${PI_MANAGER_UPDATE_GW:-10.0.0.1}"
                echo -ne "  Outro gateway que não 10.0.0.1? [Enter = manter 10.0.0.1]: "
                read -r _gw || true
                if [ -n "${_gw:-}" ]; then
                    export PI_MANAGER_UPDATE_GW="$_gw"
                fi
                ;;
            *)
                :
                ;;
        esac
    fi

    # 4) Limpeza antiga alargada (raro)
    echo ""
    if [ "${PI_MANAGER_LEGACY_WIDE_CLEANUP:-0}" = "1" ]; then
        echo "  Limpeza alargada *pi-manager*: já ativa (PI_MANAGER_LEGACY_WIDE_CLEANUP=1)."
    else
        echo "  Procurar e remover pastas antigas com nome *pi-manager* em todo o disco?"
        echo -e "  (\033[1;33mArriscado\033[0m — só use se souber o que faz.)"
        echo -ne "  Ativar? [s/N]: "
        read -r line || true
        line="$(echo "${line:-}" | tr '[:upper:]' '[:lower:]')"
        case "$line" in
            s|sim|y|yes)
                export PI_MANAGER_LEGACY_WIDE_CLEANUP=1
                ;;
            *)
                :
                ;;
        esac
    fi

    echo ""
    echo -e "  \033[0;32m✓\033[0m Opções guardadas. A continuar a instalação..."
    echo ""
}
