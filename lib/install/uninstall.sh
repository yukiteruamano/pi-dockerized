#!/bin/bash

# uninstall.sh - undo the shell integration `install` added.
# Sourced by lib/install-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# By default only the managed lines in ~/.bashrc and ~/.zshrc are removed (after
# a .pi-dockerized.bak backup). The image and the config/state tree (which holds
# your secrets file and sessions) are only touched when asked for explicitly.

# Remove the lines the installer manages from one rc file: the PATH export, the
# three aliases, the completion `source` lines and their marker comments, each
# matched exactly as the installer writes it. Lines you wrote yourself (a PATH
# export that also lists other directories, say) are never touched.
# Returns 0 when it changed the file, 1 when there was nothing to remove, 2 on error.
# Usage: remove_managed_rc_lines <rcfile>
remove_managed_rc_lines() {
    local rc_file="$1" tmp line prev="" managed changed=false
    # A completion line of any checkout, but only right below our marker (the
    # same shape could source another tool's completions).
    local completion_re='^\[ -f ".*/completions/(bash|zsh)\.sh" \] && source ".*/completions/(bash|zsh)\.sh"$'
    [ -f "$rc_file" ] || return 1
    tmp=$(mktemp "${rc_file}.tmp.XXXXXX" 2>/dev/null) || return 2

    while IFS= read -r line || [ -n "$line" ]; do
        managed=false
        case "$line" in
        "# Added by pi-dockerized install" | "# Pi Dockerized aliases" | "# Pi Dockerized completion" | \
            "$PI_BIN_PATH_LINE" | \
            "alias pid='pi-dockerized'" | "alias pid-run='pi-dockerized run'" | "alias pid-auth='pi-dockerized auth'")
            managed=true
            ;;
        esac
        if [ "$prev" = "# Pi Dockerized completion" ] && [[ "$line" =~ $completion_re ]]; then
            managed=true
        fi
        prev="$line"
        if [ "$managed" = true ]; then
            changed=true
            continue
        fi
        printf '%s\n' "$line" >>"$tmp" || {
            rm -f "$tmp"
            return 2
        }
    done <"$rc_file"

    if [ "$changed" = false ]; then
        rm -f "$tmp"
        return 1
    fi
    cp -p "$rc_file" "$rc_file.pi-dockerized.bak" 2>/dev/null || {
        rm -f "$tmp"
        return 2
    }
    cat "$tmp" >"$rc_file" || {
        rm -f "$tmp"
        return 2
    }
    rm -f "$tmp"
    return 0
}

# True when DIR is somewhere it is safe to delete recursively: an existing,
# real (not symlinked) directory inside $HOME that is a pi-dockerized config
# root or one profile in it. Never $HOME, ~/.config or another app's dir.
# Usage: _config_dir_deletable <dir>
_config_dir_deletable() {
    local dir="$1" real home_real
    [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    real=$(canonical_path "$dir")
    home_real=$(canonical_path "$HOME")
    [[ "$real" == "$home_real"/* ]] || return 1
    case "$real" in
    */pi-dockerized/profiles/*/*) return 1 ;;
    */pi-dockerized | */pi-dockerized/profiles/?*) return 0 ;;
    esac
    return 1
}

# What --purge-config deletes: the active profile's directory, or with
# --all-profiles the whole config root (every profile and the routing config).
# Usage: dir=$(_purge_target <all_profiles>)
_purge_target() {
    if [ "$1" = true ]; then printf '%s' "$PI_CONFIG_ROOT"; else printf '%s' "$CONFIG_DIR"; fi
}

# Usage: run_uninstall [--yes] [--image] [--purge-config [--all-profiles]]
run_uninstall() {
    local yes=false image=false purge=false all_profiles=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --yes) yes=true ;;
        --image) image=true ;;
        --purge-config) purge=true ;;
        --all-profiles) all_profiles=true ;;
        -h | --help)
            echo "Usage: pi-dockerized uninstall [--yes] [--image] [--purge-config [--all-profiles]]"
            echo "  (default)        remove the PATH, alias and completion lines from ~/.bashrc and ~/.zshrc"
            echo "  --image          also remove the Docker image (every tag)"
            echo "  --purge-config   also delete $CONFIG_DIR (this profile's config, secrets file, sessions)"
            echo "  --all-profiles   with --purge-config: delete $PI_CONFIG_ROOT instead (every profile)"
            return 0
            ;;
        *)
            config_error "Unknown uninstall option: $1"
            return 1
            ;;
        esac
        shift
    done
    if [ "$all_profiles" = true ] && [ "$purge" != true ]; then
        config_error "--all-profiles only works together with --purge-config"
        return 1
    fi

    local rc rc_status
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        rc_status=0
        remove_managed_rc_lines "$rc" || rc_status=$?
        case "$rc_status" in
        0) config_success "Removed pi-dockerized lines from $rc (backup: $rc.pi-dockerized.bak)" ;;
        1) config_info "Nothing to remove in $rc" ;;
        *) config_warning "Could not update $rc" ;;
        esac
    done

    if [ -L "$HOME/.local/bin/pi-dockerized" ]; then
        rm -f "$HOME/.local/bin/pi-dockerized"
        config_success "Removed legacy symlink ~/.local/bin/pi-dockerized"
    fi

    if [ "$image" = true ]; then
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            clean_image
        else
            config_warning "Docker is not running; the image was not removed."
        fi
    fi

    if [ "$purge" = true ]; then
        local target
        target=$(_purge_target "$all_profiles")
        if ! _config_dir_deletable "$target"; then
            config_warning "Not deleting '$target': it must be a pi-dockerized config directory inside your home."
        else
            local ans=y
            if [ "$yes" != true ]; then
                read -r -p "Delete $target, including its secrets files and sessions? (y/N): " ans || ans=""
            fi
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                rm -rf -- "$target"
                config_success "Deleted $target"
            else
                config_info "Kept $target"
            fi
        fi
    else
        config_info "Config and state kept in $CONFIG_DIR (use --purge-config to delete them)."
    fi

    config_info "To finish, delete the checkout: $REPO_ROOT"
}
