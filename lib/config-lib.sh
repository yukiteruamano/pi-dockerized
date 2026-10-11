#!/bin/bash

# config-lib.sh - Shared configuration module for pi-dockerized
# This file is sourced by other scripts (not executed directly)
# Provides: config parsing, docker arg building, shared volume logic, and
# interactive prompts for running Pi (the earendil-works agent CLI) in a
# sandboxed container.

# NOTE: Do not use "set -e" here — this is a library file sourced by callers.
# Let calling scripts control their own error handling.

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

# Ensure all required host-side directories exist, inside the self-contained
# PI_HOME tree. Fresh start only: existing files are never overwritten, and the
# host home XDG dirs are left untouched.
ensure_pi_dirs() {
    mkdir -p "$PI_HOME/.pi/agent" 2>/dev/null || true
    mkdir -p "$PI_HOME/.pi/agent/skills" 2>/dev/null || true
    mkdir -p "$PI_HOME/.pi/agent/sessions" 2>/dev/null || true
    mkdir -p "$PI_HOME/.npm" 2>/dev/null || true
    ensure_pi_state
}

# Seed/repair the host-side Pi state that is bind-mounted into the container.
# The read-only resources (settings.json, AGENTS.md, extensions) are baked into
# the image; only mcp.json and the runtime state below live on the host.
# Files are only created when missing — user edits are never overwritten.
ensure_pi_state() {
    local agent="$PI_HOME/.pi/agent"
    mkdir -p "$agent/skills" "$agent/sessions" "$PI_HOME/.npm" 2>/dev/null || true

    # MCP server definitions: mounted read-only into the container, edited on
    # the host (`pi-dockerized config pi edit`). Seeded empty on first run.
    if [ ! -f "$agent/mcp.json" ]; then
        printf '{\n  "mcpServers": {}\n}\n' >"$agent/mcp.json" 2>/dev/null || true
    fi

    # Runtime state Pi writes into the agent directory; bind-mounted read-write.
    # Created up front so a bind never fails on a missing source. The JSON files
    # are seeded as empty objects; an empty/zero-byte file (from an older run)
    # would break Pi's parser, so it is healed here.
    local f
    for f in auth.json mcp-auth.json trust.json; do
        if [ ! -s "$agent/$f" ]; then
            printf '{}\n' >"$agent/$f" 2>/dev/null || true
        fi
    done
    [ -f "$agent/mcp.log" ] || : >"$agent/mcp.log" 2>/dev/null || true
}

# Check whether a file parses as JSON. Tries node, then python3; without either
# the check is skipped (return 2 = unknown, never a false failure).
# Usage: json_valid <file> (0 valid, 1 invalid, 2 unknown)
json_valid() {
    if command -v node >/dev/null 2>&1; then
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
        return $?
    fi
    return 2
}

# Print the canonical install binary path (Doom-style: <install>/bin/pi-dockerized).
# Usage: repo_script_path
repo_script_path() {
    local repo_dir
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    readlink -f "$repo_dir/bin/pi-dockerized" 2>/dev/null || true
}

# Canonical install root for this checkout (lib/ -> repo root).
# Usage: install_root
install_root() {
    cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd
}

# Remove a legacy ~/.local/bin/pi-dockerized symlink left by older versions.
# A real (non-symlink) file is never touched. Returns 0 when nothing remains.
# Usage: cleanup_legacy_symlink
cleanup_legacy_symlink() {
    local link="$HOME/.local/bin/pi-dockerized"
    if [ -L "$link" ]; then
        rm -f "$link" 2>/dev/null || true
        config_success "Removed legacy symlink $link (now reached via PATH)"
    fi
    return 0
}

# Verify the global host integration: <install>/bin on PATH plus the managed
# rc lines (aliases, completions, PATH). Report-only; sync never edits rc
# files (re-run `pi-dockerized install` to repair them).
# Usage: check_global_install
check_global_install() {
    local stale=false
    local expected bin_file
    expected=$(repo_script_path)
    bin_file="$PI_BIN_DIR/pi-dockerized"
    # The running checkout counts too: dev checkouts outside the canonical
    # path are fine as long as their bin/ is on PATH.
    local this_bin=""
    this_bin="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin" && pwd)/pi-dockerized"
    if command -v pi-dockerized >/dev/null 2>&1; then
        config_success "pi-dockerized on PATH ($(command -v pi-dockerized))"
    elif [ -n "$expected" ] && [ -x "$expected" ] && [[ ":$PATH:" == *":$(dirname "$expected"):"* ]]; then
        config_success "install bin/ on PATH ($(dirname "$expected"))"
    else
        config_warning "pi-dockerized not on PATH; run 'pi-dockerized install' to add $PI_BIN_DIR (or this checkout's bin/) to PATH"
        stale=true
    fi
    if [ -e "$HOME/.local/bin/pi-dockerized" ] && [ -L "$HOME/.local/bin/pi-dockerized" ]; then
        config_warning "legacy symlink present at $HOME/.local/bin/pi-dockerized; sync removes it"
        stale=true
    fi

    local cand
    for cand in "$expected" "$this_bin" "$bin_file"; do
        if [ -n "$cand" ] && [ -e "$cand" ] && [ ! -x "$cand" ]; then
            config_warning "binary is not executable ($cand); re-run 'pi-dockerized install'"
            stale=true
        fi
    done

    local rc kind missing
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        case "$rc" in
        *.bashrc) kind=bash ;;
        *) kind=zsh ;;
        esac
        missing=""
        if ! grep -qxF -- "alias pid='pi-dockerized'" "$rc" 2>/dev/null ||
            ! grep -qxF -- "alias pid-run='pi-dockerized run'" "$rc" 2>/dev/null ||
            ! grep -qxF -- "alias pid-auth='pi-dockerized auth'" "$rc" 2>/dev/null; then
            missing="$missing aliases"
        fi
        grep -qF -- "completions/$kind.sh" "$rc" 2>/dev/null || missing="$missing completion"
        if ! grep -qF -- 'pi-dockerized/bin' "$rc" 2>/dev/null; then
            missing="$missing PATH"
        fi
        if [ -n "$missing" ]; then
            config_warning "$(basename "$rc"): stale host integration ($missing ); re-run 'pi-dockerized install' to repair"
            stale=true
        else
            config_success "$(basename "$rc") host integration (in sync)"
        fi
    done

    if [ "$stale" = true ]; then
        return 1
    fi
    return 0
}

