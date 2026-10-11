#!/bin/bash

# parse.sh - runtime config parsing: mounts and env arguments.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# ============================================
# CONFIG PARSING (used at runtime by all scripts)
# ============================================

# Parse config file into global arrays
parse_config() {
    load_config || return 0 # Continue even if load fails
}

# Add a bind mount for a socket/file. Docker's `--mount` spec separates fields
# with commas, so fall back to `-v` when a path contains one.
# Usage: mount_bind <source> <target>
mount_bind() {
    local src="$1" dst="$2"
    case "$src$dst" in
        *,*) DOCKER_MOUNT_ARGS+=(-v "$src:$dst") ;;
        *) DOCKER_MOUNT_ARGS+=(--mount "type=bind,source=$src,target=$dst") ;;
    esac
}

# Build docker volume mount arguments from CUSTOM_MOUNTS array (plus SSH/GPG
# agent forwarding). Populates DOCKER_MOUNT_ARGS array.
build_mount_args() {
    DOCKER_MOUNT_ARGS=()
    GPG_SOCKET=""
    # Stop a relay left over from a previous call in the same process.
    if [ -n "$GPG_RELAY_SOCKET" ]; then
        stop_gpg_relay "$GPG_RELAY_SOCKET"
    fi
    GPG_RELAY_SOCKET=""

    # Host-side preflight for the forwarded agents (no-op when disabled). It
    # launches the GPG agent if needed and reports why a socket is unusable.
    ensure_ssh_agent_ready
    ensure_gpg_agent_ready
    cleanup_stale_relays

    for mount in "${CUSTOM_MOUNTS[@]}"; do
        # Expand a leading ~ to the home directory (only at the start of the
        # host path; ':' inside paths is the field separator and unsupported)
        if [[ "$mount" == "~"* ]]; then
            mount="$HOME${mount#"~"}"
        fi

        # Extract host_path, container_path, and mode
        local host_path="${mount%%:*}"
        local rest="${mount#*:}"
        local container_path="${rest%:*}"
        local mode="${rest##*:}"

        # A mount entry must be host_path:container_path[:mode].
        if [[ "$mount" != *:* ]]; then
            config_error "Invalid mount '$mount': expected host_path:container_path"
            exit 1
        fi

        # Never expose the host SSH private material: agent forwarding is the
        # supported path (config/known_hosts are mounted read-only automatically).
        if [ "$host_path" = "$HOME/.ssh" ] || [[ "$host_path" == "$HOME/.ssh/"* ]]; then
            config_error "Refusing to mount $host_path: it would expose SSH private keys."
            config_info "Use setting.ssh_agent_support=true instead (config/known_hosts are mounted read-only automatically)."
            exit 1
        fi

        # Never expose the host GnuPG private material either: agent forwarding
        # mirrors only the public keyring and forwards the agent socket.
        if [ "$host_path" = "$HOME/.gnupg" ] || [[ "$host_path" == "$HOME/.gnupg/"* ]]; then
            config_error "Refusing to mount $host_path: it would expose GnuPG private keys."
            config_info "Use setting.gpg_agent_support=true instead (only the public keyring and the agent socket are shared)."
            exit 1
        fi

        # A malformed entry must not reach docker as `-v host::mode`.
        if [ -z "$container_path" ] || [[ "$container_path" != /* ]]; then
            config_error "Invalid mount '$mount': container path must be absolute"
            exit 1
        fi

        # Validate mode is either not set or "rw"
        if [ "$mode" = "$container_path" ]; then
            # No mode specified, default to read-only
            DOCKER_MOUNT_ARGS+=(-v "$host_path:$container_path:ro")
        elif [ "$mode" = "rw" ]; then
            DOCKER_MOUNT_ARGS+=(-v "$host_path:$container_path:rw")
        else
            # Mode was specified, use it as-is
            DOCKER_MOUNT_ARGS+=(-v "$host_path:$container_path:$mode")
        fi
    done

    # Handle SSH agent forwarding if enabled. ensure_ssh_agent_ready has already
    # reported why a socket is unusable, so only a valid socket is mounted here.
    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
            # --mount (not -v) so a stale/missing source fails loudly instead
            # of Docker creating a directory at the host socket path, which
            # would break the real ssh-agent.
            mount_bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK"
        fi

        # Mount only the non-secret SSH files (read-only) so host-key
        # verification and host aliases keep working. Private keys (id_*,
        # *.pem, *.key) are never mounted; keys are used via the forwarded agent.
        local ssh_file
        for ssh_file in config known_hosts known_hosts2; do
            if [ -f "$HOME/.ssh/$ssh_file" ]; then
                DOCKER_MOUNT_ARGS+=(-v "$HOME/.ssh/$ssh_file:/home/coder/.ssh/$ssh_file:ro")
            fi
        done
    fi

    # Handle GnuPG agent forwarding if enabled: mount the mirrored public
    # keyring (rw so GPG can write lock files) and the host agent socket. The
    # private keys stay on the host; only public material is shared. The socket
    # is bind-mounted with --mount (a stale source fails loudly instead of Docker
    # creating a directory) at the container's GNUPGHOME path (and at its own XDG
    # path when applicable) so GPG discovers it without any host symlink.
    if [ "$GPG_AGENT_SUPPORT" = true ]; then
        GPG_SOCKET=""
        ensure_gpg_mirror
        if [ -d "$PI_HOME/.gnupg" ]; then
            mount_bind "$PI_HOME/.gnupg" "/home/coder/.gnupg"
        else
            config_warning "GnuPG agent support enabled but $PI_HOME/.gnupg could not be prepared"
        fi

        local main_socket extra_socket gpg_socket
        main_socket=$(resolve_gpg_agent_socket)
        extra_socket=$(resolve_gpg_agent_extra_socket)

        # Prefer the restricted "extra" socket (sign/decrypt only) so the
        # container cannot reconfigure the host agent. The full-control main
        # socket is only used when explicitly opted in.
        if [ -n "$extra_socket" ] && [ -S "$extra_socket" ]; then
            gpg_socket="$extra_socket"
        elif [ -n "$main_socket" ] && [ -S "$main_socket" ] && [ "$GPG_ALLOW_MAIN_SOCKET" = true ]; then
            gpg_socket="$main_socket"
            config_warning "Using the full-control GnuPG agent socket (setting.gpg_allow_main_socket=true)"
        else
            gpg_socket=""
        fi

        if [ -n "$gpg_socket" ] && [ -S "$gpg_socket" ]; then
            GPG_SOCKET="$gpg_socket"
            local mount_socket="$gpg_socket"
            # Docker cannot bind a socket from a per-user tmpfs (/run/user/...):
            # it creates an empty directory instead. Relay it through a socket on
            # a normal filesystem and mount that.
            if { [[ "$gpg_socket" == /run/* ]] || [ "${GPG_RELAY_FORCE:-false}" = true ]; } && [ "$GPG_RELAY" = true ]; then
                local relay
                if relay=$(start_gpg_relay "$gpg_socket"); then
                    GPG_RELAY_SOCKET="$relay"
                    mount_socket="$relay"
                else
                    config_warning "Could not start the GnuPG relay; is 'socat' installed on the host?"
                fi
            fi
            if [[ "$mount_socket" == /run/* ]]; then
                config_warning "GnuPG agent socket is on tmpfs and no relay is available; Docker may not be able to bind it."
            fi
            # Mount the socket at a dedicated path OUTSIDE the mirror. A socket
            # mounted *inside* another bind mount (the mirror) can be shadowed by
            # Docker, which left the agent socket invisible to gpg.
            mount_bind "$mount_socket" "/home/coder/.gnupg-agent/S.gpg-agent"
            # Expose it to gpg through GNUPGHOME with a symlink (gpg follows it).
            # ensure_gpg_mirror clears any previous link before each run.
            if [ -d "$PI_HOME/.gnupg" ]; then
                ln -sfn "/home/coder/.gnupg-agent/S.gpg-agent" "$PI_HOME/.gnupg/S.gpg-agent" 2>/dev/null ||
                    config_warning "Could not create the GnuPG agent socket symlink in $PI_HOME/.gnupg"
            fi
        else
            config_warning "GnuPG agent support enabled but no usable agent socket (extra socket missing and main fallback disabled)"
        fi
    fi
}

# Build docker environment variable arguments for automatic (non-secret)
# forwarding: agent sockets and doctor state flags.
# User secrets travel exclusively via setting.env_file (--env-file).
# Populates DOCKER_ENV_ARGS array with -e arguments
build_env_args() {
    DOCKER_ENV_ARGS=()

    # Handle SSH agent forwarding if enabled
    if [ "$SSH_AGENT_SUPPORT" = true ]; then
        if [ -n "$SSH_AUTH_SOCK" ]; then
            DOCKER_ENV_ARGS+=(-e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
        fi
    fi

    # Handle GnuPG agent forwarding if enabled. GNUPGHOME points at the mirrored
    # public keyring; XDG_RUNTIME_DIR is forwarded only when the agent socket
    # lives under it, so gpgconf inside the container resolves the mounted path.
    if [ "$GPG_AGENT_SUPPORT" = true ]; then
        DOCKER_ENV_ARGS+=(-e "GNUPGHOME=/home/coder/.gnupg")

        if [ -n "${GPG_SOCKET:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [[ "$GPG_SOCKET" == "$XDG_RUNTIME_DIR"/* ]]; then
            DOCKER_ENV_ARGS+=(-e "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
        fi
    fi

    # Forwarding state for `doctor` (non-secret): lets the in-container
    # diagnostics skip checks for forwardings the user disabled on purpose
    # instead of reporting them as failures.
    DOCKER_ENV_ARGS+=(-e "PI_DOCKERIZED_SSH_AGENT=$SSH_AGENT_SUPPORT")
    DOCKER_ENV_ARGS+=(-e "PI_DOCKERIZED_GPG_AGENT=$GPG_AGENT_SUPPORT")
    DOCKER_ENV_ARGS+=(-e "PI_DOCKERIZED_THEME=$THEME")
    DOCKER_ENV_ARGS+=(-e "PI_DOCKERIZED_MODEL=$MODEL")
    DOCKER_ENV_ARGS+=(-e "PI_DOCKERIZED_ENV_FILE=$([ -n "$ENV_FILE" ] && echo yes || echo no)")
}

# Build the docker --env-file argument from setting.env_file.
# The file holds secrets (dotenv KEY=VALUE lines) and is consumed host-side by
# `docker run --env-file`, so values never appear on the wrapper command line.
# The file itself is never mounted: it must live under CONFIG_DIR, which no
# mount ever serves. This is the only way user secrets reach the container.
# Populates DOCKER_ENV_FILE_ARGS array.
# Usage: build_env_file_args
build_env_file_args() {
    DOCKER_ENV_FILE_ARGS=()

    [ -n "$ENV_FILE" ] || return 0

    # Expand a leading ~, then canonicalize so `..` segments cannot escape the
    # containment check below (readlink -m needs no existing file; fall back to
    # the literal path where it is unavailable, e.g. macOS).
    local env_file="$ENV_FILE"
    if [[ "$env_file" == "~"* ]]; then
        env_file="$HOME${env_file#"~"}"
    fi
    local canonical
    if canonical=$(readlink -m "$env_file" 2>/dev/null) && [ -n "$canonical" ]; then
        env_file="$canonical"
    fi

    case "$env_file" in
    "$CONFIG_DIR" | "$CONFIG_DIR"/*) ;;
    *)
        config_error "Refusing env file outside \$CONFIG_DIR ($CONFIG_DIR): it could be mounted into the container."
        exit 1
        ;;
    esac

    if [ ! -f "$env_file" ]; then
        config_error "env file not found: $env_file"
        exit 1
    fi

    # A secrets file readable by group/others defeats its purpose.
    local mode=""
    mode=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null || true)
    if [ -n "$mode" ] && [ $((8#$mode & 8#044)) -ne 0 ]; then
        config_warning "env file is readable by group/others ($env_file); run: chmod 600 \"$env_file\""
    fi

    # Light format check (never prints values, only line numbers): docker
    # ignores blank lines and `#` comments, needs KEY=VALUE otherwise, does
    # not understand an `export ` prefix, and may choke on CRLF line endings.
    local line lineno=0 CR
    CR=$(printf '\r')
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in
        "" | \#*) continue ;;
        esac
        case "$line" in
        *"$CR"*) config_warning "env file line $lineno has CRLF line endings; use LF only" ;;
        esac
        case "$line" in
        *=*) ;;
        *)
            config_warning "env file line $lineno has no '=' and will be ignored by docker"
            continue
            ;;
        esac
        case "$line" in
        export\ * | export\	*)
            config_warning "env file line $lineno uses an 'export ' prefix, which docker does not strip"
            ;;
        esac
    done <"$env_file"

    # shellcheck disable=SC2034 # populated here, consumed by bin/pi-dockerized and tests
    DOCKER_ENV_FILE_ARGS=(--env-file "$env_file")
}
