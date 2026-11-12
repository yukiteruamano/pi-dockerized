#!/bin/bash

# Bash completion for pi-dockerized
# Source this file in your ~/.bashrc or install system-wide

# Keep these lists in sync with the wrapper: tests/wrapper-args.test.sh checks
# them against the help text and SETTING_KEYS.
_PI_COMMANDS="run exec shell auth models mcp extensions stats doctor audit ps stop install uninstall upgrade update build pull rollback version config profile clean help"
_PI_SETTINGS="ssh_agent_support gpg_agent_support gpg_allow_main_socket gpg_autostart_agent gpg_relay docker_socket network security_policy allowed_tools verify_updates memory cpus pids_limit env_file theme model default_profile"

# Print the existing profile names; with "default", the root profile too.
# Usage: _pi_profiles [default]
_pi_profiles() {
    local root="${PI_CONFIG_ROOT:-$HOME/.config/pi-dockerized}/profiles" dir
    [ "${1:-}" = default ] && echo default
    for dir in "$root"/*; do
        [ -d "$dir" ] && [ "${dir##*/}" != default ] && basename "$dir"
    done
    return 0
}

# Fill COMPREPLY with the words in $1 matching the current word.
_pi_words() {
    mapfile -t COMPREPLY < <(compgen -W "$1" -- "$cur")
}

# Values accepted by `config set <key>` (empty when free-form).
_pi_setting_values() {
    case "$1" in
    ssh_agent_support | gpg_agent_support | gpg_allow_main_socket | gpg_autostart_agent | \
        gpg_relay | docker_socket | verify_updates) echo "true false" ;;
    network) echo "host bridge" ;;
    security_policy) echo "strict balanced off" ;;
    pids_limit) echo "4096 unlimited" ;;
    default_profile) _pi_profiles default ;;
    esac
}

# Complete the comma-separated sections of `install --only`.
_pi_only_sections() {
    local prefix="" item
    [[ "$cur" == *,* ]] && prefix="${cur%,*},"
    COMPREPLY=()
    for item in config completions aliases global path build; do
        [[ "$prefix$item" == "$cur"* ]] && COMPREPLY+=("$prefix$item")
    done
}

# Session flags for run/shell/exec, plus directories where one is accepted.
# Usage: _pi_session <run|shell|exec>
_pi_session() {
    local flags="--untrusted --policy --network --timeout --dir"
    [ "$1" = run ] && flags="$flags --resume --list"
    if [[ "$cur" == -* ]]; then
        _pi_words "$flags"
    elif [ "$1" != exec ]; then
        mapfile -t COMPREPLY < <(compgen -d -- "$cur")
    fi
}

_pi_dockerized() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"

    # Values of the flags that take one, wherever they appear.
    case "$prev" in
    --profile)
        _pi_words "$(_pi_profiles default)"
        return 0
        ;;
    --policy)
        _pi_words "strict balanced off"
        return 0
        ;;
    --network)
        _pi_words "host bridge"
        return 0
        ;;
    --dir)
        mapfile -t COMPREPLY < <(compgen -d -- "$cur")
        return 0
        ;;
    --only)
        _pi_only_sections
        return 0
        ;;
    --pi-version)
        _pi_words "latest"
        return 0
        ;;
    --timeout | -n | --resume) return 0 ;;
    esac

    # Find the command, skipping the global `--profile NAME` (also when bash
    # split `--profile=NAME` at the `=`).
    local i=1 cmd="" cmd_i=0
    while [ "$i" -lt "$COMP_CWORD" ]; do
        case "${COMP_WORDS[i]}" in
        --profile)
            i=$((i + 2))
            [ "${COMP_WORDS[i - 1]}" = "=" ] && i=$((i + 1))
            continue
            ;;
        -*) ;;
        *)
            cmd="${COMP_WORDS[i]}"
            cmd_i=$i
            break
            ;;
        esac
        i=$((i + 1))
    done

    if [ -z "$cmd" ]; then
        _pi_words "$_PI_COMMANDS --profile --help -h"
        return 0
    fi

    # Words after the command: sub = first one, arg = the position of the
    # current word among them (1 = completing sub itself).
    local sub="${COMP_WORDS[cmd_i + 1]:-}" arg=$((COMP_CWORD - cmd_i))
    case "$cmd" in
    run | shell | exec) _pi_session "$cmd" ;;
    mcp) [ "$arg" -eq 1 ] && _pi_words "list login logout" ;;
    extensions | plugin)
        if [ "$arg" -eq 1 ]; then
            _pi_words "list install remove update path edit"
        else
            case "$sub" in install | add | update) _pi_words "--allow-scripts" ;; esac
        fi
        ;;
    stats | ps) _pi_words "--json" ;;
    doctor | debug) _pi_words "--fix" ;;
    audit) _pi_words "-n --summary --clear --explain" ;;
    stop)
        local sessions=""
        if command -v docker >/dev/null 2>&1; then
            sessions=$(docker ps --filter label=pi-dockerized=1 --format '{{.Names}}' 2>/dev/null)
        fi
        _pi_words "--all --yes --force $sessions"
        ;;
    install) _pi_words "--yes --only --help" ;;
    uninstall) _pi_words "--yes --image --purge-config --all-profiles" ;;
    upgrade | update) _pi_words "--check --yes --no-build --verify --pi-version" ;;
    build) _pi_words "--pi-version --bust-cache --fresh" ;;
    pull) _pi_words "--no-verify --allow-downgrade" ;;
    config)
        if [ "$arg" -eq 1 ]; then
            _pi_words "show edit get set path sync pi allow"
            return 0
        fi
        case "$sub" in
        show) _pi_words "--sources" ;;
        get)
            if [ "$arg" -eq 2 ]; then _pi_words "$_PI_SETTINGS"; else _pi_words "--source"; fi
            ;;
        set)
            if [ "$arg" -eq 2 ]; then
                _pi_words "$_PI_SETTINGS"
            elif [ "$arg" -eq 3 ] && [ "$prev" = env_file ]; then
                mapfile -t COMPREPLY < <(compgen -f -- "$cur")
            elif [ "$arg" -eq 3 ]; then
                _pi_words "$(_pi_setting_values "$prev")"
            fi
            ;;
        sync) _pi_words "--check" ;;
        pi | allow) [ "$arg" -eq 2 ] && _pi_words "path edit" ;;
        esac
        ;;
    profile)
        if [ "$arg" -eq 1 ]; then
            _pi_words "list create remove show path check fix run root"
            return 0
        fi
        case "$sub" in
        root) [ "$arg" -eq 2 ] && _pi_words "path edit" ;;
        remove | rm)
            if [ "$arg" -eq 2 ]; then _pi_words "$(_pi_profiles)"; else _pi_words "--yes"; fi
            ;;
        show)
            if [ "$arg" -eq 2 ]; then _pi_words "$(_pi_profiles default) --sources"; else _pi_words "--sources"; fi
            ;;
        path | check | fix) [ "$arg" -eq 2 ] && _pi_words "$(_pi_profiles default)" ;;
        run)
            if [ "$arg" -eq 2 ]; then _pi_words "$(_pi_profiles default)"; else _pi_session run; fi
            ;;
        esac
        ;;
    esac
    return 0
}

complete -F _pi_dockerized pi-dockerized
complete -F _pi_dockerized pid