# Compare the host-side Pi state against what the wrapper expects.
# Prints one status line per component and returns 1 when anything is stale.
# Pure reads only; never writes. Backs `config sync --check`.
# Usage: check_pi_state
check_pi_state() {
    local stale=false
    local agent="$PI_HOME/.pi/agent"

    # mcp.json must exist and parse; it is never edited by sync.
    if [ ! -f "$agent/mcp.json" ]; then
        config_warning "mcp.json missing (seeded on sync)"
        stale=true
    else
        local v=0
        json_valid "$agent/mcp.json" || v=$?
        if [ "$v" -eq 0 ]; then
            config_success "mcp.json valid (in sync)"
        elif [ "$v" -eq 1 ]; then
            config_warning "mcp.json is not valid JSON (fix it; sync never edits this file)"
            stale=true
        else
            config_info "mcp.json present (no JSON parser available to validate)"
        fi
    fi

    # The writable state Pi needs; missing entries are (re)seeded on sync.
    local name
    for name in skills sessions auth.json mcp-auth.json trust.json mcp.log; do
        if [ -e "$agent/$name" ]; then
            config_success "$name present (in sync)"
        else
            config_warning "$name missing (seeded on sync)"
            stale=true
        fi
    done

    # The secrets file is never read for values here; only its permissions.
    if [ -n "${ENV_FILE:-}" ]; then
        if [ ! -f "$ENV_FILE" ]; then
            config_warning "env file not found: $ENV_FILE"
            stale=true
        else
            local mode=""
            mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)
            if [ -n "$mode" ] && [ $((8#$mode & 8#044)) -ne 0 ]; then
                config_warning "env file is readable by group/others ($ENV_FILE); run: chmod 600"
            else
                config_success "env file permissions ok"
            fi
        fi
    fi

    # Global host integration (bin/ on PATH + rc lines); report-only here.
    if ! check_global_install; then
        stale=true
    fi

    if [ "$stale" = true ]; then
        return 1
    fi
    return 0
}

# Print a one-line hint when the host-side Pi state drifts from expectations.
# Pure reads only (see check_pi_state).
# Usage: maybe_drift_hint
maybe_drift_hint() {
    check_pi_state >/dev/null 2>&1 || echo "Host state drift detected: run 'pi-dockerized config sync' to repair."
}

# (Re)create the host-side Pi state and report the result.
# With --check it only reports drift (exit 1 when stale) and writes nothing.
# Local-only: no Docker required.
# Usage: sync_pi_state [--check]
sync_pi_state() {
    case "${1:-}" in
    "" | --check) ;;
    *)
        config_error "Usage: $0 config sync [--check]"
        return 1
        ;;
    esac
    # Host-only: inside a container CONFIG_DIR is ephemeral, so syncing there
    # creates a junk tree instead of updating the host. Tests override with
    # PI_DOCKERIZED_ALLOW_CONTAINER_SYNC=1.
    if [ -z "${PI_DOCKERIZED_ALLOW_CONTAINER_SYNC:-}" ] && { [ -f /.dockerenv ] || [ -f /run/.containerenv ]; }; then
        config_error "config sync is host-only; run it on the host, not inside a container."
        return 1
    fi
    if [ "${1:-}" = "--check" ]; then
        if check_pi_state; then
            config_success "Host state is in sync."
            return 0
        fi
        config_error "Host state is stale; run 'config sync' without --check to repair."
        return 1
    fi

    config_info "Refreshing host-side Pi state..."
    ensure_pi_dirs

    # Repair an unparsable mcp.json (user servers are only lost when the file is
    # already broken; the broken copy is kept as .bak).
    local mcp="$PI_HOME/.pi/agent/mcp.json" v=0
    if [ -f "$mcp" ]; then
        json_valid "$mcp" || v=$?
        if [ "$v" -eq 1 ]; then
            cp "$mcp" "$mcp.bak" 2>/dev/null || true
            printf '{\n  "mcpServers": {}\n}\n' >"$mcp" 2>/dev/null || true
            config_warning "Backed up broken mcp.json to mcp.json.bak and reseeded it"
        fi
    fi

    # Drop the legacy ~/.local/bin symlink (nothing is ever installed there
    # anymore; the binary is reached via <install>/bin on PATH). A real file is
    # never touched. Binaries must stay executable for PATH resolution.
    cleanup_legacy_symlink || true
    local want_bin
    want_bin=$(repo_script_path)
    if [ -n "$want_bin" ] && [ -e "$want_bin" ] && [ ! -x "$want_bin" ]; then
        if chmod +x "$want_bin" 2>/dev/null; then
            config_success "Made the pi-dockerized binary executable"
        else
            config_warning "Binary is not executable ($want_bin)"
        fi
    fi
    echo ""
    if check_pi_state; then
        config_success "Host state synced."
        return 0
    fi
    config_warning "Host state still reports stale items after refresh (see above)."
    return 1
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

# ============================================
# GnuPG / SSH AGENT FORWARDING
# ============================================

# Resolve the host's gpg-agent socket path.
# Prefers an explicit override (GPG_AGENT_SOCKET, used by tests), then gpgconf.
# Prints an empty string when neither is available.
resolve_gpg_agent_socket() {
    if [ -n "${GPG_AGENT_SOCKET:-}" ]; then
        echo "$GPG_AGENT_SOCKET"
        return 0
    fi
    if command -v gpgconf >/dev/null 2>&1; then
        gpgconf --list-dirs agent-socket 2>/dev/null || true
    fi
}

# Resolve the host's restricted gpg-agent "extra" socket path. This socket only
# allows signing/decryption, so a forwarded container cannot reconfigure the
# host agent. Prefers an explicit override (GPG_AGENT_EXTRA_SOCKET, used by
# tests), then gpgconf. Prints an empty string when neither is available.
resolve_gpg_agent_extra_socket() {
    if [ -n "${GPG_AGENT_EXTRA_SOCKET:-}" ]; then
        echo "$GPG_AGENT_EXTRA_SOCKET"
        return 0
    fi
    if command -v gpgconf >/dev/null 2>&1; then
        gpgconf --list-dirs agent-extra-socket 2>/dev/null || true
    fi
}

# Return 0 when the host gpg-agent looks reachable, 1 otherwise. Socket
# presence alone is not enough: a stale socket file would pass for "running",
# so on a real host the agent is probed with gpg-connect-agent (2s timeout).
# Test seams:
#   - GPG_AGENT_PROBE_CMD replaces the probe with an arbitrary command.
#   - GPG_AGENT_SOCKET / GPG_AGENT_EXTRA_SOCKET (plain test sockets, not real
#     agents) skip the probe and trust the socket.
# Usage: gpg_agent_is_running
gpg_agent_is_running() {
    local extra main
    extra=$(resolve_gpg_agent_extra_socket)
    main=$(resolve_gpg_agent_socket)

    if { [ -z "$extra" ] || [ ! -S "$extra" ]; } && { [ -z "$main" ] || [ ! -S "$main" ]; }; then
        return 1
    fi

    if [ -n "${GPG_AGENT_PROBE_CMD:-}" ]; then
        bash -c "$GPG_AGENT_PROBE_CMD" >/dev/null 2>&1 && return 0
        return 1
    fi

    # Test sockets are not real agents: trust the socket.
    if [ -n "${GPG_AGENT_SOCKET:-}" ] || [ -n "${GPG_AGENT_EXTRA_SOCKET:-}" ]; then
        return 0
    fi

    # Without the probe tooling, fall back to trusting the socket.
    if ! command -v gpg-connect-agent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        return 0
    fi
    if timeout 2 gpg-connect-agent --no-autostart 'getinfo version' /bye >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Prepare the host GnuPG agent before its socket is mounted. When the restricted
# extra socket is missing, launch the host agent (unless autostart is disabled)
# and wait briefly for it to appear. Never fails the run: it reports actionable
# warnings and lets build_mount_args skip the socket.
# Usage: ensure_gpg_agent_ready
ensure_gpg_agent_ready() {
    [ "$GPG_AGENT_SUPPORT" = true ] || return 0

    if ! command -v gpgconf >/dev/null 2>&1; then
        config_warning "gpgconf not found on the host; cannot prepare the GnuPG agent"
        return 0
    fi

    local extra main
    extra=$(resolve_gpg_agent_extra_socket)
    main=$(resolve_gpg_agent_socket)

    # Ready only when the socket we will actually mount is usable: the restricted
    # extra socket, or the main one when explicitly allowed. A live main socket
    # alone must not short-circuit, or a missing extra socket is never repaired.
    if [ -n "$extra" ] && [ -S "$extra" ]; then
        if gpg_agent_is_running; then
            return 0
        fi
    elif [ "$GPG_ALLOW_MAIN_SOCKET" = true ] && [ -n "$main" ] && [ -S "$main" ]; then
        if gpg_agent_is_running; then
            return 0
        fi
    fi

    if [ "$GPG_AUTOSTART_AGENT" != true ]; then
        config_warning "GnuPG agent socket not available and autostart is disabled (setting.gpg_autostart_agent=false)"
        return 0
    fi

    # A previous `-v` mount can leave an empty directory where the agent socket
    # belongs, which blocks gpg-agent from creating it. Remove empty ones (rmdir
    # refuses non-empty directories) before launching.
    local dir
    for dir in "$extra" "$main"; do
        if [ -n "$dir" ] && [ -d "$dir" ] && [ ! -S "$dir" ]; then
            if rmdir "$dir" 2>/dev/null; then
                config_warning "Removed an empty directory blocking the GnuPG agent socket: $dir"
            fi
        fi
    done

    config_info "Starting host gpg-agent for GnuPG forwarding..."
    if [ -n "${GPG_AGENT_LAUNCH_CMD:-}" ]; then
        bash -c "$GPG_AGENT_LAUNCH_CMD" >/dev/null 2>&1 || true
    else
        gpgconf --launch gpg-agent >/dev/null 2>&1 || config_warning "gpgconf --launch gpg-agent failed"
    fi

    # The socket appears asynchronously; give it up to ~2s.
    local i
    for ((i = 0; i < 20; i++)); do
        extra=$(resolve_gpg_agent_extra_socket)
        if [ -n "$extra" ] && [ -S "$extra" ]; then
            return 0
        fi
        main=$(resolve_gpg_agent_socket)
        if [ -n "$main" ] && [ -S "$main" ]; then
            return 0
        fi
        sleep 0.1
    done

    # Still missing: report the most likely cause (a non-empty directory
    # squatting on the socket path, e.g. created by an earlier Docker -v mount).
    if { [ -n "$extra" ] && [ -d "$extra" ]; } || { [ -n "$main" ] && [ -d "$main" ]; }; then
        config_warning "The GnuPG agent socket path is a non-empty directory, not a socket."
        config_info "Remove it on the host (usually under \$XDG_RUNTIME_DIR/gnupg) and re-run."
    else
        config_warning "Could not start the host gpg-agent; run 'gpgconf --launch gpg-agent' manually"
    fi
    return 0
}

# Validate the forwarded SSH agent before its socket is mounted. Deliberately
# never starts ssh-agent: a fresh agent would carry no host keys.
# Usage: ensure_ssh_agent_ready
ensure_ssh_agent_ready() {
    [ "$SSH_AGENT_SUPPORT" = true ] || return 0

    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        config_warning "SSH agent support enabled but SSH_AUTH_SOCK is not set in this environment"
        return 0
    fi

    if [ ! -S "$SSH_AUTH_SOCK" ]; then
        config_warning "SSH agent support enabled but $SSH_AUTH_SOCK is not a socket"
        if [ -d "$SSH_AUTH_SOCK" ]; then
            config_info "That path is a directory; remove it or point SSH_AUTH_SOCK at the real agent socket"
        fi
        return 0
    fi

    # The socket exists. Do not query it here (ssh-add against a non-agent
    # socket can block); the forwarded agent is used by git/ssh directly.
    return 0
}

# Mirror the host's *public* GnuPG material into $PI_HOME/.gnupg so the
# container can use the host gpg-agent (forwarded via its socket) without ever
# receiving the private keys. Only public files are copied; private-keys-v1.d,
# the agent sockets and random_seed are deliberately excluded.
# Usage: ensure_gpg_mirror
ensure_gpg_mirror() {
    local host_gpg_home="${GNUPGHOME:-$HOME/.gnupg}"
    local dest="$PI_HOME/.gnupg"

    if [ ! -d "$host_gpg_home" ]; then
        config_warning "GnuPG agent support enabled but no GnuPG home found at $host_gpg_home"
        return 0
    fi

    mkdir -p "$dest" 2>/dev/null || return 0
    chmod 700 "$dest" 2>/dev/null || true

    # Public keyring (GnuPG 2.x keybox) plus its lock/trust files. With keyboxd
    # the database can also live under public-keys.d/, so mirror that too.
    # Private keys (private-keys-v1.d) are never copied.
    local f
    for f in pubring.kbx trustdb.gpg sshcontrol; do
        if [ -f "$host_gpg_home/$f" ]; then
            install -m 600 "$host_gpg_home/$f" "$dest/$f" 2>/dev/null ||
                cp "$host_gpg_home/$f" "$dest/$f" 2>/dev/null || true
        fi
    done
    if [ -f "$host_gpg_home/public-keys.d/pubring.db" ]; then
        mkdir -p "$dest/public-keys.d" 2>/dev/null || true
        install -m 600 "$host_gpg_home/public-keys.d/pubring.db" "$dest/public-keys.d/pubring.db" 2>/dev/null ||
            cp "$host_gpg_home/public-keys.d/pubring.db" "$dest/public-keys.d/pubring.db" 2>/dev/null || true
    fi

    # Mirror the config verbatim, including `use-keyboxd`: on such hosts GnuPG
    # keeps the public keyring in the keyboxd database (public-keys.d/), so the
    # container must run keyboxd to read it. entrypoint.sh launches it at boot;
    # `no-autostart` (below) still prevents a keyless local gpg-agent. Stale
    # mirrored config is removed when the host has none.
    local conf
    for conf in gpg.conf common.conf; do
        if [ -f "$host_gpg_home/$conf" ]; then
            install -m 600 "$host_gpg_home/$conf" "$dest/$conf" 2>/dev/null ||
                cp "$host_gpg_home/$conf" "$dest/$conf" 2>/dev/null || true
        else
            rm -f "$dest/$conf" 2>/dev/null || true
        fi
    done

    # Never let the container's gpg auto-start a keyless local agent: the real
    # agent is the host's, reached through the forwarded socket.
    if [ -f "$dest/gpg.conf" ]; then
        grep -qE '^[[:space:]]*no-autostart([[:space:]]|$)' "$dest/gpg.conf" 2>/dev/null ||
            echo "no-autostart" >>"$dest/gpg.conf" 2>/dev/null || true
    else
        echo "no-autostart" >"$dest/gpg.conf" 2>/dev/null || true
    fi

    # Without a public keyring gpg cannot build a signature even when the agent
    # socket is forwarded: warn instead of failing silently later.
    if [ ! -f "$dest/pubring.kbx" ] && [ ! -f "$dest/public-keys.d/pubring.db" ]; then
        config_warning "No public GnuPG keyring found in $host_gpg_home (commit signing will not work)"
    fi

    # Clear any stale agent entry from earlier versions: the socket is
    # bind-mounted by the wrapper, never linked. A previous `-v` mount or a
    # Docker run with a missing source can leave a directory here, which would
    # block the socket mount and the real host agent.
    if [ -d "$dest/S.gpg-agent" ] && [ ! -S "$dest/S.gpg-agent" ]; then
        rmdir "$dest/S.gpg-agent" 2>/dev/null ||
            config_warning "Stray directory at $dest/S.gpg-agent; remove it on the host before mounting the agent socket"
    fi
    rm -f "$dest/S.gpg-agent" 2>/dev/null || true

    # Clear a stale keyboxd socket/lock from a previous run: the container starts
    # a fresh keyboxd, and a dead socket file would otherwise confuse gpgconf.
    rm -f "$dest/S.keyboxd" "$dest/S.keyboxd.lock" 2>/dev/null || true
}

# True when GPG_RELAY_DIR is a safe, non-root location to manage relays in.
# Usage: relay_dir_ok && ...
relay_dir_ok() {
    [ -n "$GPG_RELAY_DIR" ] || return 1
    case "$GPG_RELAY_DIR" in
        / | "") return 1 ;;
    esac
    case "$GPG_RELAY_DIR" in
        "$CONFIG_DIR"/* | "$HOME"/*) return 0 ;;
    esac
    return 1
}

# Remove relay directories whose socat process is gone (crash, kill -9, stale
# session). Runs before starting a new relay.
# Usage: cleanup_stale_relays
cleanup_stale_relays() {
    relay_dir_ok || return 0
    [ -d "$GPG_RELAY_DIR" ] || return 0
    local d pid
    for d in "$GPG_RELAY_DIR"/*; do
        [ -d "$d" ] || continue
        pid=$(cat "$d/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        rm -rf "$d" 2>/dev/null || true
    done
}

# Relay a GnuPG agent socket through a socket on a normal filesystem so Docker
# can bind it. One process per session; the wrapper stops it when the container
# exits. Uses `socat` by default; GPG_RELAY_CMD overrides the command for tests
# (it receives RELAY_SOCK and RELAY_REAL in its environment).
# Usage: relay_socket=$(start_gpg_relay <real_socket>)
start_gpg_relay() {
    local real="$1"
    [ -n "$real" ] && [ -S "$real" ] || return 1
    relay_dir_ok || return 1

    local template="${GPG_RELAY_CMD:-}"
    if [ -z "$template" ]; then
        command -v socat >/dev/null 2>&1 || return 1
        # Single quotes are intentional: expanded later via RELAY_SOCK/RELAY_REAL env.
        # shellcheck disable=SC2016
        template='socat "UNIX-LISTEN:$RELAY_SOCK,fork,max-children=8,mode=600" "UNIX-CONNECT:$RELAY_REAL"'
    fi

    mkdir -p "$GPG_RELAY_DIR" 2>/dev/null || return 1
    chmod 700 "$GPG_RELAY_DIR" 2>/dev/null || true
    # Keep the path short: Unix socket paths are limited to ~108 chars, and the
    # relay dir already nests under the wrapper config dir. The PID alone is
    # unique per live process (stale dirs are purged before each start).
    local dir sock pid i
    dir="$GPG_RELAY_DIR/$$"
    sock="$dir/relay.sock"
    if [ "${#sock}" -ge 108 ]; then
        config_warning "GPG relay path too long for a Unix socket (${#sock} chars); skipping relay"
        return 1
    fi
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true

    # `exec` makes $! the relay process itself (not a wrapping bash), so
    # stop_gpg_relay reliably kills it.
    RELAY_SOCK="$sock" RELAY_REAL="$real" bash -c "exec $template" >/dev/null 2>&1 &
    pid=$!
    echo "$pid" >"$dir/pid" 2>/dev/null || true

    for ((i = 0; i < 20; i++)); do
        if [ -S "$sock" ]; then
            echo "$sock"
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done

    kill "$pid" 2>/dev/null || true
    rm -rf "$dir" 2>/dev/null || true
    return 1
}

# Stop a relay started by start_gpg_relay and remove its directory.
# Usage: stop_gpg_relay <relay_socket>
stop_gpg_relay() {
    local sock="$1"
    [ -n "$sock" ] || return 0
    local dir
    dir=$(dirname "$sock")
    # Only ever touch directories we own under GPG_RELAY_DIR.
    case "$dir" in
        "$GPG_RELAY_DIR"/*) ;;
        *) return 0 ;;
    esac
    local pid
    pid=$(cat "$dir/pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -rf "$dir" 2>/dev/null || true
}

# ============================================
# GIT WORKTREE SUPPORT
# ============================================

# Detect if a directory is a git worktree and return the main repo's .git directory path
# A worktree has a .git FILE (not directory) containing "gitdir: <path>"
# Returns (via stdout): "<git_common_dir>" if worktree, empty string otherwise
# Usage: main_git_dir=$(detect_git_worktree "/path/to/worktree")
detect_git_worktree() {
    local project_dir="$1"

    # Quick check: if .git is a directory (normal repo) or doesn't exist, not a worktree
    if [ ! -f "$project_dir/.git" ]; then
        return 0
    fi

    # Use git to reliably resolve paths (handles relative/absolute gitdir pointers)
    if ! command -v git >/dev/null 2>&1; then
        config_warning "Git worktree detected but 'git' is not installed on the host — git info will be unavailable in container"
        return 0
    fi

    # git rev-parse --git-common-dir gives us the shared .git directory
    local git_common_dir
    git_common_dir=$(git -C "$project_dir" rev-parse --git-common-dir 2>/dev/null) || return 0

    # Resolve to absolute path
    if [[ "$git_common_dir" != /* ]]; then
        git_common_dir=$(cd "$project_dir" && cd "$git_common_dir" && pwd)
    else
        git_common_dir=$(cd "$git_common_dir" && pwd)
    fi

    # Sanity check: the common dir should be a real .git directory
    if [ ! -d "$git_common_dir/objects" ] || [ ! -d "$git_common_dir/refs" ]; then
        return 0
    fi

    echo "$git_common_dir"
}

# Build Docker volume/bind args needed for git worktree support.
# When the project is a git worktree, the .git file points to the main repo's
# .git directory which lives outside the project dir. We mount the main .git
# directory (read-only) at its real host path so the gitdir pointer resolves
# correctly inside the container.
#
# Read-only is intentional: it preserves the sandbox boundary (container only
# has write access to the mounted project directory). Read operations like
# git log, status, diff, and branch work. Write operations (commit, stash,
# fetch) will fail — run those on the host.
#
# Populates GIT_WORKTREE_ARGS array
# Usage: build_git_worktree_args "/path/to/project"
build_git_worktree_args() {
    local project_dir="$1"

    GIT_WORKTREE_ARGS=()

    local git_common_dir
    git_common_dir=$(detect_git_worktree "$project_dir")

    if [ -z "$git_common_dir" ]; then
        return 0
    fi

    config_info "Git worktree detected — mounting main .git directory (read-only) for git support"
    config_info "Main git directory: $git_common_dir"

    # Mount the main repo's .git directory at its real host path (read-only)
    GIT_WORKTREE_ARGS+=(-v "$git_common_dir:$git_common_dir:ro")
}

# ============================================
# DOCKER ARG BUILDING
# ============================================

# Reject inline secrets in the host mcp.json: credentials must use ${VAR}
# references so secrets never rest in a file the container can read. Heuristic
# on key names; only offending key names are reported, never values.
# Called on every run; exits non-zero with remediation.
# Usage: validate_pi_config || exit 1
validate_pi_config() {
    local mcp="$PI_HOME/.pi/agent/mcp.json"
    [ -f "$mcp" ] || return 0

    local hits m keys=""
    hits=$(grep -oE '"(apiKey|api_key|api-key|accessToken|access_token|clientSecret|token|secret|password|passwd|authorization|bearer)"[[:space:]]*:[[:space:]]*"[^"]*"' "$mcp" 2>/dev/null || true)
    [ -n "$hits" ] || return 0
    while IFS= read -r m; do
        case "$m" in
        *'${'*) continue ;;
        esac
        keys="$keys $(printf '%s' "$m" | grep -oE '^"[A-Za-z_.-]+"' || true)"
    done <<<"$hits"
    case "$keys" in
    "" | " ") ;;
    *)
        config_error "Inline secrets in $mcp ($keys ): use \${VAR} references instead."
        config_info "Put the values in setting.env_file and reference them as \${VAR} in mcp.json."
        return 1
        ;;
    esac
    return 0
}

# Build common Docker run arguments shared by run_pi and run_auth.
# Populates DOCKER_COMMON_ARGS array.
# The container runs as the host user directly (no root): --user starts the
# process with the host UID/GID, so entrypoint.sh needs no privilege dropping or
# UID/GID remapping. --group-add coder keeps the group-writable (g+rwX) home
# tree accessible to any host UID; the name resolves against the container's
# /etc/group (gid 1000 here), so the host does not need a "coder" group.
# no-new-privileges neutralizes setuid binaries and cap-drop removes Linux
# capabilities the non-root process never needs.
# Usage: build_common_docker_args
build_common_docker_args() {
    # shellcheck disable=SC2034  # DOCKER_COMMON_ARGS is used by callers that source this file
    # Block runs whose mcp.json carries inline secrets (must use ${VAR}).
    validate_pi_config || exit 1
    # Allowlist the network mode (config values are user-edited).
    case "${NETWORK:-host}" in
    host | bridge) ;;
    *)
        config_warning "Invalid network '$NETWORK' (use host|bridge); falling back to host"
        NETWORK="host"
        ;;
    esac
    DOCKER_COMMON_ARGS=(
        --rm
        --network "$NETWORK"
        --user "$(id -u):$(id -g)"
        --group-add coder
        --security-opt no-new-privileges:true
        --cap-drop=ALL
        -e "TERM=${TERM:-xterm-256color}"
    )

    # Optional resource limits (setting.memory / setting.cpus).
    [ -n "$MEMORY" ] && DOCKER_COMMON_ARGS+=(--memory "$MEMORY")
    [ -n "$CPUS" ] && DOCKER_COMMON_ARGS+=(--cpus "$CPUS")

    # Pass terminal identification variables so applications inside the container
    # can detect the host terminal and use its capabilities correctly.
    local term_var
    for term_var in TERM_PROGRAM TERM_PROGRAM_VERSION KITTY_WINDOW_ID COLORTERM; do
        if [ -n "${!term_var}" ]; then
            DOCKER_COMMON_ARGS+=(-e "$term_var=${!term_var}")
        fi
    done

    # Pi reads everything from its agent directory; the agent tree itself lives
    # in the image (baked read-only at build time). Only the writable state is
    # bind-mounted (see build_standard_volume_args).
    DOCKER_COMMON_ARGS+=(-e "PI_CODING_AGENT_DIR=$PI_AGENT_CONTAINER_DIR")

    # Keep Pi from checking for and applying self-updates inside the container.
    DOCKER_COMMON_ARGS+=(-e "PI_SKIP_VERSION_CHECK=1")

    # Install/update telemetry off by default (override with PI_TELEMETRY=1).
    DOCKER_COMMON_ARGS+=(-e "PI_TELEMETRY=${PI_TELEMETRY:-0}")

    # Security policy mode consumed by the baked security-guard extension
    # (strict | balanced | off). Defaults to balanced when unset.
    DOCKER_COMMON_ARGS+=(-e "PI_DOCKERIZED_POLICY=$SECURITY_POLICY")
}

# Build standard volume mount arguments for Pi directories.
# Populates VOLUME_ARGS and CONTAINER_WORKDIR.
# The project is mounted at a path derived from the host path (with $HOME
# stripped) so that Pi stores a unique, meaningful directory per project.
# The read-only resources (settings, extensions, AGENTS.md, prompts, themes,
# models) are baked into the image and are NOT mounted. Only mcp.json (RO, host
# edited), the writable skills dir, the session store and the runtime files Pi
# persists are bind-mounted.
build_standard_volume_args() {
    local project_dir="$1"
    local include_docker_socket="${2:-false}"

    VOLUME_ARGS=()

    # Compute container-side mount path: strip $HOME prefix for portability
    # e.g. /home/user/projects/acme/frontend -> /projects/acme/frontend
    CONTAINER_WORKDIR=$(compute_container_path "$project_dir")

    # Project directory (read-write) — mounted at the computed path.
    # Skipped when no project is given (e.g. auth) or when it resolves to $HOME.
    if [ -n "$project_dir" ] && [ -n "$CONTAINER_WORKDIR" ]; then
        VOLUME_ARGS+=(-v "$project_dir:$CONTAINER_WORKDIR")
        build_git_worktree_args "$project_dir"
    fi

    local agent="$PI_HOME/.pi/agent"

    # MCP server definitions: host-managed, mounted read-only. Edited on the
    # host with 'pi-dockerized config pi edit'; the container can never modify
    # the server list.
    if [ -f "$agent/mcp.json" ]; then
        VOLUME_ARGS+=(-v "$agent/mcp.json:$PI_AGENT_CONTAINER_DIR/mcp.json:ro")
    else
        config_warning "mcp.json not found at $agent/mcp.json (run 'pi-dockerized install')"
    fi

    # Skills are the one resource the user keeps writable in the container.
    if [ -d "$agent/skills" ]; then
        VOLUME_ARGS+=(-v "$agent/skills:$PI_AGENT_CONTAINER_DIR/skills:rw")
    fi

    # Session store (Pi persists conversations here; sessionDir is fixed to this
    # path by the baked settings.json).
    if [ -d "$agent/sessions" ]; then
        VOLUME_ARGS+=(-v "$agent/sessions:$PI_AGENT_CONTAINER_DIR/sessions:rw")
    fi

    # Runtime state Pi writes into the agent directory.
    local state_file
    for state_file in auth.json mcp-auth.json trust.json mcp.log; do
        if [ -f "$agent/$state_file" ]; then
            VOLUME_ARGS+=(-v "$agent/$state_file:$PI_AGENT_CONTAINER_DIR/$state_file:rw")
        fi
    done

    # npm cache (read-write): persisted so npx-based MCP servers do not re-download.
    if [ -d "$PI_HOME/.npm" ]; then
        VOLUME_ARGS+=(-v "$PI_HOME/.npm:/home/coder/.npm:rw")
    fi

    # Claude Code compatibility directory (optional): fallback CLAUDE.md rules
    # and ~/.claude/skills.
    if [ -d "$HOME/.claude" ]; then
        VOLUME_ARGS+=(-v "$HOME/.claude:/home/coder/.claude:ro")
    fi

    # Agent-compatible skills directory (optional).
    # Pi also reads skills from ~/.agents/skills/<name>/SKILL.md.
    if [ -d "$HOME/.agents" ]; then
        VOLUME_ARGS+=(-v "$HOME/.agents:/home/coder/.agents:ro")
    fi

    # Docker socket (optional, for Docker-in-Docker operations). The container
    # runs as a non-root numeric UID, so access is granted with a supplementary
    # --group-add (the socket's GID) instead of a runtime `usermod` that required
    # root. It is appended to VOLUME_ARGS because it is part of what this
    # function contributes to the `docker run` command.
    # WARNING: root-equivalent on the host — enable only for Docker-in-Docker /
    # Testcontainers (setting.docker_socket=true).
    if [ "$include_docker_socket" = true ] && [ -S /var/run/docker.sock ]; then
        config_warning "Docker socket mounted: root-equivalent on the host (disable with setting.docker_socket=false when not needed)"
        VOLUME_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
        VOLUME_ARGS+=(--group-add "$(stat -c '%g' /var/run/docker.sock)")
    fi
}

# ============================================
# CONFIG FILE OPERATIONS
# ============================================

# Check if config file exists
config_exists() {
    [ -f "$CONFIG_FILE" ]
}

# Initialize config file with header
init_config_file() {
    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<'EOF'
# Pi Dockerized User Configuration
# Generated by 'pi-dockerized install' - edit manually or re-run 'pi-dockerized install' to modify

# Settings
# SSH Agent Forwarding (enables git over SSH in container)
# Automatically mounts SSH_AUTH_SOCK socket and passes the environment variable
# setting.ssh_agent_support=false

# GnuPG Agent Forwarding (enables git commit signing with your host keys)
# Shares only the public keyring and the gpg-agent socket; private keys never
# enter the container. Requires a running gpg-agent on the host.
# setting.gpg_agent_support=false

# Allow falling back to the full-control gpg-agent socket when the restricted
# S.gpg-agent.extra socket is unavailable. NOT recommended: the main socket can
# reconfigure the host agent. Default: false (warn and skip instead).
# setting.gpg_allow_main_socket=false

# Launch the host gpg-agent automatically at run time when its socket is
# missing. Default: true. Set to false to only warn and never start it.
# setting.gpg_autostart_agent=true

# Relay the agent socket through a socket on a normal filesystem. Needed when
# socketdir is on tmpfs (/run/user/<uid>/gnupg), which Docker cannot bind.
# Requires `socat` on the host. Default: true.
# setting.gpg_relay=true

# Docker socket (opt-in). Mounting it grants the container full control of the
# host Docker daemon, which is effectively root on the host. Enable only when
# you need Docker-in-Docker / Testcontainers.
# setting.docker_socket=false

# Container network: host (default, simple; shares the host network namespace)
# or bridge (more isolated; host services are reached via host.docker.internal).
# setting.network=host

# Security policy mode enforced by the baked security-guard extension.
# strict = every vendored pattern; balanced = drop the noisy false positives
# (default); off = vendored patterns disabled (built-in backstops stay).
# setting.security_policy=balanced

# Optional container resource limits (docker --memory / --cpus). Empty = no limit.
# setting.memory=4g
# setting.cpus=2

# Secrets file (dotenv KEY=VALUE lines) loaded with docker --env-file.
# Must live under ~/.config/pi-dockerized/ (never mounted). Create it with
# `install -m 600 /dev/null ~/.config/pi-dockerized/env` and add provider keys
# like ANTHROPIC_API_KEY=... Empty = disabled.
# setting.env_file=~/.config/pi-dockerized/env

# TUI theme (built-in, e.g. system). Empty = Pi default.
# setting.theme=system

# Startup model selection (passed as `pi --model`). Empty = Pi default.
# setting.model=sonnet

# Custom volume mounts (read-only by default)
# Format: mount.<name>=<host_path>:<container_path>[:rw]
# Examples:
#   mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
#   mount.gitignore_global=~/.config/git/gitignore_global:/home/coder/.config/git/gitignore_global
# NOTE: do NOT mount ~/.ssh (it exposes private keys and is refused). Use
# setting.ssh_agent_support=true: the agent socket plus ~/.ssh/config and
# known_hosts are mounted read-only automatically.

# Secrets live in setting.env_file (dotenv KEY=VALUE, never mounted).
# Use `pi-dockerized install` to add keys without ever printing them.
EOF
    config_success "Created config file at $CONFIG_FILE"
}

# Load config file into arrays, preserving each entry's original key suffix so
# save_config can re-emit it unchanged (re-running setup never renames keys).
load_config() {
    if ! config_exists; then
        config_warning "Config file not found at $CONFIG_FILE"
        return 1
    fi

    CUSTOM_MOUNTS=()
    CUSTOM_MOUNT_KEYS=()

    # Read mounts (lines starting with "mount.")
    while IFS='=' read -r key value; do
        # Skip comments and non-mount lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ "$key" =~ ^[[:space:]]*mount\. ]] || continue
        # Trim whitespace around the key, then keep the suffix after "mount."
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#mount.}"
        # Remove leading/trailing whitespace from the value
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [ -n "$value" ] && [ -n "$key" ]; then
            CUSTOM_MOUNT_KEYS+=("$key")
            CUSTOM_MOUNTS+=("$value")
        fi
    done <"$CONFIG_FILE"

    # Legacy env vars (lines starting with "env."): the host-environment
    # passthrough was removed; secrets now live in setting.env_file. Entries
    # are ignored with a warning telling how to migrate (see
    # migrate_legacy_env_vars for the interactive one-shot migration).
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ "$key" =~ ^[[:space:]]*env\. ]] || continue
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#env.}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [ -n "$value" ] && [ -n "$key" ]; then
            config_warning "Ignoring legacy '$key' (env.* passthrough was removed); move the value to setting.env_file instead."
        fi
    done <"$CONFIG_FILE"

    # Read settings (lines starting with "setting.")
    SSH_AGENT_SUPPORT=false
    GPG_AGENT_SUPPORT=false
    GPG_ALLOW_MAIN_SOCKET=false
    GPG_AUTOSTART_AGENT=true
    GPG_RELAY=true
    DOCKER_SOCKET=false
    NETWORK="host"
    SECURITY_POLICY="balanced"
    MEMORY=""
    CPUS=""
    ENV_FILE=""
    THEME=""
    MODEL=""
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ "$key" =~ ^[[:space:]]*setting\. ]] || continue
        # Trim whitespace and keep the suffix after "setting."
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#setting.}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
        ssh_agent_support) [[ "$value" == "true" ]] && SSH_AGENT_SUPPORT=true ;;
        gpg_agent_support) [[ "$value" == "true" ]] && GPG_AGENT_SUPPORT=true ;;
        gpg_allow_main_socket) [[ "$value" == "true" ]] && GPG_ALLOW_MAIN_SOCKET=true ;;
        gpg_autostart_agent) [[ "$value" == "false" ]] && GPG_AUTOSTART_AGENT=false ;;
        gpg_relay) [[ "$value" == "false" ]] && GPG_RELAY=false ;;
        docker_socket) [[ "$value" == "true" ]] && DOCKER_SOCKET=true ;;
        network)
            case "$value" in
            "" | host | bridge) NETWORK="${value:-host}" ;;
            *) config_warning "Invalid network '$value' (use host|bridge); keeping host" ;;
            esac
            ;;
        env_file) ENV_FILE="$value" ;;
        theme)
            case "$value" in
            "") ;;
            *[!A-Za-z0-9_-]*) config_warning "Invalid theme '$value' (use letters, numbers, - or _); ignoring" ;;
            *) THEME="$value" ;;
            esac
            ;;
        model)
            case "$value" in
            "") ;;
            *[!A-Za-z0-9._:/@-]*) config_warning "Invalid model '$value' (unexpected characters); ignoring" ;;
            *) MODEL="$value" ;;
            esac
            ;;
        memory)
            if [ -z "$value" ]; then
                MEMORY=""
            elif [[ "$value" =~ ^[0-9]+[bBkKmMgG]$ ]]; then
                MEMORY="$value"
            else
                config_warning "Invalid memory '$value' (e.g. 4g); ignoring"
            fi
            ;;
        cpus)
            if [ -z "$value" ]; then
                CPUS=""
            elif [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                CPUS="$value"
            else
                config_warning "Invalid cpus '$value' (e.g. 2); ignoring"
            fi
            ;;
        security_policy)
            case "$value" in
            strict | balanced | off) SECURITY_POLICY="$value" ;;
            *) config_warning "Invalid security_policy '$value' (use strict|balanced|off); keeping balanced" ;;
            esac
            ;;
        esac
    done <"$CONFIG_FILE"

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

# Save current arrays to config file, preserving original key names and
# skipping exact duplicate lines (idempotent across re-runs).
save_config() {
    mkdir -p "$CONFIG_DIR"

    {
        echo "# Pi Dockerized User Configuration"
        echo "# Generated by 'pi-dockerized install' - edit manually or re-run 'pi-dockerized install' to modify"
        echo ""
        echo "# Settings"
        echo "# SSH Agent Forwarding (enables git over SSH in container)"
        echo "# Automatically mounts SSH_AUTH_SOCK socket and passes the environment variable"
        echo "setting.ssh_agent_support=$SSH_AGENT_SUPPORT"
        echo "# GnuPG agent forwarding (public keyring + gpg-agent socket; enables git commit -S)"
        echo "setting.gpg_agent_support=$GPG_AGENT_SUPPORT"
        echo "# Allow GPG fallback to the full-control agent socket when the restricted"
        echo "# S.gpg-agent.extra is unavailable (NOT recommended)"
        echo "setting.gpg_allow_main_socket=$GPG_ALLOW_MAIN_SOCKET"
        echo "# Launch the host gpg-agent automatically when its socket is missing"
        echo "setting.gpg_autostart_agent=$GPG_AUTOSTART_AGENT"
        echo "# Relay the agent socket through a normal-filesystem socket (needed when"
        echo "# socketdir is on tmpfs, e.g. /run/user/<uid>/gnupg); requires socat"
        echo "setting.gpg_relay=$GPG_RELAY"
        echo "# Docker socket (opt-in; grants host Docker control — root-equivalent)"
        echo "setting.docker_socket=$DOCKER_SOCKET"
        echo "# Container network: host (default) | bridge (more isolated)"
        echo "setting.network=$NETWORK"
        echo "# Security policy mode: strict | balanced | off"
        echo "setting.security_policy=$SECURITY_POLICY"
        echo "# Optional container resource limits (empty = no limit)"
        echo "setting.memory=$MEMORY"
        echo "setting.cpus=$CPUS"
        echo "# Secrets file (dotenv KEY=VALUE lines) loaded with docker --env-file."
        echo "# Must live under $CONFIG_DIR (never mounted). Empty = disabled."
        echo "setting.env_file=$ENV_FILE"
        echo "# TUI theme (built-in, e.g. system). Empty = Pi default."
        echo "setting.theme=$THEME"
        echo "# Startup model selection (passed as 'pi --model'). Empty = Pi default."
        echo "setting.model=$MODEL"
        echo ""
        echo "# Custom volume mounts (read-only by default)"
        echo "# Format: mount.<name>=<host_path>:<container_path>[:rw]"
        echo "# NOTE: paths containing ':' are not supported (used as separator)"

        if [ ${#CUSTOM_MOUNTS[@]} -gt 0 ]; then
            local seen_m=""
            for i in "${!CUSTOM_MOUNTS[@]}"; do
                local line="mount.${CUSTOM_MOUNT_KEYS[$i]}=${CUSTOM_MOUNTS[$i]}"
                [[ "$seen_m" == *"|$line|"* ]] && continue
                seen_m="$seen_m|$line|"
                echo "$line"
            done
        fi
    } >"$CONFIG_FILE"

    config_success "Saved configuration to $CONFIG_FILE"
}

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
