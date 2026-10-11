#!/bin/bash

# Bash completion for pi-dockerized
# Source this file in your ~/.bashrc or install system-wide

_pi_dockerized() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="run auth models exec mcp extensions stats doctor install upgrade build update version config clean help --help -h"

    case "${prev}" in
        run|models)
            # Complete directory paths for run command
            mapfile -t COMPREPLY < <(compgen -d -- "${cur}")
            return 0
            ;;
        config)
            # Complete config subcommands
            mapfile -t COMPREPLY < <(compgen -W "show edit path sync pi" -- "${cur}")
            return 0
            ;;
        sync)
            # Second-level flag for `config sync`
            if [ "${COMP_WORDS[1]}" = "config" ]; then
                mapfile -t COMPREPLY < <(compgen -W "--check" -- "${cur}")
                return 0
            fi
            ;;
        mcp)
            mapfile -t COMPREPLY < <(compgen -W "list login logout" -- "${cur}")
            return 0
            ;;
        extensions|plugin)
            mapfile -t COMPREPLY < <(compgen -W "list" -- "${cur}")
            return 0
            ;;
        pi)
            # Second-level flag for `config pi`
            if [ "${COMP_WORDS[1]}" = "config" ]; then
                mapfile -t COMPREPLY < <(compgen -W "path edit" -- "${cur}")
                return 0
            fi
            ;;
        upgrade|update)
            mapfile -t COMPREPLY < <(compgen -W "--check --yes --no-build --pi-version" -- "${cur}")
            return 0
            ;;
        install)
            mapfile -t COMPREPLY < <(compgen -W "--yes --only" -- "${cur}")
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
