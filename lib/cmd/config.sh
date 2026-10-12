#!/bin/bash

# config.sh - the `config` command (show/edit/get/set/path/sync/pi/allow/profiles)
# and `audit`. Everything here is host-side: no Docker daemon needed.
# Sourced by bin/pi-dockerized (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# Open FILE in the user's editor.
# Usage: edit_file <file>
edit_file() {
    local file="$1" editor
    if ! editor=$(resolve_editor); then
        print_error "No editor found (set \$EDITOR or install sensible-editor, vi or nano)"
        exit 1
    fi
    "$editor" "$file"
}

# Print the files the guard reads from the host, creating nothing.
# Usage: config_pi_file <mcp|allow>
_config_pi_file() {
    case "$1" in
    mcp) echo "$PI_HOME/.pi/agent/mcp.json" ;;
    allow) echo "$PI_HOME/.pi/agent/allow.json" ;;
    esac
}

# Handle `config pi|allow [path|edit]`: the Pi agent files mounted read-only
# into the container, edited here on the host.
# Usage: config_agent_file <mcp|allow> [path|edit]
config_agent_file() {
    local kind="$1" action="${2:-path}" file
    file=$(_config_pi_file "$kind")
    case "$action" in
    path)
        echo "$file"
        ;;
    edit)
        if [ "$kind" = mcp ] && [ ! -f "$file" ]; then
            print_warning "mcp.json does not exist. Running install first..."
            # shellcheck source=lib/install-lib.sh
            source "$REPO_ROOT/lib/install-lib.sh"
            run_install_main --yes || exit 1
        fi
        if [ "$kind" = allow ] && [ ! -f "$file" ]; then
            mkdir -p "$(dirname "$file")"
            printf '[]\n' >"$file"
            print_info "Created $file: a JSON array of {\"id\",\"pattern\",\"reason\"} allow rules."
        fi
        edit_file "$file"
        ;;
    *)
        print_error "Usage: $0 config $kind [path|edit]"
        exit 1
        ;;
    esac
}

# List the named profiles that exist.
list_profiles() {
    local dir name found=false
    if [ -z "$PI_PROFILE" ]; then echo "default (active)"; else echo "default"; fi
    for dir in "$PI_CONFIG_ROOT"/profiles/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        found=true
        if [ "$name" = "$PI_PROFILE" ]; then echo "$name (active)"; else echo "$name"; fi
    done
    [ "$found" = true ] || print_info "No named profiles yet: use '$0 --profile NAME install' to create one."
}

# Function to show or edit configuration
show_config() {
    local subcommand="${1:-show}"
    shift || true

    case "$subcommand" in
    show)
        if [ "${1:-}" = "--sources" ]; then
            parse_config
            print_config_sources
            maybe_drift_hint
        else
            parse_config
            print_config
            maybe_drift_hint
        fi
        ;;
    edit)
        if [ ! -f "$CONFIG_FILE" ]; then
            print_warning "Config file does not exist. Running install first..."
            # shellcheck source=lib/install-lib.sh
            source "$REPO_ROOT/lib/install-lib.sh"
            run_install_main --yes --only config || exit 1
        else
            edit_file "$CONFIG_FILE"
        fi
        ;;
    path)
        echo "$CONFIG_FILE"
        ;;
    get)
        if [ -z "${1:-}" ]; then
            print_error "Usage: $0 config get <setting> [--source]"
            exit 1
        fi
        config_get_value "$1" "${2:-}" || exit 1
        ;;
    set)
        if [ $# -ne 2 ]; then
            print_error "Usage: $0 config set <setting> <value>"
            exit 1
        fi
        config_set_value "$1" "$2" || exit 1
        ;;
    sync)
        # Local-only command: (re)create the host-side Pi state (mcp.json,
        # skills, runtime files) without starting a container. With --check it
        # only reports drift.
        parse_config || true
        sync_pi_state "${1:-}"
        ;;
    pi)
        config_agent_file mcp "${1:-path}"
        ;;
    allow)
        config_agent_file allow "${1:-path}"
        ;;
    profiles)
        list_profiles
        ;;
    *)
        print_error "Unknown config subcommand: $subcommand"
        echo "Usage: $0 config [show|edit|get|set|path|sync|pi|allow|profiles]" >&2
        exit 1
        ;;
    esac
}

