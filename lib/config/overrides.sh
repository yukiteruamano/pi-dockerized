#!/bin/bash

# overrides.sh - per-invocation session flags (--policy, --network, --untrusted).
# Sourced by lib/config-lib.sh (not executable directly).
# shellcheck disable=SC2034 # globals are defined here and consumed by the other sourced modules
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# The config file holds the everyday defaults. These flags tighten (or, when
# asked explicitly, change) one session without editing it, e.g. a repository
# you do not trust: `pi-dockerized run --untrusted ~/src/unknown-repo`.

SESSION_DIR=""     # --dir DIR (exec/shell); run takes the directory positionally
SESSION_TIMEOUT="" # --timeout SEC (run/shell/exec); empty = no limit
SESSION_RESUME=""  # --resume [ID] (run only); "select" = interactive picker
SESSION_LIST=false # --list (run only): list local sessions, no container
SESSION_REST=()    # arguments left after the session flags

# Consume the leading session flags of an argument list. Stops at the first
# argument that is not one, so everything after it (a directory, a prompt, Pi's
# own flags) is left untouched in SESSION_REST. `--` ends flag parsing.
# Returns 1 on a malformed flag.
# Usage: parse_session_flags "$@"
parse_session_flags() {
    SESSION_POLICY=""
    SESSION_NETWORK=""
    SESSION_UNTRUSTED=false
    SESSION_DIR=""
    SESSION_TIMEOUT=""
    SESSION_RESUME=""
    SESSION_LIST=false
    SESSION_REST=()

    while [ $# -gt 0 ]; do
        case "$1" in
        --untrusted) SESSION_UNTRUSTED=true ;;
        --policy | --network | --dir | --timeout)
            if [ -z "${2:-}" ]; then
                config_error "$1 needs a value"
                return 1
            fi
            _set_session_flag "$1" "$2" || return 1
            shift
            ;;
        --policy=* | --network=* | --dir=* | --timeout=*)
            _set_session_flag "${1%%=*}" "${1#*=}" || return 1
            ;;
        --list) SESSION_LIST=true ;;
        --resume)
            # Optional session id: `--resume ID` resumes it, bare `--resume`
            # opens Pi's interactive picker.
            if [ -n "${2:-}" ] && [[ "${2:-}" != -* ]]; then
                SESSION_RESUME="$2"
                shift
            else
                SESSION_RESUME="select"
            fi
            ;;
        --resume=*) SESSION_RESUME="${1#*=}" ;;
        --)
            shift
            break
            ;;
        *) break ;;
        esac
        shift
    done
    SESSION_REST=("$@")
}

# Validate and store one value-carrying session flag.
_set_session_flag() {
    local flag="$1" value="$2"
    case "$flag" in
    --policy)
        case "$value" in
        strict | balanced | off) SESSION_POLICY="$value" ;;
        *)
            config_error "Invalid --policy '$value' (use strict|balanced|off)"
            return 1
            ;;
        esac
        ;;
    --network)
        case "$value" in
        host | bridge) SESSION_NETWORK="$value" ;;
        *)
            config_error "Invalid --network '$value' (use host|bridge)"
            return 1
            ;;
        esac
        ;;
    --dir) SESSION_DIR="$value" ;;
    --timeout)
        if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?[smhd]?$ ]]; then
            SESSION_TIMEOUT="$value"
        else
            config_error "Invalid --timeout '$value' (use seconds, e.g. 300, or 5m/1h)"
            return 1
        fi
        ;;
    esac
}

# Apply the session flags on top of the loaded config. --untrusted forces the
# most restrictive setup; combining it with a weaker explicit flag is refused
# instead of silently picking one.
# Usage: apply_session_overrides
apply_session_overrides() {
    if [ "$SESSION_UNTRUSTED" = true ]; then
        if [ "$SESSION_POLICY" = off ] || [ "$SESSION_NETWORK" = host ]; then
            config_error "--untrusted cannot be combined with --policy off or --network host."
            return 1
        fi
        SECURITY_POLICY="strict"
        NETWORK="bridge"
        SSH_AGENT_SUPPORT=false
        GPG_AGENT_SUPPORT=false
        DOCKER_SOCKET=false
        CUSTOM_MOUNTS=()
        CUSTOM_MOUNT_KEYS=()
    fi
    if [ -n "$SESSION_POLICY" ]; then SECURITY_POLICY="$SESSION_POLICY"; fi
    if [ -n "$SESSION_NETWORK" ]; then NETWORK="$SESSION_NETWORK"; fi
    return 0
}
