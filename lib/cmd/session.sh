#!/bin/bash

# session.sh - commands that start a container: run, exec, shell, auth, doctor,
# models, stats, mcp, extensions, plus ps/stop for the running ones.
# Sourced by bin/pi-dockerized (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# Every command goes through the same three steps, so they cannot drift:
#   prepare_session    validate the project, load config, build all docker args
#   build_session_cmd  assemble the single `docker run` command (DOCKER_CMD)
#   launch_session     print it (DRY_RUN) or run it, and always clean up

DOCKER_CMD=()
SESSION_PROJECT=""
SESSION_CONTAINER=""

# Resolve a project directory to an absolute, symlink-free path and refuse the
# ones that would expose the home directory (or a parent of it).
# Usage: dir=$(resolve_project_dir <dir>)
resolve_project_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        print_error "Project directory does not exist: $dir"
        exit 1
    fi
    # A symlink to $HOME or / must not slip past validate_project_dir.
    dir="$(cd "$dir" && pwd -P)"
    validate_project_dir "$dir" || exit 1
    printf '%s' "$dir"
}

# Validate inputs, load the config (plus session flags) and build every docker
# argument array. `socket_policy` is "config" (follow setting.docker_socket) or
# "never".
# Usage: prepare_session <project_dir|""> <config|never>
prepare_session() {
    local project_dir="$1" socket_policy="$2"
    SESSION_PROJECT=""
    if [ -n "$project_dir" ]; then
        project_dir="$(resolve_project_dir "$project_dir")" || exit 1
        SESSION_PROJECT="$project_dir"
    fi

    check_image "$IMAGE_NAME" || exit 1
    ensure_pi_dirs
    parse_config
    apply_session_overrides || exit 1

    local socket=false
    [ "$socket_policy" = config ] && socket="$DOCKER_SOCKET"

    build_mount_args
    build_env_args
    build_env_file_args
    build_common_docker_args
    # Docker socket is opt-in: mounting it is root-equivalent on the host.
    build_standard_volume_args "$project_dir" "$socket" || exit 1
    check_image_drift
}

# Assemble the `docker run` command for the prepared session into DOCKER_CMD.
# `tty_mode` is "yes" (always allocate a TTY) or "auto" (only when attached to
# one, so the command stays pipeable).
# Usage: build_session_cmd <container_name> <yes|auto> <command...>
build_session_cmd() {
    local name="$1" tty_mode="$2"
    shift 2
    SESSION_CONTAINER="$name"

    local -a tty_args=(-i) workdir_args=() label_args=()
    if [ "$tty_mode" = yes ] || { [ -t 0 ] && [ -t 1 ]; }; then
        tty_args=(-it)
    fi
    if [ -n "$CONTAINER_WORKDIR" ]; then
        workdir_args=(--workdir "$CONTAINER_WORKDIR" -e "PI_WORKDIR=$CONTAINER_WORKDIR")
    fi
    if [ -n "$SESSION_PROJECT" ]; then
        label_args=(--label "pi-dockerized.project=$SESSION_PROJECT")
    fi

    DOCKER_CMD=(
        docker run "${tty_args[@]}"
        --name "$name"
        "${workdir_args[@]}"
        "${label_args[@]}"
        "${DOCKER_COMMON_ARGS[@]}"
        "${VOLUME_ARGS[@]}"
        "${GIT_WORKTREE_ARGS[@]}"
        "${DOCKER_MOUNT_ARGS[@]}"
        "${DOCKER_ENV_ARGS[@]}"
        "${DOCKER_ENV_FILE_ARGS[@]}"
        "$IMAGE_NAME"
        "$@"
    )
}

# Stop the per-session GnuPG relay (a no-op when none is running).
_session_cleanup() {
    stop_gpg_relay "$GPG_RELAY_SOCKET"
    GPG_RELAY_SOCKET=""
}

# A signal (including the terminal closing) must not leave the container, and
# the project mounted into it, running in the background.
_session_abort() {
    docker stop -t 5 "$SESSION_CONTAINER" >/dev/null 2>&1 || true
    _session_cleanup
    exit 130
}