# Extract one flat string field from a JSONL audit entry (handles \ escapes).
# Usage: audit_field <line> <field>
audit_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\":\"\(\(\\\\.\|[^\"\\\\]\)*\)\".*/\1/p"
}

# Look up a vendored rule's reason by id in the checked-out policy sets.
# Usage: vendored_reason <rule-id>
# Prints the reason or nothing.
vendored_reason() {
    local id="$1" f
    for f in "$REPO_ROOT/policies/unsafe-tool-patterns.json" "$REPO_ROOT/policies/prompt-injection-patterns.json"; do
        [ -f "$f" ] || continue
        grep -A3 -F "\"id\": \"$id\"" "$f" 2>/dev/null | grep -o '"reason": "[^"]*"' | head -n 1
    done
}

# Explain the Nth most recent blocked call (default: the last one): what rule
# fired, why, and how to proceed when it blocks legitimate work.
# Usage: explain_audit [N]
explain_audit() {
    local n="${1:-1}" log="$PI_HOME/.pi/agent/audit.log" line
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ]; then
        print_error "--explain needs a positive number"
        exit 1
    fi
    if [ ! -s "$log" ]; then
        print_info "No blocked calls recorded."
        return 0
    fi
    local total line
    total=$(wc -l <"$log")
    if [ "$n" -gt "$total" ]; then
        print_error "Only $total blocked call(s) recorded."
        exit 1
    fi
    line=$(tail -n "$n" "$log" | head -n 1)
    local tool rule target ts reason advice
    tool=$(audit_field "$line" tool)
    rule=$(audit_field "$line" rule)
    target=$(audit_field "$line" target)
    ts=$(audit_field "$line" ts)
    print_info "Blocked call ($ts): $tool -> $target"
    print_info "Rule: $rule"
    case "$rule" in
    pi-policy/*)
        reason=$(vendored_reason "${rule#pi-policy/}" | sed 's/^"reason": "//; s/"$//')
        [ -n "$reason" ] && print_info "Why: $reason"
        advice="If this blocks legitimate work, add an allow pattern with '$0 config allow edit', or run the session with a looser --policy."
        ;;
    backstop/unknown-tool)
        advice="Strict mode refuses tools it does not model. List it in setting.allowed_tools ('$0 config set allowed_tools ...')."
        ;;
    backstop/unknown-tool-scope)
        advice="The tool is allowed but this input is outside its scope. Widen the scope in setting.allowed_tools."
        ;;
    backstop/too-long)
        advice="The input exceeded the 16 KiB evaluation cap. Split the call, or write file contents with the write tool."
        ;;
    backstop/*)
        advice="Built-in backstop: never relaxable via allow.json. Change the command, not the policy."
        ;;
    *)
        advice="Unknown rule. Rebuild the image so the wrapper and guard agree ('$0 build')."
        ;;
    esac
    print_info "$advice"
}

# Review the guard's audit log: the tool calls it blocked, newest last.
# Usage: show_audit [-n N] [--summary] [--clear] [--explain [N]]
show_audit() {
    local count=20 mode=tail explain_n=1
    while [ $# -gt 0 ]; do
        case "$1" in
        -n)
            count="${2:-}"
            shift
            ;;
        --summary) mode=summary ;;
        --clear) mode=clear ;;
        --explain)
            mode=explain
            case "${2:-}" in
            '' | -*) ;;
            *)
                explain_n="$2"
                shift
                ;;
            esac
            ;;
        *)
            print_error "Usage: $0 audit [-n N] [--summary] [--clear] [--explain [N]]"
            exit 1
            ;;
        esac
        shift
    done
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        print_error "-n needs a number"
        exit 1
    fi

    local log="$PI_HOME/.pi/agent/audit.log"
    if [ ! -f "$log" ]; then
        print_info "No audit log yet (it is created by 'config sync' or the first session)."
        return 0
    fi
    case "$mode" in
    explain)
        explain_audit "$explain_n"
        ;;
    clear)
        : >"$log"
        print_success "Audit log cleared."
        ;;
    summary)
        if [ -s "$log" ]; then
            grep -o '"rule":"[^"]*"' "$log" | sort | uniq -c | sort -rn
        else
            print_info "No blocked calls recorded."
        fi
        ;;
    *)
        if [ -s "$log" ]; then
            tail -n "$count" "$log"
        else
            print_info "No blocked calls recorded."
        fi
        ;;
    esac
}
