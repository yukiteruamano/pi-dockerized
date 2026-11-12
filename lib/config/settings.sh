#!/bin/bash

# settings.sh - config file loading, saving and key/value editing (the file a
# fresh profile starts from is written by config-file.sh).
# Sourced by lib/config-lib.sh (not executable directly).
# shellcheck disable=SC2034 # globals are defined here and consumed by the other sourced modules
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# The config is INI-style: `setting.<key>=<value>` and `mount.<name>=<spec>`.
# Every setting is described once in _setting_spec; the loader, `config set`
# and the saver all go through it, so validation cannot drift between them.

# Every setting key, in the order they are written to a fresh file.
SETTING_KEYS=(
    ssh_agent_support gpg_agent_support gpg_allow_main_socket gpg_autostart_agent
    gpg_relay docker_socket git_readonly network security_policy allowed_tools
    verify_updates memory cpus pids_limit env_file theme model default_profile
)

# ============================================
# SETTING DEFINITIONS
# ============================================

# Describe one setting as "<VARIABLE> <type> <arg> <default>".
#   bool  true|false
#   enum  comma-separated choices in <arg>; empty value resets to <default>
#   re    value must match the ERE in <arg> (empty must match to be accepted)
#   any   verbatim
# Returns 1 for an unknown key.
_setting_spec() {
    case "$1" in
    ssh_agent_support) echo "SSH_AGENT_SUPPORT bool" ;;
    gpg_agent_support) echo "GPG_AGENT_SUPPORT bool" ;;
    gpg_allow_main_socket) echo "GPG_ALLOW_MAIN_SOCKET bool" ;;
    gpg_autostart_agent) echo "GPG_AUTOSTART_AGENT bool" ;;
    gpg_relay) echo "GPG_RELAY bool" ;;
    docker_socket) echo "DOCKER_SOCKET bool" ;;
    git_readonly) echo "GIT_READONLY bool" ;;
    verify_updates) echo "VERIFY_UPDATES bool" ;;
    network) echo "NETWORK enum host,bridge host" ;;
    security_policy) echo "SECURITY_POLICY enum strict,balanced,off balanced" ;;
    allowed_tools) echo "ALLOWED_TOOLS re ^[A-Za-z0-9_.:,+*=-]*$" ;;
    memory) echo "MEMORY re ^([0-9]+[bBkKmMgG])?$" ;;
    cpus) echo "CPUS re ^([0-9]+(\\.[0-9]+)?)?$" ;;
    pids_limit) echo "PIDS_LIMIT re ^([1-9][0-9]{0,5}|unlimited)?$" ;;
    default_profile) echo "DEFAULT_PROFILE re ^([a-z0-9][a-z0-9_-]{0,31})?$" ;;
    theme) echo "THEME re ^[A-Za-z0-9_-]*$" ;;
    model) echo "MODEL re ^[A-Za-z0-9._:/@-]*$" ;;
    env_file) echo "ENV_FILE any" ;;
    *) return 1 ;;
    esac
}

# Reset every setting and mount to its default (before loading a file).
reset_settings() {
    CUSTOM_MOUNTS=()
    CUSTOM_MOUNT_KEYS=()
    SETTINGS_FROM_FILE=()
    SSH_AGENT_SUPPORT=false
    GPG_AGENT_SUPPORT=false
    GPG_ALLOW_MAIN_SOCKET=false
    GPG_AUTOSTART_AGENT=true
    GPG_RELAY=true
    DOCKER_SOCKET=false
    GIT_READONLY=true
    VERIFY_UPDATES=true
    NETWORK="host"
    SECURITY_POLICY="balanced"
    ALLOWED_TOOLS=""
    MEMORY=""
    CPUS=""
    PIDS_LIMIT="4096"
    DEFAULT_PROFILE=""
    ENV_FILE=""
    THEME=""
    MODEL=""
}

# Validate <value> for setting <key> and assign it to its variable.
# Returns 0 (applied), 1 (invalid, warned, variable untouched), 2 (unknown key).
# Usage: _apply_setting <key> <value>
_apply_setting() {
    local key="$1" value="$2" spec var type arg default
    spec=$(_setting_spec "$key") || return 2
    read -r var type arg default <<<"$spec"
    case "$type" in
    bool)
        case "$value" in
        true | false) ;;
        *)
            config_warning "Invalid value '$value' for setting.$key (use true|false); keeping '${!var}'"
            return 1
            ;;
        esac
        ;;
    enum)
        if [ -z "$value" ]; then
            value="$default"
        else
            case ",$arg," in
            *",$value,"*) ;;
            *)
                config_warning "Invalid value '$value' for setting.$key (use ${arg//,/|}); keeping '${!var}'"
                return 1
                ;;
            esac
        fi
        ;;
    re)
        if ! [[ "$value" =~ $arg ]]; then
            config_warning "Invalid value '$value' for setting.$key (unexpected format); keeping '${!var}'"
            return 1
        fi
        ;;
    esac
    printf -v "$var" '%s' "$value"
}

