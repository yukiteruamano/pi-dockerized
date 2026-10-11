#!/bin/bash

# rc.sh - managed lines in the shell rc files (PATH, aliases, completions).
# Sourced by lib/install-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# Ensure the <install>/bin PATH export exists in an rc file.
# Returns 0 when added, 1 when already present, 2 on error.
# Usage: ensure_path_in_rc <rcfile>
ensure_path_in_rc() {
    local rc_file="$1"
    # Single quotes are intentional: $HOME/$PATH must stay unexpanded in the rc line.
    # shellcheck disable=SC2016
    local path_line='export PATH="$HOME/.local/share/pi-dockerized/bin:$PATH"'
    [ -f "$rc_file" ] || : >"$rc_file" 2>/dev/null || return 2
    if grep -qF -- 'pi-dockerized/bin' "$rc_file" 2>/dev/null; then
        return 1
    fi
    {
        echo ""
        echo "# Added by pi-dockerized install"
        echo "$path_line"
    } >>"$rc_file" || return 2
    return 0
}

# Replace lines starting with PREFIX that also mention NEEDLE with REPLACEMENT
# (first match; later matching dupes dropped; all other lines preserved).
# Returns 0 when it replaced, 1 when nothing matched.
# Usage: replace_rc_line <file> <prefix> <needle> <replacement>
replace_rc_line() {
    local file="$1" prefix="$2" needle="$3" replacement="$4"
    local tmp replaced=false line
    tmp=$(mktemp "${file}.tmp.XXXXXX" 2>/dev/null) || return 2
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        "$prefix"*)
            case "$line" in
            *"$needle"*)
                if [ "$replaced" = false ]; then
                    printf '%s\n' "$replacement" >>"$tmp" || {
                        rm -f "$tmp"
                        return 2
                    }
                    replaced=true
                fi
                ;;
            *)
                printf '%s\n' "$line" >>"$tmp" || {
                    rm -f "$tmp"
                    return 2
                }
                ;;
            esac
            ;;
        *)
            printf '%s\n' "$line" >>"$tmp" || {
                rm -f "$tmp"
                return 2
            }
            ;;
        esac
    done <"$file" || {
        rm -f "$tmp"
        return 2
    }
    if [ "$replaced" = false ]; then
        rm -f "$tmp"
        return 1
    fi
    cat "$tmp" >"$file" 2>/dev/null || {
        rm -f "$tmp"
        return 2
    }
    rm -f "$tmp"
}

# Ensure the three managed alias lines exist, pointing at the global command
# on PATH (never at an absolute repo path, which goes stale on repo moves).
# Returns 0 when it changed anything, 1 when already ok, 2 on error.
# Usage: ensure_aliases_in_rc <rcfile>
ensure_aliases_in_rc() {
    local rc_file="$1"
    local marker="# Pi Dockerized aliases"
    local a1="alias pid='pi-dockerized'"
    local a2="alias pid-run='pi-dockerized run'"
    local a3="alias pid-auth='pi-dockerized auth'"
    local changed=false line key existing
    [ -f "$rc_file" ] || : >"$rc_file" 2>/dev/null || return 2
    if ! grep -qF -- "$marker" "$rc_file" 2>/dev/null; then
        {
            echo ""
            echo "$marker"
            echo "$a1"
            echo "$a2"
            echo "$a3"
        } >>"$rc_file" || return 2
        return 0
    fi
    for line in "$a1" "$a2" "$a3"; do
        if grep -qxF -- "$line" "$rc_file" 2>/dev/null; then
            continue
        fi
        key="${line%%=*}"
        existing=$(grep -E -- "^${key}=" "$rc_file" 2>/dev/null | head -1 || true)
        if [ -n "$existing" ]; then
            case "$existing" in
            *pi-dockerized*)
                replace_rc_line "$rc_file" "$key=" "pi-dockerized" "$line" || return 2
                ;;
            *)
                printf '%s\n' "$line" >>"$rc_file" || return 2
                echo "Kept your custom '${key}' line; added ours after it (last definition wins)"
                ;;
            esac
        else
            printf '%s\n' "$line" >>"$rc_file" || return 2
        fi
        changed=true
    done
    [ "$changed" = true ]
}

# True when all three managed alias lines exist exactly (global command form).
# Usage: aliases_configured <rcfile>
aliases_configured() {
    local rc_file="$1" a
    for a in "alias pid='pi-dockerized'" "alias pid-run='pi-dockerized run'" "alias pid-auth='pi-dockerized auth'"; do
        grep -qxF -- "$a" "$rc_file" 2>/dev/null || return 1
    done
    return 0
}
