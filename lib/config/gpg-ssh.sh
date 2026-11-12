#!/bin/bash

# gpg-ssh.sh - GnuPG / SSH agent forwarding and the GPG socket relay.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# ============================================
# GnuPG / SSH AGENT FORWARDING
# ============================================

# True when a forwarding socket is safe to mount: a real socket owned by this
# user. A planted socket (another owner) could impersonate the agent and
# harvest signatures or auth requests. Warns on refusal.
# Usage: forwarding_socket_ok <path> <what>
forwarding_socket_ok() {
    local sock="$1" what="$2"
    [ -S "$sock" ] || return 1
    if [ ! -O "$sock" ]; then
        config_warning "$what socket $sock is not owned by you; refusing to forward it"
        return 1
    fi
    return 0
}

# Resolve the host's gpg-agent socket path.
# Prefers the GPG_AGENT_SOCKET test override (test mode only, see test_seam),
# then gpgconf. Prints an empty string when neither is available.
resolve_gpg_agent_socket() {
    local override
    override=$(test_seam GPG_AGENT_SOCKET)
    if [ -n "$override" ]; then
        echo "$override"
        return 0
    fi
    if command -v gpgconf >/dev/null 2>&1; then
        gpgconf --list-dirs agent-socket 2>/dev/null || true
    fi
}

