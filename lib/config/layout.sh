#!/bin/bash

# layout.sh - the on-disk layout of the config root and its one-time migration.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# Every profile, "default" included, lives in $PI_CONFIG_ROOT/profiles/NAME;
# the root only keeps the routing config (default_profile, profile.map.*).
# Versions up to 0.16 kept the default profile's files (config, secrets file,
# state tree, relay dir, backups) directly in the root: migrate_legacy_layout
# moves them into profiles/default the first time the new wrapper runs.

# Active routing lines (default_profile, profile.map.*) of a config file.
ROUTING_LINE_RE='^[[:space:]]*(setting\.default_profile|profile\.map\.[^=]*)[[:space:]]*='

# Staging directory of an unfinished migration. Hidden, so profile listings
# skip it; its final rename to profiles/default marks the migration done.
LEGACY_STAGE_DIR="$PI_CONFIG_ROOT/profiles/.default.migrating"

# ============================================
# ROOT (ROUTING) CONFIG
# ============================================

# Create the root (routing) config: which profile a command uses. It holds no
# profile settings; each profile has its own config under profiles/NAME.
init_root_config() {
    (umask 077 && mkdir -p "$PI_CONFIG_ROOT") || return 1
    cat >"$ROOT_CONFIG_FILE" <<'EOF'
# Pi Dockerized profile routing (root config)
# Only routing lives here; every profile, "default" included, has its own
# config, secrets and state in profiles/<name>/. Values are taken verbatim.

# Profile used when --profile is not given (empty = "default"). Escape back to
# the default profile with `--profile default`.
# setting.default_profile=

# Per-project profile mapping: sessions started in <path> (or below) use
# <profile>; the longest matching path wins and an explicit --profile always
# takes precedence. The key after `profile.map.` is a free label.
#   profile.map.work=~/work:acme
EOF
    chmod 600 "$ROOT_CONFIG_FILE" 2>/dev/null || true
}

# default_profile is routing: it is written to the root config whatever the
# active profile, and must name a profile that exists (a dangling one would
# make every command fail).
_set_root_default_profile() {
    local value="$1"
    if [ -n "$value" ] && [ "$value" != default ] && [ ! -d "$PI_CONFIG_ROOT/profiles/$value" ]; then
        config_error "Profile '$value' does not exist (see '$0 profile list')."
        return 1
    fi
    [ -f "$ROOT_CONFIG_FILE" ] || init_root_config || return 1
    # shellcheck disable=SC2034 # read by config_upsert
    (
        CONFIG_FILE="$ROOT_CONFIG_FILE"
        CONFIG_BACKED_UP=false
        config_upsert setting.default_profile "$value"
    ) || return 1
    config_success "setting.default_profile=$value (root config)"
}

# The root config: private, and default_profile and profile.map pointing at
# profiles that exist, or every command (or every mapped session) fails. Also
# reports files the old layout left in the root.
check_root_config() {
    local ok=0 value target mode entry
    if [ -f "$ROOT_CONFIG_FILE" ]; then
        mode=$(stat -c '%a' "$ROOT_CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$ROOT_CONFIG_FILE" 2>/dev/null || true)
        if [ -n "$mode" ] && [ $((8#$mode & 8#077)) -ne 0 ]; then
            print_warning "$ROOT_CONFIG_FILE is accessible to group/others ($mode); fix restores 600"
            ok=1
        fi
    fi
    for entry in "$PI_CONFIG_ROOT"/* "$PI_CONFIG_ROOT"/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case "${entry##*/}" in profiles | config | config.bak.*) continue ;; esac
        print_warning "$entry is left over from the old layout; profile files belong in $PI_CONFIG_ROOT/profiles/<name>/"
        ok=1
    done
    value=$(root_default_profile)
    if [ -n "$value" ] && [ "$value" != default ] && [ ! -d "$PI_CONFIG_ROOT/profiles/$value" ]; then
        print_error "setting.default_profile=$value names a missing profile; fix it with '$0 --profile default config set default_profile <name>'."
        ok=1
    fi
    while IFS= read -r value; do
        target="${value##*:}"
        target="${target//[[:space:]]/}"
        if [ -n "$target" ] && [ "$target" != default ] && [ ! -d "$PI_CONFIG_ROOT/profiles/$target" ]; then
            print_error "profile.map points at missing profile '$target' ($(safe_text "${value%%=*}"))."
            ok=1
        fi
    done < <(grep -E '^[[:space:]]*profile\.map\.[^=]*=.*:' "$ROOT_CONFIG_FILE" 2>/dev/null)
    [ "$ok" -eq 0 ] && print_success "root config ok ($ROOT_CONFIG_FILE)"
    return "$ok"
}

# ============================================
# MIGRATION FROM THE OLD LAYOUT
# ============================================

# True when the root still holds a default profile in the old layout, or a
# migration was interrupted. Cheap: a few stats on every start.
legacy_layout_pending() {
    local root="$PI_CONFIG_ROOT" entry
    [ -d "$root" ] || return 1
    [ -d "$root/profiles/default" ] && return 1
    [ -d "$LEGACY_STAGE_DIR" ] && return 0
    for entry in "$root"/* "$root"/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case "${entry##*/}" in
        profiles | config | config.bak.*) continue ;;
        esac
        return 0
    done
    # A root config with profile settings (anything besides routing) is the
    # old default profile too.
    [ -f "$root/config" ] &&
        grep -E '^[[:space:]]*(setting|mount|env)\.' "$root/config" 2>/dev/null | grep -qvE "$ROUTING_LINE_RE"
}

