#!/bin/bash

# docker-args.sh - git worktree support and docker run argument building.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

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

# Build the `pi` invocation args from wrapper settings (theme/model).
# Usage: build_pi_args <array_name>; appends to the named array.
build_pi_args() {
    local -n _out="$1"
    # `if` (not `[ ] && ...`): an empty setting must not make the function
    # return 1, which would abort the caller under `set -e`.
    if [ -n "$THEME" ]; then _out+=(--use-theme "$THEME"); fi
    if [ -n "$MODEL" ]; then _out+=(--model "$MODEL"); fi
}
