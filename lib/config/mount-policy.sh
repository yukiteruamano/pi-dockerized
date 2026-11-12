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

# Container paths no mount (custom or the project) may equal, sit above (it
# would hide them) or sit below (it would replace part of them, e.g.
# /etc/ld.so.preload, /bin/sh or the guard): the system, the baked read-only
# tooling and the agent directory with the wrapper's own state mounts.
CONTAINER_SHADOW_PATHS=(
    /bin /sbin /lib /lib32 /lib64 /libx32 /usr /etc /dev /proc /sys
    /usr/local/lib/pi-dockerized /home/coder/.nvm /home/coder/.local
    /home/coder/.pi/agent /home/coder/.pi/ext-agent
)

# Data-only locations under the protected system paths that a custom mount may
# still target (strictly below them): extra CA certificates for proxies.
CONTAINER_MOUNT_EXCEPTIONS=(/etc/ssl/certs /usr/local/share/ca-certificates)

# Host directories that hold sockets (Docker, containerd, agents, D-Bus): a bind
# mount of the directory hands every socket in it to the agent, and a read-only
# bind does not stop connect(). Removable media under /run/media stay allowed.
HOST_SOCKET_DIRS=(/run /var/run)

# Shared temp dirs: they hold per-user sockets (tmux, ssh-agent, X11, IDE
# IPC), so neither they nor an ancestor may be mounted; a project below them
# is fine unless it is one of those socket directories.
HOST_TMP_DIRS=(/tmp /var/tmp)
HOST_TMP_SOCKET_GLOBS=(.X11-unix .ICE-unix .font-unix .XIM-unix 'tmux-*' 'ssh-*' 'vscode-*')

# Container VM homes under $HOME whose directories hold engine sockets.
HOME_SOCKET_PATHS=(.colima .rd .lima .orbstack .local/share/containers)

# How deep to look for socket files in a mount source: a socket in a mounted
# tree is reachable by connect() even through a read-only bind.
SOCKET_SCAN_DEPTH=3

# Pseudo filesystems: /proc/<pid>/root and friends reach the host's root.
HOST_PSEUDO_FS=(/proc /sys /dev)

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

# True when two paths overlap: one equals or contains the other.
# Usage: paths_overlap <a> <b>
paths_overlap() {
    path_within "$1" "$2" || path_within "$2" "$1"
}

# True when a container target lies strictly inside an allowed data location.
# Usage: container_path_excepted <normalized_path>
container_path_excepted() {
    local exc
    for exc in "${CONTAINER_MOUNT_EXCEPTIONS[@]}"; do
        if [ "$1" != "$exc" ] && path_within "$1" "$exc"; then
            return 0
        fi
    done
    return 1
}

# Refuse a container path that would hide or replace system, tooling or
# wrapper paths (see CONTAINER_SHADOW_PATHS).
# Usage: validate_container_path <path> <what>
validate_container_path() {
    local path="$1" what="$2" norm other
    norm=$(normalize_path "$path")
    container_path_excepted "$norm" && return 0
    for other in "${CONTAINER_SHADOW_PATHS[@]}"; do
        if paths_overlap "$norm" "$other"; then
            config_error "Refusing $what at $norm inside the container: it would hide or replace $other."
            config_info "Move the project or rename the directory so its container path differs."
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
        if paths_overlap "$path" "$home/$rel"; then
            case "$rel" in
            .ssh) echo "it would expose SSH private keys (use setting.ssh_agent_support=true)" ;;
            .gnupg) echo "it would expose GnuPG private keys (use setting.gpg_agent_support=true)" ;;
            *) echo "it exposes credentials in ~/$rel" ;;
            esac
            return 0
        fi
    done
    # The wrapper's config root (every profile), the active config dir and the
    # state tree hold the secrets file, the config and the state.
    for root in "$PI_CONFIG_ROOT" "$(canonical_path "$PI_CONFIG_ROOT")" \
        "$CONFIG_DIR" "$(canonical_path "$CONFIG_DIR")" \
        "$PI_HOME" "$(canonical_path "$PI_HOME")"; do
        if paths_overlap "$path" "$root"; then
            echo "it holds the wrapper's secrets file and state ($root)"
            return 0
        fi
    done
    for rel in "${HOME_SOCKET_PATHS[@]}"; do
        if paths_overlap "$path" "$home/$rel"; then
            echo "it holds a container engine VM and its sockets (~/$rel)"
            return 0
        fi
    done
    local glob
    for root in "${HOST_TMP_DIRS[@]}"; do
        if path_within "$root" "$path"; then
            echo "it is or contains a shared temp directory ($root: tmux, ssh-agent and X11 sockets)"
            return 0
        fi
        for glob in "${HOST_TMP_SOCKET_GLOBS[@]}"; do
            # shellcheck disable=SC2053 # $glob is a pattern on purpose
            if [[ "$path" == "$root"/$glob || "$path" == "$root"/$glob/* ]]; then
                echo "it is a socket directory under $root"
                return 0
            fi
        done
    done
    for root in "${HOST_PSEUDO_FS[@]}"; do
        if path_within "$path" "$root"; then
            echo "it is a pseudo filesystem ($root) that reaches the host"
            return 0
        fi
    done
    case "$path" in
    */docker.sock | */podman.sock | */containerd.sock)
        echo "it is a container engine socket (use setting.docker_socket=true, which is root-equivalent)"
        return 0
        ;;
    esac
    local -a socket_dirs=("${HOST_SOCKET_DIRS[@]}")
    [ -n "${XDG_RUNTIME_DIR:-}" ] && socket_dirs+=("$XDG_RUNTIME_DIR" "$(canonical_path "$XDG_RUNTIME_DIR")")
    for root in "${socket_dirs[@]}"; do
        case "$path" in
        /run/media/?*/?* | /var/run/media/?*/?*) continue ;;
        esac
        if paths_overlap "$path" "$root"; then
            echo "it is or contains a runtime socket directory ($root: Docker, agent and D-Bus sockets)"
            return 0
        fi
    done
    return 0
}

# Print the first socket found in a directory tree (bounded depth, symlinks not
# followed), or nothing. Unreadable entries are skipped.
# Usage: sock=$(find_socket <dir>)
find_socket() {
    if [ -S "$1" ]; then
        printf '%s' "$1"
        return 0
    fi
    [ -d "$1" ] || return 0
    find "$1" -maxdepth "$SOCKET_SCAN_DEPTH" -type s -print -quit 2>/dev/null || true
}

# Validate the host side of a custom mount. Prints the reason and returns 1 when
# refused; warns (and succeeds) for sources that merely deserve attention.
# Usage: validate_mount_source <host_path> <name>
validate_mount_source() {
    local host_path="$1" name="$2" real home_real form home why sock
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
    if sock=$(find_socket "$real") && [ -n "$sock" ]; then
        config_error "Refusing to mount $host_path ($name): it contains a socket ($sock) the agent could connect to."
        config_info "Move the socket out of the tree, or mount a narrower directory."
        return 1
    fi
    case "$real" in
    "$home_real"/.npmrc | "$HOME"/.npmrc)
        config_warning "Mounting ~/.npmrc hands its registry tokens to the agent."
        ;;
    esac
    return 0
}
