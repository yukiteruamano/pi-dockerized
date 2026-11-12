#!/bin/bash

# docker-args.sh - git worktree support and docker run argument building.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# ============================================
# GIT WORKTREE SUPPORT
# ============================================

# Detect if a directory is a linked git worktree and print the main repo's .git
# directory (the common dir), or nothing. A worktree has a .git FILE containing
# "gitdir: <main>/.git/worktrees/<name>". The project is untrusted content, so
# the pointer is parsed here (git itself is never run on it) and only accepted
# when it has the shape git creates: <common>/worktrees/<name>, whose own
# `gitdir` file points back at this project's .git file. A planted pointer
# (e.g. a `commondir` aimed at another private repo) is ignored.
# Usage: main_git_dir=$(detect_git_worktree "/path/to/worktree")
detect_git_worktree() {
    local project_dir="$1" line gitdir back common

    [ -f "$project_dir/.git" ] && [ ! -L "$project_dir/.git" ] || return 0
    IFS= read -r line 2>/dev/null <"$project_dir/.git" || return 0
    [[ "$line" == "gitdir: "* ]] || return 0
    gitdir="${line#gitdir: }"
    [[ "$gitdir" == /* ]] || gitdir="$project_dir/$gitdir"
    gitdir=$(canonical_path "$gitdir")

    [ "$(basename "$(dirname "$gitdir")")" = worktrees ] || return 0
    common=$(dirname "$(dirname "$gitdir")")

    # The back-pointer git writes for every linked worktree.
    IFS= read -r back 2>/dev/null <"$gitdir/gitdir" || return 0
    [ "$(canonical_path "$back")" = "$(canonical_path "$project_dir/.git")" ] || return 0

    # Sanity check: the common dir must be a real .git directory.
    if [ ! -d "$common/objects" ] || [ ! -d "$common/refs" ]; then
        return 0
    fi

    printf '%s' "$common"
}

# Build Docker volume/bind args needed for git worktree support.
# When the project is a git worktree, the .git file points to the main repo's
# .git directory which lives outside the project dir. We mount the main .git
# directory (read-only) at its real host path so the gitdir pointer resolves
# correctly inside the container. The common dir passes the same source and
# target checks as any other mount, and --untrusted sessions never get it.
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
    [ "$SESSION_UNTRUSTED" != true ] || return 0

    local git_common_dir
    git_common_dir=$(detect_git_worktree "$project_dir")

    if [ -z "$git_common_dir" ]; then
        return 0
    fi
    if ! validate_mount_source "$git_common_dir" "git worktree" ||
        ! validate_container_path "$git_common_dir" "the git worktree"; then
        config_warning "Not mounting the main .git directory; git will be unavailable in the container"
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
        return "$E_CONFIG"
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
    validate_pi_config || exit "$E_CONFIG"
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
        --label "pi-dockerized=1"
        --label "pi-dockerized.profile=${PI_PROFILE:-default}"
        -e "TERM=${TERM:-xterm-256color}"
    )

    # Optional resource limits (setting.memory / setting.cpus) and the process
    # cap (setting.pids_limit): fork bombs are contained by the kernel, since
    # the balanced policy no longer pattern-matches them.
    [ -n "$MEMORY" ] && DOCKER_COMMON_ARGS+=(--memory "$MEMORY")
    [ -n "$CPUS" ] && DOCKER_COMMON_ARGS+=(--cpus "$CPUS")
    local pids_limit="${PIDS_LIMIT:-4096}"
    [ "$pids_limit" != unlimited ] && DOCKER_COMMON_ARGS+=(--pids-limit "$pids_limit")

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
    # Tells entrypoint.sh which settings rules to check (host file vs packages).
    DOCKER_COMMON_ARGS+=(-e "PI_DOCKERIZED_SETTINGS_SOURCE=$(settings_source)")

    # Install/update telemetry off by default (override with PI_TELEMETRY=1).
    DOCKER_COMMON_ARGS+=(-e "PI_TELEMETRY=${PI_TELEMETRY:-0}")

    # Security policy mode consumed by the baked security-guard extension
    # (strict | balanced | off). Defaults to balanced when unset.
    DOCKER_COMMON_ARGS+=(-e "PI_DOCKERIZED_POLICY=$SECURITY_POLICY")

    # Strict mode refuses tools outside the built-in set unless listed here.
    DOCKER_COMMON_ARGS+=(-e "PI_DOCKERIZED_ALLOWED_TOOLS=$ALLOWED_TOOLS")

    # Where the guard finds the optional host allow rules and writes its audit
    # log (both mounted by build_standard_volume_args when present).
    DOCKER_COMMON_ARGS+=(-e "PI_DOCKERIZED_ALLOW_FILE=$PI_AGENT_CONTAINER_DIR/allow.json")
    DOCKER_COMMON_ARGS+=(-e "PI_DOCKERIZED_AUDIT_FILE=$PI_AGENT_CONTAINER_DIR/audit.log")
}

# Which settings.json a session mounts: "ext" when Pi Packages are installed
# (their installer file replaces the host one), "host" otherwise. Untrusted
# sessions never receive packages, so they always use the host file.
# Usage: settings_source (prints ext|host)
settings_source() {
    if [ -f "$EXT_AGENT_DIR/settings.json" ] && [ "$SESSION_UNTRUSTED" != true ]; then
        echo ext
    else
        echo host
    fi
}

# Mount the Pi Packages installed with `pi-dockerized extensions install`: their
# settings.json, npm/ and git/, read-only (code the session loads but can never
# change). The entrypoint checks that the settings still carry the sandbox's
# security keys. Usage: mount_ext_packages (returns 1 on invalid JSON)
mount_ext_packages() {
    local ext_part ev=0
    json_valid "$EXT_AGENT_DIR/settings.json" || ev=$?
    if [ "$ev" -eq 1 ]; then
        config_error "$EXT_AGENT_DIR/settings.json is not valid JSON; fix it or remove it."
        return 1
    fi
    VOLUME_ARGS+=(-v "$EXT_AGENT_DIR/settings.json:$PI_AGENT_CONTAINER_DIR/settings.json:ro")
    for ext_part in npm git; do
        if [ -d "$EXT_AGENT_DIR/$ext_part" ]; then
            VOLUME_ARGS+=(-v "$EXT_AGENT_DIR/$ext_part:$PI_AGENT_CONTAINER_DIR/$ext_part:ro")
        fi
    done
}

# Mount the host state shared between trusted sessions: the npm cache, the qmd
# index and models, the pi-lens state and the read-only compat skill dirs.
# Appends to VOLUME_ARGS. Usage: build_shared_state_args
build_shared_state_args() {
    # npm cache (read-write): persisted so npx-based MCP servers do not re-download.
    if [ -d "$PI_HOME/.npm" ]; then
        VOLUME_ARGS+=(-v "$PI_HOME/.npm:/home/coder/.npm:rw")
    fi

    # qmd keeps its index and downloaded models under ~/.cache/qmd; the
    # container is ephemeral (--rm), so persist them on the host.
    if [ -d "$PI_HOME/.cache/qmd" ]; then
        VOLUME_ARGS+=(-v "$PI_HOME/.cache/qmd:/home/coder/.cache/qmd:rw")
    fi

    # pi-lens keeps its state under ~/.pi-lens; persist it on the host so it
    # survives container restarts (the container is ephemeral, --rm).
    if [ -d "$PI_HOME/.pi-lens" ]; then
        VOLUME_ARGS+=(-v "$PI_HOME/.pi-lens:/home/coder/.pi-lens:rw")
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
}

# Build standard volume mount arguments for Pi directories.
# Populates VOLUME_ARGS and CONTAINER_WORKDIR.
# The project is mounted at a path derived from the host path (with $HOME
# stripped) so that Pi stores a unique, meaningful directory per project.
# The read-only resources (settings.json base, extensions, AGENTS.md) are baked
# into the image and are NOT mounted. Host-managed inputs are bind-mounted: mcp.json
# and models.json (RO), skills (RO), prompts and themes (RW), plus the session
# store, the runtime files Pi persists and the pi-lens state directory.
build_standard_volume_args() {
    local project_dir="$1"
    local include_docker_socket="${2:-false}"

    VOLUME_ARGS=()

    # Compute container-side mount path: strip $HOME prefix for portability
    # e.g. /home/user/projects/acme/frontend -> /projects/acme/frontend
    CONTAINER_WORKDIR=$(compute_container_path "$project_dir")

    # Project directory (read-write) — mounted at the computed path.
    # Skipped when no project is given (e.g. auth) or when it resolves to $HOME.
    # Stripping $HOME can land on a system path (~/etc -> /etc): refuse those.
    if [ -n "$project_dir" ] && [ -n "$CONTAINER_WORKDIR" ]; then
        validate_container_path "$CONTAINER_WORKDIR" "the project" || return 1
        VOLUME_ARGS+=(-v "$project_dir:$CONTAINER_WORKDIR")
        build_git_worktree_args "$project_dir"
    fi

    local agent="$PI_HOME/.pi/agent"
    # --untrusted sessions share as little host state as possible: no MCP
    # servers or their OAuth tokens, no shared caches, no compat skills, data
    # directories read-only and a session store of their own.
    local untrusted=false
    [ "$SESSION_UNTRUSTED" = true ] && untrusted=true

    # MCP server definitions: host-managed, mounted read-only. Edited on the
    # host with 'pi-dockerized config pi edit'; the container can never modify
    # the server list.
    if [ "$untrusted" = true ]; then
        :
    elif [ -f "$agent/mcp.json" ]; then
        VOLUME_ARGS+=(-v "$agent/mcp.json:$PI_AGENT_CONTAINER_DIR/mcp.json:ro")
    else
        config_warning "mcp.json not found at $agent/mcp.json (run 'pi-dockerized install')"
    fi

    # Skills instruct the model, so they are host-managed and mounted read-only:
    # a session cannot add or change them. Edit them on the host.
    if [ -d "$agent/skills" ]; then
        VOLUME_ARGS+=(-v "$agent/skills:$PI_AGENT_CONTAINER_DIR/skills:ro")
    fi

    # Prompt templates and themes are data, not code: read-write so they can be
    # added or edited from the host or from inside a session. Prompt templates
    # still instruct the model, so an untrusted session only reads them.
    local data_dir data_mode=rw
    [ "$untrusted" = true ] && data_mode=ro
    for data_dir in prompts themes; do
        if [ -d "$agent/$data_dir" ]; then
            VOLUME_ARGS+=(-v "$agent/$data_dir:$PI_AGENT_CONTAINER_DIR/$data_dir:$data_mode")
        fi
    done

    # settings.json has one mount target, so exactly one file is mounted there
    # (see settings_source). Both are read-only and checked by the entrypoint.
    if [ "$(settings_source)" = ext ]; then
        if [ -f "$agent/settings.json" ]; then
            config_warning "Pi Packages are installed: the host settings.json is not applied (ext-agent/settings.json is used)"
        fi
        mount_ext_packages || return 1
    elif [ -f "$agent/settings.json" ]; then
        local hv=0
        json_valid "$agent/settings.json" || hv=$?
        if [ "$hv" -eq 1 ]; then
            config_error "$agent/settings.json is not valid JSON; fix it or remove it."
            return 1
        fi
        VOLUME_ARGS+=(-v "$agent/settings.json:$PI_AGENT_CONTAINER_DIR/settings.json:ro")
    fi

    # Session store (Pi persists conversations here; sessionDir is fixed to this
    # path by the baked settings.json). Untrusted transcripts live apart, so a
    # trusted session never resumes or reads one (and vice versa).
    local sessions_dir="$agent/sessions"
    if [ "$untrusted" = true ]; then
        sessions_dir="$agent/sessions-untrusted"
        (umask 077 && mkdir -p "$sessions_dir") 2>/dev/null || true
    fi
    if [ -d "$sessions_dir" ]; then
        VOLUME_ARGS+=(-v "$sessions_dir:$PI_AGENT_CONTAINER_DIR/sessions:rw")
    fi

    # Runtime state Pi writes into the agent directory. auth.json (provider
    # logins) is the only one an untrusted session keeps: without it OAuth
    # providers could not refresh their tokens.
    local -a state_files=(auth.json mcp-auth.json trust.json mcp.log)
    [ "$untrusted" = true ] && state_files=(auth.json)
    local state_file
    for state_file in "${state_files[@]}"; do
        if [ -f "$agent/$state_file" ]; then
            VOLUME_ARGS+=(-v "$agent/$state_file:$PI_AGENT_CONTAINER_DIR/$state_file:rw")
        fi
    done

    # Guard audit log (read-write): one JSON line per blocked call.
    if [ -f "$agent/audit.log" ]; then
        VOLUME_ARGS+=(-v "$agent/audit.log:$PI_AGENT_CONTAINER_DIR/audit.log:rw")
    fi

    # Host-managed extra allow rules for the guard (read-only: the session can
    # never widen its own allowlist). Skipped for --untrusted sessions.
    if [ -f "$agent/allow.json" ] && [ "$untrusted" != true ]; then
        local av=0
        json_valid "$agent/allow.json" || av=$?
        if [ "$av" -eq 1 ]; then
            config_error "$agent/allow.json is not valid JSON; fix it or remove it."
            return 1
        fi
        VOLUME_ARGS+=(-v "$agent/allow.json:$PI_AGENT_CONTAINER_DIR/allow.json:ro")
    fi

    # Host-managed provider definitions (read-only: the session cannot point
    # providers at other endpoints). Skipped for --untrusted sessions, which use
    # only the image's providers.
    if [ -f "$agent/models.json" ] && [ "$untrusted" != true ]; then
        local mv=0
        json_valid "$agent/models.json" || mv=$?
        if [ "$mv" -eq 1 ]; then
            config_error "$agent/models.json is not valid JSON; fix it or remove it."
            return 1
        fi
        VOLUME_ARGS+=(-v "$agent/models.json:$PI_AGENT_CONTAINER_DIR/models.json:ro")
    fi

    # Caches and compat skills are shared by every session: an untrusted one
    # could poison them for the trusted ones (e.g. the npm cache that npx-based
    # MCP servers reuse), so it gets none.
    if [ "$untrusted" != true ]; then
        build_shared_state_args
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
