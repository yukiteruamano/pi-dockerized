#!/bin/bash

# prompts.sh - interactive configuration and output helpers.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# ============================================
# INTERACTIVE CONFIGURATION
# ============================================

# Add or replace a custom mount entry, de-duplicating by container path.
# Usage: add_mount <host> <container> <rw|ro>
add_mount() {
    local host="$1" container="$2" mode="${3:-ro}"
    local entry="$host:$container"
    [ "$mode" = "rw" ] && entry="$host:$container:rw"

    local i
    for i in "${!CUSTOM_MOUNTS[@]}"; do
        local existing_container="${CUSTOM_MOUNTS[$i]#*:}"
        existing_container="${existing_container%%:*}"
        if [ "$existing_container" = "$container" ]; then
            CUSTOM_MOUNTS[$i]="$entry"
            return 0
        fi
    done
    local key
    key=$(next_custom_key "${CUSTOM_MOUNT_KEYS[@]:-}")
    CUSTOM_MOUNT_KEYS+=("$key")
    CUSTOM_MOUNTS+=("$entry")
}

# Suggest a container path for a host path (strip $HOME, keep the rest).
# Usage: suggest_container_path <host_path>
suggest_container_path() {
    local host_path="$1"
    compute_container_path "$host_path"
}

# Prompt for the configuration mode (basic/advanced/skip).
prompt_config_mode() {
    echo ""
    echo "Configuration mode:"
    echo "  1) Basic (recommended): SSH/GPG/docker toggles"
    echo "  2) Advanced: also configure mounts, limits and secrets"
    echo "  3) Skip"
    local choice=""
    read -r -p "Select option (1-3): " choice || choice=""
    case "$choice" in
    2) echo "advanced" ;;
    3) echo "skip" ;;
    *) echo "basic" ;;
    esac
}

# Interactively collect custom mounts.
prompt_custom_mounts() {
    echo ""
    read -r -p "Add custom volume mounts? (y/N): " add_any || add_any=""
    [[ "$add_any" =~ ^[Yy]$ ]] || return 0
    local host container mode
    while :; do
        read -r -p "Host path (empty to finish): " host || host=""
        [ -n "$host" ] || break
        host="${host/#\~/$HOME}"
        local suggested
        suggested=$(suggest_container_path "$host")
        read -r -p "Container path [$suggested]: " container || container=""
        container="${container:-$suggested}"
        read -r -p "Read-write? (y/N): " rw || rw=""
        local m="ro"
        [[ "$rw" =~ ^[Yy]$ ]] && m="rw"
        add_mount "$host" "$container" "$m"
        echo "Added: $host:$container:$m"
    done
}

# Upsert a KEY=VALUE line in the secrets file (never prints the value).
# Usage: env_file_upsert <file> <KEY> <value>
env_file_upsert() {
    local file="$1" key="$2" value="$3"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    [ -f "$file" ] || install -m 600 /dev/null "$file" 2>/dev/null || : >"$file"
    chmod 600 "$file" 2>/dev/null || true
    local tmp
    tmp=$(mktemp 2>/dev/null) || return 1
    grep -vE "^[[:space:]]*${key}=" "$file" >"$tmp" 2>/dev/null || : >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    cat "$tmp" >"$file" 2>/dev/null || true
    rm -f "$tmp"
}

# One-shot migration of legacy env.* entries into the secrets file.
migrate_legacy_env_vars() {
    local target="$1"
    [ -f "$CONFIG_FILE" ] || return 0
    local migrated=0 key value
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*env\. ]] || continue
        key="${key#env.}"
        key="${key//[[:space:]]/}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [ -n "$key" ] && [ -n "$value" ]; then
            env_file_upsert "$target" "$key" "$value"
            migrated=$((migrated + 1))
        fi
    done <"$CONFIG_FILE"
    [ "$migrated" -gt 0 ] && config_success "Migrated $migrated legacy env.* entr(ies) into $target"
    return 0
}

# Interactively collect secret keys for the env file (values never echoed).
prompt_env_vars() {
    echo ""
    echo "Secrets file (setting.env_file): provider API keys and tokens."
    echo "Known providers: ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY."
    read -r -p "Configure secrets now? (y/N): " do_env || do_env=""
    [[ "$do_env" =~ ^[Yy]$ ]] || return 0

    local env_file="$CONFIG_DIR/env"
    read -r -p "Secrets file path [$env_file]: " chosen || chosen=""
    env_file="${chosen:-$env_file}"
    env_file="${env_file/#\~/$HOME}"

    local key value
    while :; do
        read -r -p "Variable name (empty to finish): " key || key=""
        [ -n "$key" ] || break
        if ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            echo "Invalid variable name (use A-Z, 0-9, _)."
            continue
        fi
        read -r -s -p "Value for $key: " value || value=""
        echo ""
        env_file_upsert "$env_file" "$key" "$value"
        echo "Saved $key (value hidden)."
    done
    ENV_FILE="$env_file"
}

prompt_ssh_agent_support() {
    echo ""
    echo "SSH agent forwarding lets git use your host keys without mounting private keys."
    read -r -p "Enable SSH agent forwarding? (y/N): " ans || ans=""
    [[ "$ans" =~ ^[Yy]$ ]] && SSH_AGENT_SUPPORT=true || SSH_AGENT_SUPPORT=false
}

prompt_gpg_agent_support() {
    echo ""
    echo "GnuPG agent forwarding enables signed commits using your host keys."
    read -r -p "Enable GnuPG agent forwarding? (y/N): " ans || ans=""
    [[ "$ans" =~ ^[Yy]$ ]] && GPG_AGENT_SUPPORT=true || GPG_AGENT_SUPPORT=false
}

