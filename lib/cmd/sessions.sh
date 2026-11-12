#!/bin/bash

# sessions.sh - session inventory without starting a container: the local
# transcripts (`run --list`) and the running containers (`ps`, `stop`).
# Sourced by bin/pi-dockerized (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# Everything listed here was written by a container (transcripts, labels), so
# it is read defensively and printed without control characters.

# List local Pi sessions (short id, start time) without starting a container.
# Filenames already carry `<timestamp>_<id>`; no JSON parsing needed.
# Usage: list_pi_sessions
list_pi_sessions() {
    local dir="$PI_HOME/.pi/agent/sessions" f base ts id
    if [ ! -d "$dir" ]; then
        print_info "No sessions yet."
        return 0
    fi
    local found=false
    # sessions/ is written by the container: only regular files are read (a
    # symlink or FIFO could make the wrapper read a host file or hang), and
    # every field is stripped of control characters before it is printed.
    for f in "$dir"/*.jsonl; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        if [ "$found" = false ]; then
            printf '%-10s  %-22s  %s\n' "SESSION" "STARTED" "PROJECT"
            found=true
        fi
        base=$(basename "$f" .jsonl)
        ts=${base%%_*}
        id=${base#*_}
        printf '%-10s  %-22s  %s\n' "${id:0:8}" "$ts" "$(session_project "$f")" | strip_control_chars
    done
    if [ "$found" = false ]; then
        print_info "No sessions yet."
    else
        print_info "Resume with '$0 run --resume <session>' (partial id is enough)."
    fi
}

# Project directory recorded in a session file's first line, or "-" when the
# file is unreadable (best-effort: never fail the listing on one bad file).
# Usage: session_project <file>
session_project() {
    local cwd
    # The header is on the first line: read a bounded prefix, never the whole
    # (container-written, possibly huge) transcript.
    cwd=$(head -c 65536 -- "$1" 2>/dev/null | grep -o '"cwd":"[^"]*"' | head -n 1 | cut -d'"' -f4) || cwd=""
    if [ -n "$cwd" ]; then
        printf '%s' "$cwd"
    else
        printf '-'
    fi
}

# Names of the running pi-dockerized containers, one per line.
running_sessions() {
    docker ps --filter "label=pi-dockerized=1" --format '{{.Names}}'
}

# List running sessions with their project and status.
# Usage: list_sessions [--json]  (--json prints one object per line)
list_sessions() {
    if [ "${1:-}" = "--json" ]; then
        docker ps --filter "label=pi-dockerized=1" \
            --format '{{.Names}}\t{{.Status}}\t{{.Label "pi-dockerized.profile"}}\t{{.Label "pi-dockerized.project"}}' |
            while IFS="$(printf '\t')" read -r name status profile project; do
                [ -n "$name" ] || continue
                printf '{"name":"%s","status":"%s","profile":"%s","project":"%s"}\n' \
                    "$(json_escape "$name")" "$(json_escape "$status")" \
                    "$(json_escape "$profile")" "$(json_escape "$project")"
            done
    else
        # Labels carry project paths: strip control characters before printing.
        docker ps --filter "label=pi-dockerized=1" \
            --format 'table {{.Names}}\t{{.Status}}\t{{.Label "pi-dockerized.profile"}}\t{{.Label "pi-dockerized.project"}}' |
            strip_control_chars
    fi
}

# Stop one running session by exact name, or every one with --all.
# --all asks for confirmation unless --yes/--force is given (scripts must
# opt in: stopping every session by accident hurts).
# Usage: stop_sessions [--yes|--force] <NAME|--all>
stop_sessions() {
    local force=false target="" a name
    for a in "$@"; do
        case "$a" in
        --yes | --force) force=true ;;
        --all)
            if [ -n "$target" ]; then
                print_error "Usage: $0 stop [--yes] <NAME|--all>"
                exit 1
            fi
            target="--all"
            ;;
        --*)
            print_error "Unknown stop option: $a (use --yes/--force)"
            exit 1
            ;;
        *)
            if [ -n "$target" ]; then
                print_error "Usage: $0 stop [--yes] <NAME|--all>"
                exit 1
            fi
            target="$a"
            ;;
        esac
    done
    if [ -z "$target" ]; then
        print_error "Usage: $0 stop [--yes] <NAME|--all>  (see '$0 ps' for names)"
        exit 1
    fi
    local -a names=() all=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        all+=("$name")
    done < <(running_sessions)
    if [ "$target" = "--all" ]; then
        names=("${all[@]}")
        if [ "${#names[@]}" -eq 0 ]; then
            print_info "No running sessions."
            return 0
        fi
        if [ "$force" != true ]; then
            local ans=""
            if [ -t 0 ]; then
                read -r -p "Stop ${#names[@]} session(s) (${names[*]})? [y/N] " ans || ans=""
            fi
            case "$ans" in
            [Yy] | [Yy]es) ;;
            *)
                print_error "Aborted: pass --yes to stop ${#names[@]} session(s)."
                exit 1
                ;;
            esac
        fi
    else
        for name in "${all[@]}"; do
            [ "$name" = "$target" ] && names+=("$name")
        done
        if [ "${#names[@]}" -eq 0 ]; then
            local -a similar=()
            for name in "${all[@]}"; do
                case "$name" in
                "$target"* | *"$target"*) similar+=("$name") ;;
                esac
            done
            if [ "${#similar[@]}" -gt 0 ]; then
                print_error "No session named '$target'. Did you mean: ${similar[*]}?"
            else
                print_error "No session named '$target' (see '$0 ps' for names)."
            fi
            exit 1
        fi
    fi
    docker stop "${names[@]}" >/dev/null
    print_success "Stopped: ${names[*]}"
}
