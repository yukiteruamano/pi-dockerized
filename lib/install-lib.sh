#!/bin/bash

# install-lib.sh - First-time install / repair wizard (and uninstall) for
# pi-dockerized. Sourced by bin/pi-dockerized (the `install` and `uninstall`
# commands) and never executed directly. bin/ contains only the
# `pi-dockerized` binary; there is no second `install` binary.
#
# The implementation lives in lib/install/*.sh, one responsibility per module;
# this file loads them and holds the wizard entry point.
#
# NOTE: Do not use "set -e" here — this is a library file sourced by callers.

_INSTALL_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/install"
for _install_module in rc sections uninstall; do
    # shellcheck source=/dev/null
    source "$_INSTALL_LIB_DIR/$_install_module.sh"
done
unset _install_module

_install_usage() {
    echo "Usage: pi-dockerized install [--yes] [--only config,completions,aliases,global[,path][,build]] [-h|--help]"
    echo "  'global' and 'path' are aliases: both ensure <install>/bin is on PATH."
}

# Ensure the checkout tracks its upstream branch so `update`/`upgrade`
# work. `git clone` normally sets this, but manual checkouts
# (init + remote add + checkout) don't. Idempotent, never fails.
# Usage: ensure_git_upstream <repo_dir>
ensure_git_upstream() {
    local dir="$1" branch
    [ -d "$dir/.git" ] || return 0
    command -v git >/dev/null 2>&1 || return 0
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] || return 0
    if git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        return 0
    fi
    if git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
        if git -C "$dir" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1; then
            echo "Tracking upstream: $branch -> origin/$branch (self-update enabled)"
            return 0
        fi
    fi
    echo "Could not set upstream tracking for '$branch' (no origin/$branch found); set it manually with 'git branch --set-upstream-to=origin/<branch>'"
    return 0
}

# Parse the --yes/--only flags into SETUP_YES and SETUP_ONLY and reject unknown
# sections. Returns 0 to continue, 1 on bad usage, 2 after printing --help.
_install_parse_args() {
    SETUP_YES=false
    SETUP_ONLY="config,completions,aliases,global"
    while [ $# -gt 0 ]; do
        case "$1" in
        --yes) SETUP_YES=true ;;
        --only)
            [ -n "${2:-}" ] || {
                echo "Missing value for --only" >&2
                _install_usage
                return 1
            }
            SETUP_ONLY="$2"
            shift
            ;;
        --only=*) SETUP_ONLY="${1#--only=}" ;;
        -h | --help)
            _install_usage
            return 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            _install_usage
            return 1
            ;;
        esac
        shift
    done

    local _normalized=",$SETUP_ONLY,"
    _normalized="${_normalized//,path/,global}"
    SETUP_ONLY="${_normalized#,}"
    SETUP_ONLY="${SETUP_ONLY%,}"
    local _residue=",$SETUP_ONLY,"
    _residue="${_residue//,config/}"
    _residue="${_residue//,completions/}"
    _residue="${_residue//,aliases/}"
    _residue="${_residue//,global/}"
    _residue="${_residue//,build/}"
    if [ "$_residue" != "," ]; then
        echo "Unknown section in --only: $SETUP_ONLY (use config,completions,aliases,global[,path][,build])" >&2
        _install_usage
        return 1
    fi
    return 0
}

# First-time install / repair wizard. Idempotent.
# Non-interactive (piped stdin, no TTY) defaults to --yes so a single
# `curl .../install.sh | bash` performs the full setup (config, PATH,
# completions, aliases) without requiring a second manual run.
# Usage: run_install_main [--yes] [--only ...]
run_install_main() {
    local parse_rc=0
    _install_parse_args "$@" || parse_rc=$?
    [ "$parse_rc" -eq 2 ] && return 0
    [ "$parse_rc" -eq 0 ] || return 1

    # Piped/curl installs have no TTY for prompts: apply recommended defaults
    # instead of stopping after the core directories.
    if [ ! -t 0 ] && [ "$SETUP_YES" != true ]; then
        SETUP_YES=true
        config_info "Non-interactive install detected: applying recommended defaults (--yes)."
    fi

    local REPO_ROOT
    REPO_ROOT="$(install_root 2>/dev/null || true)"
    [ -n "$REPO_ROOT" ] || {
        config_error "Could not locate the checkout root."
        return 1
    }
    ensure_git_upstream "$REPO_ROOT" || true
    if [ "$(readlink -f "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")" != "$(readlink -f "$PI_INSTALL_DIR" 2>/dev/null || echo "$PI_INSTALL_DIR")" ] && [ -d "$PI_INSTALL_DIR/.git" ]; then
        ensure_git_upstream "$PI_INSTALL_DIR" || true
    fi

    export TMPDIR="${TMPDIR:-/tmp/pi}"
    mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"

    echo "Pi Docker Install"
    echo "================================"
    echo ""
    echo "Checking Pi configuration..."
    echo ""

    ensure_pi_dirs

    install_section_config || true
    install_section_completions "$REPO_ROOT" || true
    install_section_aliases || true
    install_section_global "$REPO_ROOT" || true
    install_section_build "$REPO_ROOT" || true

    echo ""
    echo "Install complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Build the Docker image (or fetch the prebuilt one with 'pi-dockerized pull'):"
    echo "     pi-dockerized build"
    echo ""
    echo "  2. Check provider credentials (keys in setting.env_file):"
    echo "     pi-dockerized auth"
    echo ""
    echo "  3. Run Pi in your project:"
    echo "     pi-dockerized run /path/to/your/project"
    echo ""
    return 0
}