# Run DOCKER_CMD (or print it with DRY_RUN=true) and return its exit code.
# Usage: launch_session
launch_session() {
    if [ "${DRY_RUN:-false}" = true ]; then
        print_info "Dry run — would execute:"
        dry_run_print "${DOCKER_CMD[@]}"
        _session_cleanup
        return 0
    fi
    trap _session_cleanup EXIT
    trap _session_abort INT TERM HUP
    local rc=0
    "${DOCKER_CMD[@]}" || rc=$?
    _session_cleanup
    trap - EXIT INT TERM HUP
    return "$rc"
}

# Run a one-off command inside the container. The project directory (when
# given) is mounted so project-level configuration applies.
# Usage: run_cli_command <name_suffix> <project_dir|""> <config|never> <command...>
run_cli_command() {
    local name_suffix="$1" project_dir="$2" socket_policy="$3"
    shift 3
    prepare_session "$project_dir" "$socket_policy"
    build_session_cmd "pi-${name_suffix}-$$" auto "$@"
    launch_session
}

# Function to check provider credentials
run_auth() {
    print_info "Checking Pi provider credentials..."
    if ! run_cli_command auth "" never /usr/local/lib/pi-dockerized/auth-check.sh; then
        print_error "No usable provider credentials found."
        print_info "Add provider API keys to setting.env_file and re-run."
        exit 1
    fi
    print_success "Provider credentials are ready."
}

# Diagnose the security layer, credentials and agent forwarding in-container.
# Project-independent: doctor needs no project mount (like auth).
run_doctor() {
    run_cli_command doctor "" never /usr/local/lib/pi-dockerized/doctor.sh
}

# Function to run Pi
# Usage: run_pi [--policy P] [--network N] [--untrusted] [DIR]
run_pi() {
    parse_session_flags "$@" || exit 1
    set -- "${SESSION_REST[@]}"
    local project_dir="${1:-${SESSION_DIR:-$(pwd)}}"

    prepare_session "$project_dir" config
    project_dir="$SESSION_PROJECT"

    # Unique container name from the project directory and a random suffix.
    local container_name
    container_name="pi-$(sanitize_container_name "$(basename "$project_dir")")-$(generate_random_suffix)"

    print_info "Starting Pi in Docker..."
    print_info "Project directory: $project_dir"
    print_info "Container name: $container_name"
    print_session_exposure

    local -a pi_args=()
    build_pi_args pi_args
    build_session_cmd "$container_name" yes pi "${pi_args[@]}"

    if [ "${DRY_RUN:-false}" = true ]; then
        launch_session
        return $?
    fi

    if [ "${PI_DOCKERIZED_DEBUG:-}" = 1 ]; then
        print_info "Debug — docker command:"
        dry_run_print "${DOCKER_CMD[@]}"
        # Preflight: start the very same container to run `pi --version`, so a
        # broken mount or startup error is visible before the TUI takes over.
        print_info "Debug — preflight (pi --version):"
        "${DOCKER_CMD[@]}" --version || print_warning "Preflight failed (see the error above)."
    fi

    # Pi decides between its TUI and print mode from the terminal: with a TTY it
    # opens the TUI, otherwise it runs in print mode and exits immediately with
    # no output. Warn early so a missing TTY does not look like a silent hang.
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        print_warning "No interactive terminal detected (stdin/stdout is not a TTY)."
        print_info "Pi will start in print mode and exit at once. Run from a real terminal,"
        print_info "or use '$0 exec \"...\"' for non-interactive prompts."
    fi

    local rc=0 started ended
    started=$(date +%s)
    launch_session || rc=$?
    ended=$(date +%s)
    if [ "$rc" -ne 0 ]; then
        print_error "Pi exited with an error (container exit code $rc)"
        print_info "Re-run with PI_DOCKERIZED_DEBUG=1 to print the docker command,"
        print_info "and '$0 doctor' to check the in-container setup."
        exit 1
    fi
    # A TUI session lasts until the user quits. Exiting cleanly within a couple
    # of seconds means Pi ran in print mode (no usable TTY) and produced nothing.
    if [ $((ended - started)) -lt 3 ]; then
        print_warning "Pi exited immediately without opening the TUI."
        print_info "That happens when the container has no TTY: Pi falls back to print mode."
        print_info "Re-run with PI_DOCKERIZED_DEBUG=1 to see the docker command, or use"
        print_info "'$0 exec \"...\"' for non-interactive prompts."
    fi
}

