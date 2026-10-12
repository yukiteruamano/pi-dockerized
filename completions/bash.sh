#!/bin/bash

# Bash completion for pi-dockerized
# Source this file in your ~/.bashrc or install system-wide

_pi_has_word() {
    # _pi_has_word <word>: true when <word> appears before the current word.
    # Position-independent, so global flags (--profile NAME) do not shift it.
    local w
    for w in "${COMP_WORDS[@]:1:COMP_CWORD}"; do
        [ "$w" = "$1" ] && return 0
    done
    return 1
}

_pi_dockerized() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    opts="run exec shell auth models mcp extensions stats doctor audit ps stop install uninstall upgrade update build pull rollback version config clean help --profile --help -h"
    local session_flags="--untrusted --policy --network --timeout --resume --list --dir"
    local settings="ssh_agent_support gpg_agent_support gpg_allow_main_socket gpg_autostart_agent gpg_relay docker_socket network security_policy allowed_tools verify_updates memory cpus env_file theme model"

    case "${prev}" in
    --policy)
        mapfile -t COMPREPLY < <(compgen -W "strict balanced off" -- "${cur}")
        return 0
        ;;
    --network)
        mapfile -t COMPREPLY < <(compgen -W "host bridge" -- "${cur}")
        return 0
        ;;
    --profile)
        local root="${PI_CONFIG_ROOT:-$HOME/.config/pi-dockerized}/profiles"
        if [ -d "$root" ]; then
            mapfile -t COMPREPLY < <(compgen -W "$(ls "$root")" -- "${cur}")
        fi
        return 0
        ;;
    --dir)
        mapfile -t COMPREPLY < <(compgen -d -- "${cur}")
        return 0
        ;;
    --only)
        mapfile -t COMPREPLY < <(compgen -W "config completions aliases global path build" -- "${cur}")
        return 0
        ;;
    run | shell | exec | models)
        # Session flags first, then directories
        if [[ "${cur}" == -* ]]; then
            mapfile -t COMPREPLY < <(compgen -W "${session_flags}" -- "${cur}")
        else
            mapfile -t COMPREPLY < <(compgen -d -- "${cur}")
        fi
        return 0
        ;;
    config)
        # Complete config subcommands
        mapfile -t COMPREPLY < <(compgen -W "show edit get set path sync pi allow profiles" -- "${cur}")
        return 0
        ;;
    get | set)
        if _pi_has_word config; then
            mapfile -t COMPREPLY < <(compgen -W "${settings}" -- "${cur}")
            return 0
        fi
        ;;
    sync)
        # Second-level flag for `config sync`
        if _pi_has_word config; then
            mapfile -t COMPREPLY < <(compgen -W "--check" -- "${cur}")
            return 0
        fi
        ;;
    mcp)
        mapfile -t COMPREPLY < <(compgen -W "list login logout" -- "${cur}")
        return 0
        ;;
    extensions | plugin)
        mapfile -t COMPREPLY < <(compgen -W "list install remove update path edit" -- "${cur}")
        return 0
        ;;
    pi | allow)
        # Second-level flag for `config pi` / `config allow`
        if _pi_has_word config; then
            mapfile -t COMPREPLY < <(compgen -W "path edit" -- "${cur}")
            return 0
        fi
        ;;
    audit)
        mapfile -t COMPREPLY < <(compgen -W "-n --summary --clear --explain" -- "${cur}")
        return 0
        ;;
    ps | stats)
        mapfile -t COMPREPLY < <(compgen -W "--json" -- "${cur}")
        return 0
        ;;
    doctor)
        mapfile -t COMPREPLY < <(compgen -W "--fix" -- "${cur}")
        return 0
        ;;
    upgrade | update)
        mapfile -t COMPREPLY < <(compgen -W "--check --yes --no-build --verify --pi-version" -- "${cur}")
        return 0
        ;;
    build)
        mapfile -t COMPREPLY < <(compgen -W "--pi-version --bust-cache --fresh" -- "${cur}")
        return 0
        ;;
    pull)
        mapfile -t COMPREPLY < <(compgen -W "--no-verify" -- "${cur}")
        return 0
        ;;
    install)
        mapfile -t COMPREPLY < <(compgen -W "--yes --only" -- "${cur}")
        return 0
        ;;
    uninstall)
        mapfile -t COMPREPLY < <(compgen -W "--yes --image --purge-config" -- "${cur}")
        return 0
        ;;
    stop)
        local sessions=""
        if command -v docker >/dev/null 2>&1; then
            sessions=$(docker ps --filter label=pi-dockerized=1 --format '{{.Names}}' 2>/dev/null)
        fi
        if [[ "${cur}" == -* ]]; then
            mapfile -t COMPREPLY < <(compgen -W "--all --yes --force ${sessions}" -- "${cur}")
        else
            mapfile -t COMPREPLY < <(compgen -W "--yes --force --all ${sessions}" -- "${cur}")
        fi
        return 0
        ;;
    *)
        ;;
    esac

    mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
    return 0
}

complete -F _pi_dockerized pi-dockerized
complete -F _pi_dockerized pid