# Comment out the routing lines of a profile's config: they only work in the
# root config, and a profile ignores them.
# Usage: comment_routing_lines <file>
comment_routing_lines() {
    local file="$1" line
    local -a out=()
    grep -qE "$ROUTING_LINE_RE" "$file" 2>/dev/null || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ $ROUTING_LINE_RE ]]; then
            out+=("# (root config only, ignored in a profile) $line")
        else
            out+=("$line")
        fi
    done <"$file"
    printf '%s\n' "${out[@]}" >"$file"
}

# Write the root config from the routing lines of the old root config (now
# the default profile's), unless an earlier interrupted run already did.
_migrate_routing_config() {
    local old_config="$1" tmp
    [ -f "$ROOT_CONFIG_FILE" ] && return 0
    tmp="$PI_CONFIG_ROOT/.config.migrating"
    (
        ROOT_CONFIG_FILE="$tmp"
        init_root_config
    ) || return 1
    grep -E "$ROUTING_LINE_RE" "$old_config" 2>/dev/null >>"$tmp"
    mv -f -- "$tmp" "$ROOT_CONFIG_FILE"
}

# Point setting.env_file at the moved secrets file when it lived in the old
# root (the value may use `~` or an absolute path, either spelling of a
# symlinked home).
# Usage: _migrate_env_file <profile_config> <new_profile_dir>
_migrate_env_file() {
    local file="$1" new_dir="$2" value resolved root rel new
    value=$(sed -n 's/^[[:space:]]*setting\.env_file[[:space:]]*=[[:space:]]*//p' "$file" | head -n 1)
    [ -n "$value" ] || return 0
    resolved=$(canonical_path "$(expand_tilde "$value")")
    for root in "$PI_CONFIG_ROOT" "$(canonical_path "$PI_CONFIG_ROOT")"; do
        path_within "$resolved" "$root" || continue
        path_within "$resolved" "$root/profiles" && return 0
        rel="${resolved#"$root"/}"
        new="$new_dir/$rel"
        # shellcheck disable=SC2088 # a display path: the tilde is meant literally
        [[ "$new" == "$HOME"/* ]] && new="~${new#"$HOME"}"
        # shellcheck disable=SC2034 # read by config_upsert
        (
            CONFIG_FILE="$file"
            CONFIG_BACKED_UP=true
            config_upsert setting.env_file "$new"
        )
        return
    done
}

# Move the old-layout default profile into profiles/default. Idempotent and
# resumable: entries go into the staging directory first, which is renamed
# into place only once everything is there. Moves stay on one filesystem, so
# running sessions keep their bind mounts. Secrets are moved, never read.
migrate_legacy_layout() {
    legacy_layout_pending || return 0
    local root="$PI_CONFIG_ROOT" target="$PI_CONFIG_ROOT/profiles/default" entry name
    print_warning "Moving the default profile from $root into $target (every profile now lives in profiles/)..."
    if ! (umask 077 && mkdir -p "$LEGACY_STAGE_DIR"); then
        print_error "Could not create $LEGACY_STAGE_DIR"
        return 1
    fi
    for entry in "$root"/* "$root"/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name="${entry##*/}"
        [ "$name" = profiles ] && continue
        if [ "$name" = .config.migrating ]; then
            rm -f -- "$entry" # half-written root config of an interrupted run
            continue
        fi
        # The new root config of an interrupted run stays where it is.
        [ "$name" = config ] && [ -e "$LEGACY_STAGE_DIR/config" ] && continue
        if [ -e "$LEGACY_STAGE_DIR/$name" ] || [ -L "$LEGACY_STAGE_DIR/$name" ]; then
            print_error "Cannot move $entry: $LEGACY_STAGE_DIR/$name already exists. Move it by hand, then re-run."
            return 1
        fi
        if ! mv -- "$entry" "$LEGACY_STAGE_DIR/"; then
            # Gone means a concurrent run moved it; anything else is fatal.
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            print_error "Could not move $entry into $LEGACY_STAGE_DIR"
            return 1
        fi
    done
    if [ -f "$LEGACY_STAGE_DIR/config" ]; then
        _migrate_routing_config "$LEGACY_STAGE_DIR/config" || return 1
        comment_routing_lines "$LEGACY_STAGE_DIR/config"
        _migrate_env_file "$LEGACY_STAGE_DIR/config" "$target"
    fi
    if [ -d "$target" ]; then
        rmdir "$LEGACY_STAGE_DIR" 2>/dev/null || true # a concurrent run finished first
    elif ! mv -- "$LEGACY_STAGE_DIR" "$target"; then
        print_error "Could not rename $LEGACY_STAGE_DIR to $target; re-run to resume."
        return 1
    fi
    # To stderr, like the warning above: command output stays pipeable.
    print_success "Default profile migrated to $target; $ROOT_CONFIG_FILE now only holds profile routing." >&2
}