# Run a non-interactive prompt and print the result. The prompt comes from the
# arguments or, when none are given (or the first is "-"), from stdin. Pi's exit
# code is the command's exit code.
# Usage: exec_prompt [--dir DIR] [--policy P] [--network N] [--untrusted] [MSG|-] [PI OPTS]
exec_prompt() {
    parse_session_flags "$@" || exit 1
    set -- "${SESSION_REST[@]}"

    local -a pi_args=("$@")
    if [ "${1:-}" = "-" ]; then
        pi_args=("$(cat)" "${@:2}")
    elif [ $# -eq 0 ] && [ ! -t 0 ]; then
        pi_args=("$(cat)")
    fi
    if [ "${#pi_args[@]}" -eq 0 ] || [ -z "${pi_args[0]}" ]; then
        print_error "A message is required: $0 exec [--dir DIR] \"<message>\" [OPTIONS]  (or pipe it on stdin)"
        exit 1
    fi

    run_cli_command exec "${SESSION_DIR:-$(pwd)}" config pi --print "${pi_args[@]}"
}

# Open a shell inside the sandbox (same mounts and limits as `run`) to debug
# the environment by hand.
# Usage: run_shell [--policy P] [--network N] [--untrusted] [DIR]
run_shell() {
    parse_session_flags "$@" || exit 1
    set -- "${SESSION_REST[@]}"
    local project_dir="${1:-${SESSION_DIR:-$(pwd)}}"

    prepare_session "$project_dir" config
    print_session_exposure
    build_session_cmd "pi-shell-$$" yes bash
    launch_session
}

# Function to list the models available to the configured providers
# Usage: list_models [search]
list_models() {
    parse_config
    local -a extra=(--list-models)
    if [ -n "${1:-}" ]; then
        extra=(--list-models "$1")
    elif [ -n "$MODEL" ]; then
        extra=(--list-models "$MODEL")
    fi
    run_cli_command models "" never pi "${extra[@]}"
}

# Function to show session usage statistics (best-effort via RPC).
show_stats() {
    # Pi exposes session metrics over its RPC interface (get_session_stats).
    # Best-effort: send the command and let Pi exit on stdin EOF.
    run_cli_command stats "" never bash -c \
        'printf "%s\n" "{\"type\":\"get_session_stats\"}" | timeout 30 pi --mode rpc'
}

# Warn that the Pi agent config is read-only inside the container and point the
# user at the host-side file to edit. Usage: config_readonly_guard <what>
config_readonly_guard() {
    local what="${1:-changes}"
    print_error "The Pi agent config is baked read-only into the image; '$what' is not available from here."
    print_info "MCP servers: edit on the host with '$0 config pi edit' (mcp.json)."
    print_info "Extensions: host-managed; use '$0 extensions install|remove|edit'."
}

# Function to manage MCP servers (list, login, logout)
manage_mcp() {
    local subcommand="${1:-list}"
    shift || true
    # 'add'/'remove' write to mcp.json, which is mounted read-only; login/logout
    # write OAuth tokens to mcp-auth.json and keep working.
    case "$subcommand" in
    add | remove | rm)
        config_readonly_guard "pi mcp $subcommand"
        exit 1
        ;;
    esac
    run_cli_command mcp "" never pi mcp "$subcommand" "$@"
}

# Names of the running pi-dockerized containers, one per line.
running_sessions() {
    docker ps --filter "label=pi-dockerized=1" --format '{{.Names}}'
}

# List running sessions with their project and status.
list_sessions() {
    docker ps --filter "label=pi-dockerized=1" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Label "pi-dockerized.project"}}'
}

# Stop one running session by name, or every one with --all.
# Usage: stop_sessions <NAME|--all>
stop_sessions() {
    local target="${1:-}" name
    local -a names=()
    if [ -z "$target" ]; then
        print_error "Usage: $0 stop <NAME|--all>  (see '$0 ps' for names)"
        exit 1
    fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$target" = "--all" ] || [ "$target" = "$name" ]; then
            names+=("$name")
        fi
    done < <(running_sessions)
    if [ "${#names[@]}" -eq 0 ]; then
        print_info "No matching running session."
        return 0
    fi
    docker stop "${names[@]}" >/dev/null
    print_success "Stopped: ${names[*]}"
}
