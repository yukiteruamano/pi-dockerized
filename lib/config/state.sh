#!/bin/bash

# state.sh - host-side Pi state: dirs, validation, sync and install checks.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

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
    repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
    readlink -f "$repo_dir/bin/pi-dockerized" 2>/dev/null || true
}

# Canonical install root for this checkout (lib/ -> repo root).
# Usage: install_root
install_root() {
    cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd
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
    this_bin="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../bin" && pwd)/pi-dockerized"
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
