#!/bin/bash

# profile.sh - the `profile` command: every named-profile operation lives here
# (list, create, remove, show, path, check, fix, run).
# Sourced by bin/pi-dockerized (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# Every profile, "default" included, is a whole separate tree under
# $PI_CONFIG_ROOT/profiles/NAME: its own config, secrets file, MCP servers, keys
# and sessions. Nothing is shared between profiles, so accounts never mix. The
# root config only routes commands to a profile (default_profile, profile.map).

PROFILE_NAME_RE='^[a-z0-9][a-z0-9_-]{0,31}$'

_profile_usage() {
    cat >&2 <<EOF
Usage: $0 profile <command>
  list                      named profiles (the active one is marked)
  create NAME               new profile with its own config and state tree
  remove NAME [--yes]       delete a profile and ALL its state
  show [NAME] [--sources]   the profile's settings
  path [NAME]               the profile's directory
  check [NAME]              audit the whole profile (read-only)
  fix [NAME]                repair what check reports, then check again
  run NAME [RUN ARGS]       start a session with the profile ('run' flags)
  root [path|edit]          the root config: default_profile and profile.map
NAME defaults to the active profile; 'default' always exists.
EOF
}

# Directory of a profile.
# Usage: dir=$(profile_dir <name>)
profile_dir() {
    printf '%s' "$PI_CONFIG_ROOT/profiles/$1"
}

# Comparison key for duplicate detection: names that only differ by case or
# by `-` versus `_` read as the same profile to a person.
_profile_key() {
    printf '%s' "$1" | tr 'A-Z_' 'a-z-'
}