prompt_gpg_agent_options() {
    [ "$GPG_AGENT_SUPPORT" = true ] || return 0
    echo "  The restricted S.gpg-agent.extra socket is preferred by default."
    read -r -p "  Allow fallback to the full-control agent socket? (y/N): " ans || ans=""
    [[ "$ans" =~ ^[Yy]$ ]] && GPG_ALLOW_MAIN_SOCKET=true || GPG_ALLOW_MAIN_SOCKET=false
    read -r -p "  Auto-start the host gpg-agent when its socket is missing? (Y/n): " ans || ans=""
    [[ "$ans" =~ ^[Nn]$ ]] && GPG_AUTOSTART_AGENT=false || GPG_AUTOSTART_AGENT=true
}

prompt_docker_socket() {
    echo ""
    echo "The host Docker socket is root-equivalent. Enable only for Docker-in-Docker."
    read -r -p "Mount the host Docker socket? (y/N): " ans || ans=""
    [[ "$ans" =~ ^[Yy]$ ]] && DOCKER_SOCKET=true || DOCKER_SOCKET=false
}

prompt_network() {
    echo ""
    read -r -p "Container network [host|bridge] (default host): " ans || ans=""
    case "$ans" in
    bridge) NETWORK="bridge" ;;
    *) NETWORK="host" ;;
    esac
}

prompt_security_policy() {
    echo ""
    echo "Security policy: strict | balanced (default) | off"
    read -r -p "Select policy [balanced]: " ans || ans=""
    case "$ans" in
    strict | balanced | off) SECURITY_POLICY="$ans" ;;
    *) SECURITY_POLICY="balanced" ;;
    esac
}

prompt_memory() {
    echo ""
    read -r -p "Container memory limit (e.g. 4g, empty = none): " ans || ans=""
    if [ -z "$ans" ]; then
        MEMORY=""
    elif [[ "$ans" =~ ^[0-9]+[bBkKmMgG]$ ]]; then
        MEMORY="$ans"
    else
        config_warning "Invalid memory '$ans'; leaving unset"
        MEMORY=""
    fi
}

prompt_cpus() {
    echo ""
    read -r -p "Container CPU limit (e.g. 2, empty = none): " ans || ans=""
    if [ -z "$ans" ]; then
        CPUS=""
    elif [[ "$ans" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        CPUS="$ans"
    else
        config_warning "Invalid cpus '$ans'; leaving unset"
        CPUS=""
    fi
}

prompt_theme() {
    echo ""
    read -r -p "Pi theme (built-in, empty = default): " ans || ans=""
    if [ -z "$ans" ]; then
        THEME=""
    elif [[ "$ans" =~ ^[A-Za-z0-9_-]+$ ]]; then
        THEME="$ans"
    else
        config_warning "Invalid theme '$ans'; leaving unset"
        THEME=""
    fi
}

prompt_model() {
    echo ""
    read -r -p "Startup model (passed as 'pi --model', empty = default): " ans || ans=""
    if [ -z "$ans" ]; then
        MODEL=""
    elif [[ "$ans" =~ ^[A-Za-z0-9._:/@-]+$ ]]; then
        MODEL="$ans"
    else
        config_warning "Invalid model '$ans'; leaving unset"
        MODEL=""
    fi
}

# Full interactive configuration wizard.
interactive_config_setup() {
    local mode
    mode=$(prompt_config_mode)
    [ "$mode" = "skip" ] && return 0

    # Start from an existing config when present so re-runs are additive.
    if config_exists; then
        load_config >/dev/null 2>&1 || true
    fi

    prompt_ssh_agent_support
    prompt_gpg_agent_support
    prompt_gpg_agent_options
    prompt_docker_socket
    prompt_network
    prompt_security_policy

    if [ "$mode" = "advanced" ]; then
        prompt_memory
        prompt_cpus
        prompt_theme
        prompt_model
        prompt_custom_mounts
        prompt_env_vars
    fi

    save_config
}

# ============================================
# OUTPUT HELPERS
# ============================================

# Print parsed configuration.
print_config() {
    echo "Pi Dockerized configuration"
    echo "  Config file:        $CONFIG_FILE"
    echo "  State tree:         $PI_HOME"
    echo "  SSH agent:          $SSH_AGENT_SUPPORT"
    echo "  GnuPG agent:        $GPG_AGENT_SUPPORT"
    echo "  Docker socket:      $DOCKER_SOCKET"
    echo "  Network:            $NETWORK"
    echo "  Security policy:    $SECURITY_POLICY"
    echo "  Memory:             ${MEMORY:-<none>}"
    echo "  CPUs:               ${CPUS:-<none>}"
    echo "  Secrets file:       ${ENV_FILE:-<none>}"
    echo "  Theme:              ${THEME:-<default>}"
    echo "  Model:              ${MODEL:-<default>}"
    if [ ${#CUSTOM_MOUNTS[@]} -gt 0 ]; then
        echo "  Custom mounts:"
        local i
        for i in "${!CUSTOM_MOUNTS[@]}"; do
            echo "    mount.${CUSTOM_MOUNT_KEYS[$i]}=${CUSTOM_MOUNTS[$i]}"
        done
    fi
}

# Print a docker command array without executing it, one arg per line.
# Usage: dry_run_print <args...>
dry_run_print() {
    local arg
    for arg in "$@"; do
        case "$arg" in
        *" "*) printf '%s\n' "\"$arg\"" ;;
        *) printf '%s\n' "$arg" ;;
        esac
    done
}