# Print the current value of setting <key>; returns 1 for an unknown key.
# Usage: _get_setting <key>
_get_setting() {
    local spec var
    spec=$(_setting_spec "$1") || return 1
    var="${spec%% *}"
    printf '%s' "${!var}"
}

# Trim leading/trailing whitespace of the variable named by $1, in place.
_trim() {
    local -n __trim_ref="$1"
    __trim_ref="${__trim_ref#"${__trim_ref%%[![:space:]]*}"}"
    __trim_ref="${__trim_ref%"${__trim_ref##*[![:space:]]}"}"
}

# ============================================
# LOADING AND SAVING
# ============================================

# Load the config file in one pass, preserving each mount's original key suffix
# so save_config can re-emit it unchanged. Unknown settings and malformed lines
# are reported with their line number, never silently ignored.
load_config() {
    if ! config_exists; then
        config_warning "Config file not found at $CONFIG_FILE"
        return 1
    fi

    reset_settings

    local key value lineno=0 rc
    while IFS='=' read -r key value || [ -n "$key" ]; do
        lineno=$((lineno + 1))
        _trim key
        _trim value
        case "$key" in
        "" | \#*) continue ;;
        mount.*)
            key="${key#mount.}"
            if [ -n "$value" ] && [ -n "$key" ]; then
                CUSTOM_MOUNT_KEYS+=("$key")
                CUSTOM_MOUNTS+=("$value")
            fi
            ;;
        env.*)
            # The host-environment passthrough was removed; secrets now live in
            # setting.env_file (see migrate_legacy_env_vars).
            [ -n "$value" ] && config_warning "Ignoring legacy '${key#env.}' (env.* passthrough was removed); move the value to setting.env_file instead."
            ;;
        profile.map.* | setting.default_profile)
            # Routing entries belong to the root config (read by
            # bin/pi-dockerized and profile_for_dir); a profile ignores them
            # and `profile check` reports them.
            ;;
        setting.*)
            _apply_setting "${key#setting.}" "$value"
            rc=$?
            if [ "$rc" -eq 2 ]; then
                config_warning "config line $lineno: unknown setting '${key#setting.}' (ignored)"
            elif [ "$rc" -eq 0 ]; then
                SETTINGS_FROM_FILE+=("$(_setting_key "${key#setting.}")")
            fi
            ;;
        *)
            config_warning "config line $lineno: unrecognized entry '$key' (ignored)"
            ;;
        esac
    done <"$CONFIG_FILE"
    DEFAULT_PROFILE=$(root_default_profile)

    return 0
}

# Allocate an unused "customN" key suffix for a new entry, avoiding collisions
# with already-used suffixes passed as arguments.
# Usage: key=$(next_custom_key "${CUSTOM_MOUNT_KEYS[@]}")
next_custom_key() {
    local n=1 existing
    while :; do
        local taken=false
        for existing in "$@"; do
            if [ "$existing" = "custom$n" ]; then
                taken=true
                break
            fi
        done
        if [ "$taken" = false ]; then
            echo "custom$n"
            return 0
        fi
        n=$((n + 1))
    done
}