# Resolve the host's restricted gpg-agent "extra" socket path. This socket only
# allows signing/decryption, so a forwarded container cannot reconfigure the
# host agent. Prefers the GPG_AGENT_EXTRA_SOCKET test override (test mode
# only), then gpgconf. Prints an empty string when neither is available.
resolve_gpg_agent_extra_socket() {
    local override
    override=$(test_seam GPG_AGENT_EXTRA_SOCKET)
    if [ -n "$override" ]; then
        echo "$override"
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
#   - GPG_AGENT_PROBE_CMD replaces the probe with an arbitrary command (only
#     honored with PI_DOCKERIZED_TEST=1, see test_seam).
#   - GPG_AGENT_SOCKET / GPG_AGENT_EXTRA_SOCKET (plain test sockets, not real
#     agents; test mode only) skip the probe and trust the socket.
# Usage: gpg_agent_is_running
gpg_agent_is_running() {
    local extra main
    extra=$(resolve_gpg_agent_extra_socket)
    main=$(resolve_gpg_agent_socket)

    if { [ -z "$extra" ] || [ ! -S "$extra" ]; } && { [ -z "$main" ] || [ ! -S "$main" ]; }; then
        return 1
    fi

    local probe_cmd
    probe_cmd=$(test_seam GPG_AGENT_PROBE_CMD)
    if [ -n "$probe_cmd" ]; then
        bash -c "$probe_cmd" >/dev/null 2>&1 && return 0
        return 1
    fi

    # Test sockets are not real agents: trust the socket.
    if [ -n "$(test_seam GPG_AGENT_SOCKET)" ] || [ -n "$(test_seam GPG_AGENT_EXTRA_SOCKET)" ]; then
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
    local launch_cmd
    launch_cmd=$(test_seam GPG_AGENT_LAUNCH_CMD)
    if [ -n "$launch_cmd" ]; then
        bash -c "$launch_cmd" >/dev/null 2>&1 || true
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

    # The socket exists. Ownership is enforced again at the mount site; a
    # planted socket must never be forwarded even if this check is skipped.
    # Do not query it here (ssh-add against a non-agent socket can block);
    # the forwarded agent is used by git/ssh directly.
    forwarding_socket_ok "$SSH_AUTH_SOCK" "SSH agent" || true
    return 0
}

# Parent of the per-session GnuPG mirrors. Each session gets its own mirror
# (named after the wrapper's PID): the container writes into it (keyboxd
# socket, lock files, trustdb), so a shared one let a starting session delete
# the agent link and keyboxd socket of a running one, and left cross-container
# locks behind.
gpg_mirror_root() {
    printf '%s' "$PI_HOME/.gnupg-sessions"
}

# True when a PID-named session entry (mirror or relay) belongs to a wrapper
# that is still running. The wrapper exists before it creates the entry, so a
# session that is still starting is never mistaken for a stale one.
# Usage: session_entry_alive <dir>
session_entry_alive() {
    local pid
    pid=$(basename "$1")
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Delete the mirrors of sessions whose wrapper is gone (crash, kill -9). Only
# PID-named real directories under the mirror root are touched; rm does not
# follow symlinks a session may have planted inside.
# Usage: cleanup_stale_gpg_mirrors
cleanup_stale_gpg_mirrors() {
    local root d
    root=$(gpg_mirror_root)
    [ -d "$root" ] && [ ! -L "$root" ] || return 0
    for d in "$root"/*; do
        [ -d "$d" ] && [ ! -L "$d" ] && [[ "$(basename "$d")" =~ ^[0-9]+$ ]] || continue
        session_entry_alive "$d" && continue
        rm -rf -- "$d"
    done
}

# Remove this session's mirror (set by ensure_gpg_mirror) when it ends.
# Usage: remove_gpg_mirror
remove_gpg_mirror() {
    case "$GPG_MIRROR_DIR" in
    "$(gpg_mirror_root)"/[0-9]*) rm -rf -- "$GPG_MIRROR_DIR" ;;
    esac
    GPG_MIRROR_DIR=""
}

# Mirror the host's *public* GnuPG material into this session's own directory
# (GPG_MIRROR_DIR) so the container can use the host gpg-agent (forwarded via
# its socket) without ever receiving the private keys. Only public files are
# copied; private-keys-v1.d, the agent sockets and random_seed are deliberately
# excluded.
# Usage: ensure_gpg_mirror
ensure_gpg_mirror() {
    local host_gpg_home="${GNUPGHOME:-$HOME/.gnupg}"
    local root dest
    root=$(gpg_mirror_root)
    dest="$root/$$"
    GPG_MIRROR_DIR=""

    if [ ! -d "$host_gpg_home" ]; then
        config_warning "GnuPG agent support enabled but no GnuPG home found at $host_gpg_home"
        return 0
    fi
    if [ -L "$root" ]; then
        config_warning "$root is a symlink; not mirroring GnuPG material through it"
        return 0
    fi
    (umask 077 && mkdir -p "$root") 2>/dev/null || return 0
    # Start from an empty directory: one left by an earlier process with the
    # same PID (or an earlier call in this one) is stale.
    rm -rf -- "$dest"
    (umask 077 && mkdir "$dest") 2>/dev/null || return 0
    GPG_MIRROR_DIR="$dest"

    # Every host-side write happens here, into the fresh directory, before the
    # container starts: nothing a session plants in its mirror (it is mounted
    # read-write) can redirect them, and nothing stale needs clearing.

    # Public keyring (GnuPG 2.x keybox) plus its lock/trust files. With keyboxd
    # the database can also live under public-keys.d/, so mirror that too.
    # Private keys (private-keys-v1.d) are never copied.
    local f
    for f in pubring.kbx trustdb.gpg sshcontrol; do
        if [ -f "$host_gpg_home/$f" ]; then
            _mirror_copy "$host_gpg_home/$f" "$dest/$f"
        fi
    done
    if [ -f "$host_gpg_home/public-keys.d/pubring.db" ]; then
        (umask 077 && mkdir "$dest/public-keys.d") 2>/dev/null &&
            _mirror_copy "$host_gpg_home/public-keys.d/pubring.db" "$dest/public-keys.d/pubring.db"
    fi

    # Mirror the config verbatim, including `use-keyboxd`: on such hosts GnuPG
    # keeps the public keyring in the keyboxd database (public-keys.d/), so the
    # container must run keyboxd to read it. entrypoint.sh launches it at boot,
    # in this session's own mirror; `no-autostart` (below) still prevents a
    # keyless local gpg-agent: the real agent is the host's, reached through the
    # forwarded socket. gpg.conf is always written (the host's, or an empty one)
    # with `no-autostart` ensured.
    local conf
    for conf in gpg.conf common.conf; do
        if [ -f "$host_gpg_home/$conf" ]; then
            _mirror_copy "$host_gpg_home/$conf" "$dest/$conf"
        elif [ "$conf" = gpg.conf ]; then
            _mirror_copy /dev/null "$dest/$conf"
        fi
    done

    # Without a public keyring gpg cannot build a signature even when the agent
    # socket is forwarded: warn instead of failing silently later.
    if [ ! -f "$dest/pubring.kbx" ] && [ ! -f "$dest/public-keys.d/pubring.db" ]; then
        config_warning "No public GnuPG keyring found in $host_gpg_home (commit signing will not work)"
    fi
}

# Copy a host file into the GnuPG mirror without following anything planted at
# the destination: write a private temp file next to it, then rename it over
# the destination (a rename replaces a symlink, it never writes through it).
# gpg.conf additionally gets `no-autostart`.
# Usage: _mirror_copy <src> <dest>
_mirror_copy() {
    local src="$1" dst="$2" tmp
    tmp=$(mktemp "$(dirname "$dst")/.mirror.XXXXXX" 2>/dev/null) || return 0
    if ! cat "$src" >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 0
    fi
    if [ "$(basename "$dst")" = gpg.conf ] &&
        ! grep -qE '^[[:space:]]*no-autostart([[:space:]]|$)' "$tmp" 2>/dev/null; then
        echo "no-autostart" >>"$tmp"
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst" 2>/dev/null || rm -f "$tmp"
}

# True when GPG_RELAY_DIR is a safe location to manage relays in: inside the
# wrapper's config dir (anywhere in test mode, where tests use a scratch dir).
# Usage: relay_dir_ok && ...
relay_dir_ok() {
    case "$GPG_RELAY_DIR" in
    / | "") return 1 ;;
    "$CONFIG_DIR"/*) return 0 ;;
    esac
    [ "${PI_DOCKERIZED_TEST:-}" = 1 ]
}

# True when a directory is one start_gpg_relay created: named after a PID and
# holding nothing but its `pid` file and `relay.sock`. Anything else is left
# alone, so a misconfigured relay dir can never cost unrelated files.
# Usage: is_relay_entry <dir>
is_relay_entry() {
    local d="$1" f
    [ -d "$d" ] && [ ! -L "$d" ] || return 1
    [[ "$(basename "$d")" =~ ^[0-9]+$ ]] || return 1
    for f in "$d"/* "$d"/.[!.]*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "$(basename "$f")" in
        pid | relay.sock) ;;
        *) return 1 ;;
        esac
    done
    return 0
}

# Remove one relay directory start_gpg_relay created: its two files, then the
# directory itself (never a recursive delete).
# Usage: remove_relay_entry <dir>
remove_relay_entry() {
    local d="$1"
    is_relay_entry "$d" || return 0
    rm -f "$d/pid" "$d/relay.sock" 2>/dev/null || true
    rmdir "$d" 2>/dev/null || true
}

# Remove relay directories of sessions that are gone (crash, kill -9). An
# entry is live while the wrapper that created it (its name) or its socat is
# running: judging by the socat PID alone deleted a concurrent session's relay
# in the window before that PID was written. Runs before starting a new relay,
# only with GnuPG forwarding on.
# Usage: cleanup_stale_relays
cleanup_stale_relays() {
    [ "$GPG_AGENT_SUPPORT" = true ] || return 0
    relay_dir_ok || return 0
    [ -d "$GPG_RELAY_DIR" ] && [ ! -L "$GPG_RELAY_DIR" ] || return 0
    local d pid
    for d in "$GPG_RELAY_DIR"/*; do
        is_relay_entry "$d" || continue
        session_entry_alive "$d" && continue
        pid=$(cat "$d/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        remove_relay_entry "$d"
    done
}

# Relay a GnuPG agent socket through a socket on a normal filesystem so Docker
# can bind it. One process per session; the wrapper stops it when the container
# exits. Uses `socat` by default; GPG_RELAY_CMD overrides the command for tests
# (only with PI_DOCKERIZED_TEST=1; see test_seam)
# (it receives RELAY_SOCK and RELAY_REAL in its environment).
# Usage: relay_socket=$(start_gpg_relay <real_socket>)
start_gpg_relay() {
    local real="$1"
    [ -n "$real" ] && [ -S "$real" ] || return 1
    relay_dir_ok || return 1

    local template
    template=$(test_seam GPG_RELAY_CMD)
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
    # unique per live process; an entry already carrying it is a stale one from
    # an earlier process that had the same PID, so it is replaced.
    local dir sock pid i
    dir="$GPG_RELAY_DIR/$$"
    sock="$dir/relay.sock"
    if [ "${#sock}" -ge 108 ]; then
        config_warning "GPG relay path too long for a Unix socket (${#sock} chars); skipping relay"
        return 1
    fi
    remove_relay_entry "$dir"
    mkdir "$dir" 2>/dev/null || return 1
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
    remove_relay_entry "$dir"
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
    remove_relay_entry "$dir"
}
