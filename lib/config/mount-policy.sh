#!/bin/bash

# mount-policy.sh - what may be bind-mounted into the container, and where.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# Mounts are the sandbox's main hole: a custom mount can expose the host home,
# the wrapper's own secrets file, the Docker socket, or replace the baked,
# immutable agent tooling. Every host source and container target is checked
# here, on literal and symlink-resolved paths alike.

# Credential stores under $HOME that must never reach the agent.
SENSITIVE_HOME_PATHS=(.ssh .gnupg .aws .kube .docker .config/gcloud .config/gh .netrc .git-credentials)

# Container paths a mount must not equal or sit above: it would hide them.
CONTAINER_SHADOW_PATHS=(
    /bin /sbin /lib /lib32 /lib64 /libx32 /usr/bin /usr/local/bin /etc /dev /proc /sys
    /usr/local/lib/pi-dockerized /home/coder/.nvm /home/coder/.local
    /home/coder/.pi/agent/extensions /home/coder/.pi/agent/settings.json
    /home/coder/.pi/agent/AGENTS.md
)

# Container paths a custom mount must not target at or below: the baked tooling
# (guard, settings) and the wrapper's own state mounts.
CONTAINER_INTERNAL_PATHS=(
    /home/coder/.pi/agent /home/coder/.nvm /home/coder/.local /usr/local/bin
    /usr/local/lib/pi-dockerized
)

# Lexically normalize an absolute path: collapse `//`, `.` and `..` without
# touching the filesystem (container paths do not exist on the host).
# Usage: normalize_path <path>
normalize_path() {
    local part out="" IFS=/
    local -a stack=()
    # shellcheck disable=SC2086 # intentional split on "/" via IFS
    for part in $1; do
        case "$part" in
        "" | .) ;;
        ..) [ "${#stack[@]}" -gt 0 ] && unset 'stack[${#stack[@]}-1]' ;;
        *) stack+=("$part") ;;
        esac
    done
    for part in "${stack[@]}"; do out="$out/$part"; done
    printf '%s' "${out:-/}"
}

# Refuse a container path that would hide system or wrapper paths.
# `internal` = also refuse targets inside the baked tooling (custom mounts).
# Usage: validate_container_path <path> <what> [internal]
validate_container_path() {
    local path="$1" what="$2" internal="${3:-}" norm other
    norm=$(normalize_path "$path")
    for other in "${CONTAINER_SHADOW_PATHS[@]}"; do
        if path_within "$other" "$norm"; then
            config_error "Refusing $what at $norm inside the container: it would hide $other."
            config_info "Move the project or rename the directory so its container path differs."
            return 1
        fi
    done
    [ "$internal" = internal ] || return 0
    for other in "${CONTAINER_INTERNAL_PATHS[@]}"; do
        if path_within "$norm" "$other"; then
            config_error "Refusing $what at $norm: $other is part of the baked, read-only image."
            return 1
        fi
    done
    return 0
}

# Why a host path is off limits, or nothing when it is acceptable. Tested on a
# single form of the path (literal or resolved); `home` is the matching $HOME.
# Usage: why=$(forbidden_mount_reason <path> <home>)
forbidden_mount_reason() {
    local path="$1" home="$2" rel root
    if path_within "$home" "$path"; then
        echo "it is your home directory or contains it"
        return 0
    fi
    for rel in "${SENSITIVE_HOME_PATHS[@]}"; do
        if path_within "$path" "$home/$rel" || path_within "$home/$rel" "$path"; then
            case "$rel" in
            .ssh) echo "it would expose SSH private keys (use setting.ssh_agent_support=true)" ;;
            .gnupg) echo "it would expose GnuPG private keys (use setting.gpg_agent_support=true)" ;;
            *) echo "it exposes credentials in ~/$rel" ;;
            esac
            return 0
        fi
    done
    # The wrapper's config root (every profile) and the active config dir hold
    # the secrets file and the state tree.
    for root in "$PI_CONFIG_ROOT" "$(canonical_path "$PI_CONFIG_ROOT")" \
        "$CONFIG_DIR" "$(canonical_path "$CONFIG_DIR")"; do
        if path_within "$path" "$root" || path_within "$root" "$path"; then
            echo "it holds the wrapper's secrets file and state ($root)"
            return 0
        fi
    done
    case "$path" in
    */docker.sock)
        echo "it is the Docker socket (use setting.docker_socket=true, which is root-equivalent)"
        return 0
        ;;
    esac
    return 0
}

# Validate the host side of a custom mount. Prints the reason and returns 1 when
# refused; warns (and succeeds) for sources that merely deserve attention.
# Usage: validate_mount_source <host_path> <name>
validate_mount_source() {
    local host_path="$1" name="$2" real home_real form home why
    if [[ "$host_path" != /* ]]; then
        config_error "Invalid mount '$name': host path must be absolute (got '$host_path')."
        return 1
    fi
    real=$(canonical_path "$host_path")
    home_real=$(canonical_path "$HOME")
    for form in "$host_path" "$real"; do
        # Test each form against both spellings of $HOME (symlinked homes).
        for home in "$HOME" "$home_real"; do
            why=$(forbidden_mount_reason "$form" "$home")
            if [ -n "$why" ]; then
                config_error "Refusing to mount $host_path ($name): $why."
                return 1
            fi
        done
    done
    case "$real" in
    "$home_real"/.npmrc | "$HOME"/.npmrc)
        config_warning "Mounting ~/.npmrc hands its registry tokens to the agent."
        ;;
    esac
    return 0
}