# Copy the config file to a timestamped backup, keeping the last 5. Runs at
# most once per process (bulk saves call config_upsert once per key); a no-op
# when the file does not exist yet.
CONFIG_BACKED_UP=false
backup_config_file() {
    [ "$CONFIG_BACKED_UP" = true ] && return 0
    CONFIG_BACKED_UP=true
    [ -f "$CONFIG_FILE" ] || return 0
    local backup
    backup="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$CONFIG_FILE" "$backup" 2>/dev/null || return 0
    # Timestamped names sort chronologically: keep the newest five. A glob
    # (not `ls | xargs`) so paths with spaces survive.
    local -a backups=("$CONFIG_FILE".bak.*)
    local i
    for ((i = 0; i < ${#backups[@]} - 5; i++)); do
        rm -f -- "${backups[$i]}"
    done
}

# Set <full_key>=<value> in the config file, in place. The first active line is
# updated (later duplicates dropped); otherwise the first commented template
# `# <full_key>=...` becomes the active line; otherwise the line is appended.
# Comments and entries it does not know about are left alone.
# Usage: config_upsert <full_key> <value>
config_upsert() {
    backup_config_file
    local full="$1" value="$2"
    local -a lines=() out=()
    [ -f "$CONFIG_FILE" ] && mapfile -t lines <"$CONFIG_FILE"

    local i trimmed commented active=-1 template=-1
    for i in "${!lines[@]}"; do
        trimmed="${lines[$i]#"${lines[$i]%%[![:space:]]*}"}"
        case "$trimmed" in
        "$full="*)
            [ "$active" -lt 0 ] && active=$i
            ;;
        \#*)
            commented="${trimmed#\#}"
            commented="${commented#"${commented%%[![:space:]]*}"}"
            case "$commented" in
            "$full="*) [ "$template" -lt 0 ] && template=$i ;;
            esac
            ;;
        esac
    done

    local seen=false
    for i in "${!lines[@]}"; do
        trimmed="${lines[$i]#"${lines[$i]%%[![:space:]]*}"}"
        if [ "$i" -eq "$active" ] || { [ "$active" -lt 0 ] && [ "$i" -eq "$template" ]; }; then
            out+=("$full=$value")
            seen=true
        elif [[ "$trimmed" == "$full="* ]]; then
            continue # duplicate of an active line
        else
            out+=("${lines[$i]}")
        fi
    done
    [ "$seen" = true ] || out+=("$full=$value")

    printf '%s\n' "${out[@]}" >"$CONFIG_FILE"
}

# Replace every active mount.* line with the current CUSTOM_MOUNTS, dropping
# exact duplicates (idempotent across re-runs).
_config_rewrite_mounts() {
    local -a lines=() out=()
    [ -f "$CONFIG_FILE" ] && mapfile -t lines <"$CONFIG_FILE"

    local line trimmed
    for line in "${lines[@]}"; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" == mount.* ]] || out+=("$line")
    done

    local i entry seen="" any=false
    for i in "${!CUSTOM_MOUNTS[@]}"; do
        entry="mount.${CUSTOM_MOUNT_KEYS[$i]}=${CUSTOM_MOUNTS[$i]}"
        [[ "$seen" == *"|$entry|"* ]] && continue
        seen="$seen|$entry|"
        out+=("$entry")
        any=true
    done
    [ "$any" = true ] || [ "${#out[@]}" -gt 0 ] || return 0

    printf '%s\n' "${out[@]}" >"$CONFIG_FILE"
}

# Write the current settings and mounts to the config file, keeping its
# comments and any entries this version does not know about.
save_config() {
    mkdir -p "$CONFIG_DIR"
    config_exists || init_config_file >/dev/null

    local key
    for key in "${SETTING_KEYS[@]}"; do
        # Routing lives in the root config (config_set_value writes it there).
        [ "$key" = default_profile ] && continue
        config_upsert "setting.$key" "$(_get_setting "$key")"
    done
    _config_rewrite_mounts

    config_success "Saved configuration to $CONFIG_FILE"
}

# ============================================
# KEY/VALUE ACCESS (config get / config set)
# ============================================

# Strip an optional "setting." prefix from a user-supplied key.
_setting_key() {
    printf '%s' "${1#setting.}"
}

# Where the current value of <key> comes from: "config file" or "default".
# Usage: setting_source <key>
setting_source() {
    local key k
    key=$(_setting_key "$1") || return 1
    if [ "$key" = default_profile ]; then
        if [ -n "$DEFAULT_PROFILE" ]; then echo "root config"; else echo "default"; fi
        return 0
    fi
    for k in "${SETTINGS_FROM_FILE[@]}"; do
        [ "$k" = "$key" ] && {
            echo "config file"
            return 0
        }
    done
    echo "default"
}

# Print the value of a setting from the config file.
# Usage: config_get_value <key> [--source]
config_get_value() {
    local key with_source=false
    key=$(_setting_key "$1")
    if ! _setting_spec "$key" >/dev/null; then
        config_error "Unknown setting '$key'. Known: ${SETTING_KEYS[*]}"
        return 1
    fi
    case "${2:-}" in
    "") ;;
    --source) with_source=true ;;
    *)
        config_error "Usage: $0 config get <setting> [--source]"
        return 1
        ;;
    esac
    load_config >/dev/null 2>&1 || true
    if [ "$with_source" = true ]; then
        printf '%s  (%s)\n' "$(_get_setting "$key")" "$(setting_source "$key")"
    else
        _get_setting "$key"
        echo
    fi
}

# Validate and persist one setting.
# Usage: config_set_value <key> <value>
config_set_value() {
    local key value="$2"
    key=$(_setting_key "$1")
    if [[ "$value" == *$'\n'* ]]; then
        config_error "A value cannot contain a newline."
        return 1
    fi
    # Validate in a subshell so a rejected value never leaks into the globals.
    local rc=0
    (_apply_setting "$key" "$value") || rc=$?
    case "$rc" in
    0) ;;
    2)
        config_error "Unknown setting '$key'. Known: ${SETTING_KEYS[*]}"
        return 1
        ;;
    *)
        config_error "Not saved: invalid value for setting.$key."
        return 1
        ;;
    esac
    if [ "$key" = default_profile ]; then
        _set_root_default_profile "$value"
        return
    fi
    mkdir -p "$CONFIG_DIR"
    config_exists || init_config_file >/dev/null
    config_upsert "setting.$key" "$value"
    config_success "setting.$key=$value"
}
