#!/bin/bash

# core.sh - constants, colors, logging, config globals and generic helpers.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# ============================================
# CONSTANTS
# ============================================

CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/pi-dockerized}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config}"

# Self-contained Pi state tree. The wrapper owns all of Pi's runtime state under
# this single host directory instead of spreading it across the host home, so
# the setup is portable and replaces native host usage. It mirrors the container
# home layout and is mounted piece by piece (see build_standard_volume_args):
# read-only for the baked/inert resources (mcp.json) and read-write for the
# state Pi must persist (skills, sessions, auth, MCP OAuth, trust, logs).
PI_HOME="${PI_HOME:-$CONFIG_DIR/home}"

# Container-side agent directory (Pi's PI_CODING_AGENT_DIR). Extensions,
# settings, AGENTS.md, prompts and themes are baked read-only into the image at
# build time; only the paths listed below are bind-mounted from the host.
PI_AGENT_CONTAINER_DIR="/home/coder/.pi/agent"

# Directory holding active GPG relay sockets (one subdir per session). The relay
# lives on a normal filesystem so Docker can bind it (it cannot bind sockets
# under the per-user /run/user tmpfs).
GPG_RELAY_DIR="${GPG_RELAY_DIR:-$CONFIG_DIR/gnupg-relay}"

# Self-contained install location (Doom-style). The git checkout lives here;
# the binary is always <install>/bin/pi-dockerized, reached via PATH.
# Nothing is ever installed into ~/.local/bin (no symlink, no stub, no copy).
PI_INSTALL_DIR="${PI_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-dockerized}"
PI_BIN_DIR="$PI_INSTALL_DIR/bin"
# Printed verbatim by `pi-dockerized install` for shells without an rc file on
# disk; $HOME/$PATH must stay unexpanded here.
# shellcheck disable=SC2034,SC2016 # consumed by lib/install-lib.sh; single quotes are intentional
PI_BIN_PATH_LINE='export PATH="$HOME/.local/share/pi-dockerized/bin:$PATH"'

# ============================================
# COLOR DEFINITIONS (with defaults if not set)
# ============================================

: "${RED:='\033[0;31m'}"
: "${GREEN:='\033[0;32m'}"
: "${YELLOW:='\033[1;33m'}"
: "${BLUE:='\033[0;34m'}"
: "${NC:='\033[0m'}"

# Honor NO_COLOR (https://no-color.org) and dumb terminals: strip ANSI codes.
# Applied here so every script sourcing this library (wrapper, setup,
# run-simple, tests) respects it without further changes.
if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# ============================================
# LOGGING FUNCTIONS (use caller's style if available)
# ============================================

config_info() {
    if type print_info >/dev/null 2>&1; then
        print_info "$1"
    else
        echo -e "${BLUE}ℹ${NC} $1"
    fi
}

config_success() {
    if type print_success >/dev/null 2>&1; then
        print_success "$1"
    else
        echo -e "${GREEN}✓${NC} $1"
    fi
}

config_warning() {
    if type print_warning >/dev/null 2>&1; then
        print_warning "$1"
    else
        echo -e "${YELLOW}⚠${NC} $1"
    fi
}

config_error() {
    if type print_error >/dev/null 2>&1; then
        print_error "$1"
    else
        echo -e "${RED}✗${NC} $1"
    fi
}