# Every entry under profiles/ (valid or not), one per line.
_profile_entries() {
    local dir
    for dir in "$PI_CONFIG_ROOT"/profiles/*; do
        [ -d "$dir" ] && basename "$dir"
    done
    return 0
}

# The other profile entries that read as the same name as <name>.
# Usage: conflicts=$(profile_conflicts <name>)
profile_conflicts() {
    local name="$1" key entry
    key=$(_profile_key "$name")
    while IFS= read -r entry; do
        [ -n "$entry" ] && [ "$entry" != "$name" ] && [ "$(_profile_key "$entry")" = "$key" ] && printf '%s\n' "$entry"
    done < <(_profile_entries)
    return 0
}

# The other profile entries whose directory resolves to the same tree as
# <name> (a symlinked profile is the same profile under two names).
# Usage: aliases=$(profile_aliases <name>)
profile_aliases() {
    local name="$1" real entry
    real=$(canonical_path "$(profile_dir "$name")")
    while IFS= read -r entry; do
        [ -n "$entry" ] && [ "$entry" != "$name" ] &&
            [ "$(canonical_path "$(profile_dir "$entry")")" = "$real" ] && printf '%s\n' "$entry"
    done < <(_profile_entries)
    return 0
}

# Validate a name for create/remove ("default" always exists).
_validate_profile_name() {
    local name="$1"
    if [ -z "$name" ]; then
        _profile_usage
        return 1
    fi
    if [ "$name" = default ]; then
        print_error "'default' is the default profile; it always exists and cannot be created or removed."
        return 1
    fi
    if ! [[ "$name" =~ $PROFILE_NAME_RE ]]; then
        print_error "Invalid profile name '$name' (use a-z, 0-9, - or _, up to 32 characters)."
        return 1
    fi
}

# Resolve a NAME argument (empty = the active profile) and require that it
# exists. Prints the name.
# Usage: name=$(require_profile <name|"">)
require_profile() {
    local name="${1:-${PI_PROFILE:-default}}"
    if [ "$name" != default ] && ! [[ "$name" =~ $PROFILE_NAME_RE ]]; then
        print_error "Invalid profile name '$name' (use a-z, 0-9, - or _, up to 32 characters)."
        return "$E_USAGE"
    fi
    if [ "$name" != default ] && [ ! -d "$(profile_dir "$name")" ]; then
        print_error "Profile '$name' does not exist (see '$0 profile list')."
        return "$E_USAGE"
    fi
    printf '%s' "$name"
}

# Reserve a new profile directory: refuses invalid names, existing ones and
# names that read as an existing profile, then creates the directory with a
# single `mkdir` so two concurrent creates cannot both succeed.
# Usage: claim_profile_dir <name>
claim_profile_dir() {
    local name="$1" dir conflicts
    _validate_profile_name "$name" || return "$E_USAGE"
    dir=$(profile_dir "$name")
    conflicts=$(profile_conflicts "$name")
    if [ -n "$conflicts" ]; then
        print_error "Profile '$name' would duplicate existing profile '${conflicts%%$'\n'*}' (names differ only by case or -/_)."
        return "$E_USAGE"
    fi
    mkdir -p "$PI_CONFIG_ROOT/profiles" || return 1
    if ! (umask 077 && mkdir -- "$dir") 2>/dev/null; then
        if [ -e "$dir" ]; then
            print_error "Profile '$name' already exists."
            return "$E_USAGE"
        fi
        print_error "Could not create $dir"
        return 1
    fi
}

# Run a command with every path bound to the named profile, in a subshell so
# the caller's own profile is left untouched.
# Usage: with_profile <name> <command> [args...]
with_profile() {
    local name="$1"
    shift
    # shellcheck disable=SC2034 # globals read by the sourced lib/config modules
    (
        PI_PROFILE=""
        [ "$name" = default ] || PI_PROFILE="$name"
        CONFIG_DIR=$(profile_dir "$name")
        CONFIG_FILE="$CONFIG_DIR/config"
        PI_HOME="$CONFIG_DIR/home"
        EXT_AGENT_DIR="$PI_HOME/.pi/ext-agent"
        GPG_RELAY_DIR="$CONFIG_DIR/gnupg-relay"
        _CONFIG_LOADED=false
        CONFIG_BACKED_UP=false
        "$@"
    )
}

# Routing entries that a profile must not carry: they are read from the root
# config only and ignored elsewhere.
_root_only_lines() {
    grep -nE "$ROUTING_LINE_RE" "$CONFIG_FILE" 2>/dev/null
    return 0
}

# Permission bits of a path ("" when unknown).
_mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

# ============================================
# CHECK (read-only)
# ============================================

# The profile directory itself: a real directory owned by this user, private,
# and not the same tree or name as another profile.
_check_profile_dir() {
    local name="$1" ok=0 other mode
    if [ ! -d "$CONFIG_DIR" ]; then
        print_warning "$CONFIG_DIR does not exist yet; fix creates it"
        return 1
    fi
    if [ -L "$CONFIG_DIR" ]; then
        print_error "$CONFIG_DIR is a symlink (to $(canonical_path "$CONFIG_DIR")): a profile must be its own directory."
        ok=1
    fi
    if [ -L "$PI_HOME" ]; then
        print_error "$PI_HOME is a symlink: the state tree must belong to this profile only."
        ok=1
    fi
    while IFS= read -r other; do
        [ -n "$other" ] || continue
        print_error "Profiles '$name' and '$other' are the same directory; remove one of them."
        ok=1
    done < <(profile_aliases "$name")
    while IFS= read -r other; do
        [ -n "$other" ] || continue
        print_error "Profiles '$name' and '$other' differ only by case or -/_; rename or remove one."
        ok=1
    done < <(profile_conflicts "$name")
    if [ ! -O "$CONFIG_DIR" ]; then
        print_error "$CONFIG_DIR is not owned by you."
        ok=1
    fi
    mode=$(_mode_of "$CONFIG_DIR")
    if [ -n "$mode" ] && [ $((8#$mode & 8#077)) -ne 0 ]; then
        print_warning "$CONFIG_DIR is accessible to group/others ($mode); fix restores 700"
        ok=1
    fi
    [ "$ok" -eq 0 ] && print_success "profile directory ok ($CONFIG_DIR)"
    return "$ok"
}

# The config file: present, private, parsing cleanly, and without root-only
# routing entries in a named profile.
_check_profile_config() {
    local name="$1" ok=0 mode warnings
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "config file missing ($CONFIG_FILE); fix seeds it"
        return 1
    fi
    mode=$(_mode_of "$CONFIG_FILE")
    if [ -n "$mode" ] && [ $((8#$mode & 8#077)) -ne 0 ]; then
        print_warning "config file is accessible to group/others ($mode); fix restores 600"
        ok=1
    fi
    warnings=$(load_config 2>&1 >/dev/null) || true
    if [ -n "$warnings" ]; then
        printf '%s\n' "$warnings" >&2
        print_warning "config file has invalid entries; edit it with '$0 --profile $name config edit'"
        ok=1
    fi
    if [ -n "$(_root_only_lines)" ]; then
        print_warning "config sets root-only entries (default_profile, profile.map.*) that a profile ignores; fix comments them out"
        ok=1
    fi
    [ "$ok" -eq 0 ] && print_success "config file ok"
    return "$ok"
}

# The secrets file: when set, it must belong to this profile and must not set
# variables that control the sandbox. Values are never read, only key names.
# Presence and permissions are reported by check_agent_state.
_check_profile_env() {
    local name="$1" env_file line key ok=0
    load_config >/dev/null 2>&1 || true
    if [ -z "$ENV_FILE" ]; then
        print_info "no secrets file (setting.env_file); add keys with '$0 --profile $name install'"
        return 0
    fi
    env_file=$(resolve_env_file "$ENV_FILE")
    if ! env_file_in_profile "$env_file"; then
        print_error "setting.env_file ($env_file) is outside this profile's directory: secrets must not be shared between profiles."
        print_info "Point it at $CONFIG_DIR/env ('$0 --profile $name install' adds keys there)."
        return 1
    fi
    [ -f "$env_file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "" | \#*) continue ;; esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key#export[[:space:]]}"
        key="${key%"${key##*[![:space:]]}"}"
        if env_key_forbidden "$key"; then
            print_error "secrets file sets $key, which controls the sandbox; remove it."
            ok=1
        fi
    done <"$env_file"
    [ "$ok" -eq 0 ] && print_success "secrets file belongs to this profile"
    return "$ok"
}

# Audit one profile (paths already bound by with_profile). Returns 1 when
# anything needs attention.
_check_profile() {
    local name="$1" issues=0
    echo "Profile '$name' ($CONFIG_DIR)"
    _check_profile_dir "$name" || issues=$((issues + 1))
    _check_profile_config "$name" || issues=$((issues + 1))
    _check_profile_env "$name" || issues=$((issues + 1))
    check_agent_state || issues=$((issues + 1))
    if [ "$name" = default ]; then
        check_root_config || issues=$((issues + 1))
    fi
    if [ "$issues" -eq 0 ]; then
        print_success "Profile '$name' is healthy."
        return 0
    fi
    print_error "Profile '$name': $issues area(s) need attention."
    return 1
}

# ============================================
# FIX
# ============================================

# Comment out the routing entries of a profile's config (backed up first),
# so the file no longer suggests routing it does not do.
_comment_root_only_lines() {
    [ -n "$(_root_only_lines)" ] || return 0
    backup_config_file
    comment_routing_lines "$CONFIG_FILE"
    print_success "Commented out root-only entries in $CONFIG_FILE"
}

# Repair a profile (paths bound by with_profile): only structure and
# permissions; never secrets, never a value the user wrote. Refuses to write
# through a symlinked profile, which would change another profile's tree.
_fix_profile() {
    local name="$1" env_file
    if [ -L "$CONFIG_DIR" ] || [ -L "$PI_HOME" ]; then
        print_error "Not repairing '$name': its directory or state tree is a symlink (see below)."
        return 0
    fi
    print_info "Repairing profile '$name'..."
    (umask 077 && mkdir -p "$CONFIG_DIR") || return 1
    if [ ! -f "$CONFIG_FILE" ]; then
        init_config_file
    fi
    _comment_root_only_lines
    if [ "$name" = default ] && [ -f "$ROOT_CONFIG_FILE" ] && [ -O "$ROOT_CONFIG_FILE" ]; then
        chmod 600 "$ROOT_CONFIG_FILE" 2>/dev/null || true
    fi
    if [ -O "$CONFIG_FILE" ]; then chmod 600 "$CONFIG_FILE" 2>/dev/null || true; fi
    load_config >/dev/null 2>&1 || true
    if [ -n "$ENV_FILE" ]; then
        env_file=$(resolve_env_file "$ENV_FILE")
        # Keys borrowed from another profile are dropped in favor of this
        # profile's own file when it has one; otherwise check reports it.
        if ! env_file_in_profile "$env_file" && [ -f "$CONFIG_DIR/env" ]; then
            env_file="$CONFIG_DIR/env"
            config_upsert setting.env_file "$env_file"
            print_success "setting.env_file now points at this profile's own $env_file"
        fi
        if env_file_in_profile "$env_file" && [ -f "$env_file" ] && [ -O "$env_file" ]; then
            chmod 600 "$env_file" 2>/dev/null || true
        fi
    fi
    repair_agent_state
    echo ""
}

# ============================================
# LIST / CREATE / REMOVE
# ============================================

# List the named profiles; entries the wrapper cannot use are reported.
list_profiles() {
    local entry found=false note
    if [ -z "$PI_PROFILE" ]; then echo "default (active)"; else echo "default"; fi
    while IFS= read -r entry; do
        [ -n "$entry" ] && [ "$entry" != default ] || continue
        if ! [[ "$entry" =~ $PROFILE_NAME_RE ]]; then
            print_warning "Ignoring '$(profile_dir "$entry")': not a valid profile name."
            continue
        fi
        found=true
        note=""
        [ "$entry" = "$PI_PROFILE" ] && note=" (active)"
        if [ -n "$(profile_aliases "$entry")$(profile_conflicts "$entry")" ] || [ -L "$(profile_dir "$entry")" ]; then
            note="$note (duplicate: run '$0 profile check $entry')"
        fi
        echo "$entry$note"
    done < <(_profile_entries)
    [ "$found" = true ] || print_info "No named profiles yet: use '$0 profile create NAME' to create one."
}

# Seed a profile's own config file and state tree (paths bound by
# with_profile), exactly where the wrapper looks for them under --profile.
_seed_profile() {
    init_config_file && ensure_pi_dirs
}

# Usage: create_profile <name>
create_profile() {
    local name="$1"
    claim_profile_dir "$name" || exit $?
    with_profile "$name" _seed_profile || exit 1
    print_success "Created profile '$name' at $(profile_dir "$name")"
    print_info "Configure it with '$0 --profile $name install' (keys, settings) or '$0 --profile $name config edit'."
}

# Usage: remove_profile <name> [--yes]
remove_profile() {
    local name="$1" dir answer=""
    _validate_profile_name "$name" || exit "$E_USAGE"
    dir=$(profile_dir "$name")
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        print_error "Profile '$name' does not exist."
        exit "$E_USAGE"
    fi
    if docker ps --filter "label=pi-dockerized.profile=$name" --format '{{.Names}}' 2>/dev/null | grep -q .; then
        print_error "Profile '$name' has running sessions; stop them first ('$0 ps')."
        exit 1
    fi
    if [ "${2:-}" != "--yes" ]; then
        printf "Delete profile '%s' and ALL its state (config, secrets, sessions) at %s? [y/N] " "$name" "$dir"
        read -r answer || true
        case "$answer" in
        y | Y | yes | YES) ;;
        *)
            print_info "Aborted."
            return 0
            ;;
        esac
    fi
    # A symlinked profile is an alias: drop the link, never the tree behind it.
    if [ -L "$dir" ]; then
        rm -f -- "$dir"
    else
        rm -rf -- "$dir"
    fi
    print_success "Removed profile '$name'."
    check_root_config >/dev/null 2>&1 ||
        print_warning "The root config still routes to '$name' (default_profile or profile.map); run '$0 profile check default'."
}

# `profile root [path|edit]`: the routing config, created on first edit.
manage_root_config() {
    case "$1" in
    path) echo "$ROOT_CONFIG_FILE" ;;
    edit)
        [ -f "$ROOT_CONFIG_FILE" ] || init_root_config || exit 1
        edit_file "$ROOT_CONFIG_FILE"
        ;;
    *)
        _profile_usage
        exit "$E_USAGE"
        ;;
    esac
}

# ============================================
# DISPATCH
# ============================================

# `profile <command>`: see _profile_usage.
manage_profile() {
    local action="${1:-list}" name
    shift || true
    case "$action" in
    list)
        list_profiles
        ;;
    create)
        [ $# -eq 1 ] || {
            _profile_usage
            exit "$E_USAGE"
        }
        create_profile "$1"
        ;;
    remove | rm)
        [ $# -ge 1 ] && [ $# -le 2 ] || {
            _profile_usage
            exit "$E_USAGE"
        }
        remove_profile "$@"
        ;;
    show)
        local arg target=""
        local -a show_args=()
        for arg in "$@"; do
            if [ "$arg" = --sources ]; then show_args=(--sources); else target="$arg"; fi
        done
        name=$(require_profile "$target") || exit $?
        with_profile "$name" show_config show "${show_args[@]}"
        ;;
    path)
        name=$(require_profile "${1:-}") || exit $?
        profile_dir "$name"
        echo
        ;;
    check)
        name=$(require_profile "${1:-}") || exit $?
        with_profile "$name" _check_profile "$name"
        ;;
    fix)
        name=$(require_profile "${1:-}") || exit $?
        with_profile "$name" _fix_profile "$name"
        with_profile "$name" _check_profile "$name"
        ;;
    run)
        [ $# -ge 1 ] || {
            _profile_usage
            exit "$E_USAGE"
        }
        name=$(require_profile "$1") || exit $?
        shift
        PI_PROFILE_SOURCE=explicit exec "$0" --profile "$name" run "$@"
        ;;
    root)
        manage_root_config "${1:-path}"
        ;;
    help | --help | -h)
        _profile_usage
        ;;
    *)
        print_error "Unknown profile command: $action"
        _profile_usage
        exit "$E_USAGE"
        ;;
    esac
}
