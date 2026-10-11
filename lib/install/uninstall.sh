#!/bin/bash

# uninstall.sh - undo the shell integration `install` added.
# Sourced by lib/install-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# By default only the managed lines in ~/.bashrc and ~/.zshrc are removed (after
# a .pi-dockerized.bak backup). The image and the config/state tree (which holds
# your secrets file and sessions) are only touched when asked for explicitly.

# Remove the lines the installer manages from one rc file: the PATH export, the
# three aliases, the completion `source` lines and their marker comments. Lines
# you wrote yourself are never touched.
# Returns 0 when it changed the file, 1 when there was nothing to remove, 2 on error.
# Usage: remove_managed_rc_lines <rcfile>
remove_managed_rc_lines() {
    local rc_file="$1" tmp line changed=false
    local completion_re='^\[ -f ".*/completions/(bash|zsh)\.sh" \] && source ".*/completions/(bash|zsh)\.sh"$'
    local path_re='^export PATH=.*pi-dockerized/bin'
    [ -f "$rc_file" ] || return 1
    tmp=$(mktemp "${rc_file}.tmp.XXXXXX" 2>/dev/null) || return 2

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        "# Added by pi-dockerized install" | "# Pi Dockerized aliases" | "# Pi Dockerized completion" | \
            "alias pid='pi-dockerized'" | "alias pid-run='pi-dockerized run'" | "alias pid-auth='pi-dockerized auth'")
            changed=true
            continue
            ;;
        esac
        if [[ "$line" =~ $completion_re ]] || [[ "$line" =~ $path_re ]]; then
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

# True when CONFIG_DIR is somewhere it is safe to delete recursively: inside
# $HOME, never $HOME itself, and an existing directory.
_config_dir_deletable() {
    [ -n "$CONFIG_DIR" ] && [[ "$CONFIG_DIR" == "$HOME"/* ]] && [ -d "$CONFIG_DIR" ]
}

# Usage: run_uninstall [--yes] [--image] [--purge-config]
run_uninstall() {
    local yes=false image=false purge=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --yes) yes=true ;;
        --image) image=true ;;
        --purge-config) purge=true ;;
        -h | --help)
            echo "Usage: pi-dockerized uninstall [--yes] [--image] [--purge-config]"
            echo "  (default)        remove the PATH, alias and completion lines from ~/.bashrc and ~/.zshrc"
            echo "  --image          also remove the Docker image (every tag)"
            echo "  --purge-config   also delete $CONFIG_DIR (config, secrets file, sessions)"
            return 0
            ;;
        *)
            config_error "Unknown uninstall option: $1"
            return 1
            ;;
        esac
        shift
    done

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
        if ! _config_dir_deletable; then
            config_warning "Not deleting '$CONFIG_DIR': it must be an existing directory inside your home."
        else
            local ans=y
            if [ "$yes" != true ]; then
                read -r -p "Delete $CONFIG_DIR, including your secrets file and sessions? (y/N): " ans || ans=""
            fi
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                rm -rf -- "$CONFIG_DIR"
                config_success "Deleted $CONFIG_DIR"
            else
                config_info "Kept $CONFIG_DIR"
            fi
        fi
    else
        config_info "Config and state kept in $CONFIG_DIR (use --purge-config to delete them)."
    fi

    config_info "To finish, delete the checkout: $REPO_ROOT"
}