# Resolve an editor: $EDITOR first, then common fallbacks.
# Prints the editor command name, or nothing when none is available.
# Usage: editor=$(resolve_editor)
resolve_editor() {
    if [ -n "${EDITOR:-}" ]; then
        echo "$EDITOR"
        return 0
    fi
    local candidate
    for candidate in sensible-editor vi nano; do
        if command -v "$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# ============================================
# CONFIG STATE (global arrays, populated by parse_config)
# ============================================

declare -a CUSTOM_MOUNTS=()     # Array of "host_path:container_path[:rw]" values
declare -a CUSTOM_MOUNT_KEYS=() # Parallel array of config key suffixes (after "mount.")
declare -a DOCKER_MOUNT_ARGS=() # Array of docker -v arguments (populated by build_mount_args)
declare -a DOCKER_ENV_ARGS=()   # Array of docker -e arguments (populated by build_env_args)
# shellcheck disable=SC2034 # populated here, consumed by callers (bin/pi-dockerized, tests)
declare -a DOCKER_ENV_FILE_ARGS=() # Array of docker --env-file arguments (populated by build_env_file_args)
declare -a VOLUME_ARGS=()       # Array of standard volume mount arguments (populated by build_standard_volume_args)
declare -a GIT_WORKTREE_ARGS=() # Array of docker args for git worktree support (populated by build_git_worktree_args)
SSH_AGENT_SUPPORT=false         # Boolean flag for SSH agent forwarding support
GPG_AGENT_SUPPORT=false         # Boolean flag for GnuPG agent forwarding (git signing)
GPG_ALLOW_MAIN_SOCKET=false     # Allow fallback to the full-control agent socket
GPG_AUTOSTART_AGENT=true        # Launch the host gpg-agent when its socket is missing
GPG_RELAY=true                  # Relay the agent socket through a normal-fs socket
GPG_RELAY_SOCKET=""             # Active relay socket for the current session
DOCKER_SOCKET=false             # Boolean flag: mount the host Docker socket (opt-in, root-equivalent)
NETWORK="host"                  # Container network: host (default, simple) | bridge (more isolated)
SECURITY_POLICY="balanced"      # Security policy mode: strict | balanced | off
MEMORY=""                       # Optional container memory limit (docker --memory), e.g. 4g
CPUS=""                         # Optional container CPU limit (docker --cpus), e.g. 2
ENV_FILE=""                     # Optional dotenv file with secrets (docker --env-file), must live under CONFIG_DIR
THEME=""                        # Optional Pi theme name (built-in, e.g. system); empty = Pi default
MODEL=""                        # Optional Pi model selection (--model), empty = Pi default
GPG_SOCKET=""                   # Resolved host agent socket (set by build_mount_args)

# ============================================
# SHARED HELPERS
# ============================================

# Compute the container mount path for a project directory.
# Strips $HOME prefix so the path is portable across machines/users.
# Example: /home/user/projects/acme/frontend -> /projects/acme/frontend
#          /opt/work/myproject                -> /opt/work/myproject (unchanged)
# Usage: container_path=$(compute_container_path "/home/user/projects/myapp")
compute_container_path() {
    local host_path="$1"

    if [[ "$host_path" == "$HOME"/* ]]; then
        echo "${host_path#"$HOME"}"
    else
        echo "$host_path"
    fi
}

# Reject project directories that would expose the host home or the whole
# filesystem to the sandbox: "/", $HOME, and any ancestor of $HOME (e.g. /home)
# are refused. Only a project subdirectory is allowed.
# Usage: validate_project_dir "/abs/path" || exit 1
validate_project_dir() {
    local project_dir="$1"

    if [ -z "$project_dir" ]; then
        config_error "A project directory is required."
        return 1
    fi

    if [ "$project_dir" = "/" ]; then
        config_error "Refusing to run with '/' as the project."
        config_info "Pass a project subdirectory instead (e.g. ~/projects/my-app)."
        return 1
    fi

    if [ "$project_dir" = "$HOME" ]; then
        config_error "Refusing to run with the home directory ($HOME) as the project."
        config_info "Pass a project subdirectory instead."
        return 1
    fi

    # Any ancestor of $HOME (e.g. /home) would expose the home through the mount.
    case "$HOME" in
    "$project_dir"/*)
        config_error "Refusing to run with '$project_dir' as the project: it contains your home directory."
        config_info "Pass a project subdirectory instead (e.g. ~/projects/my-app)."
        return 1
        ;;
    esac

    return 0
}

# Check if Docker image exists locally
# Usage: check_image "$IMAGE_NAME"
check_image() {
    local image_name="$1"
    if ! docker image inspect "$image_name" >/dev/null 2>&1; then
        config_error "Docker image '$image_name' not found. Run '$0 build' first."
        return 1
    fi
}

# Sanitize a string for use as part of a Docker container name
# Docker container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]
# Usage: sanitize_container_name "my project dir"
sanitize_container_name() {
    local name="$1"
    name=$(echo "$name" | tr -cd '[:alnum:]._-')
    # Ensure it starts with alphanumeric
    while [[ "$name" =~ ^[^[:alnum:]] ]]; do name="${name#?}"; done
    [ -z "$name" ] && name="project"
    echo "$name"
}

# Generate a random hex suffix for container names
generate_random_suffix() {
    # 8 hex chars of OS entropy (avoids the collision-prone $RANDOM)
    head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
}
