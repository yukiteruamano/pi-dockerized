#!/bin/bash
set -e

# This script runs as a non-root user. There is no privilege dropping and no
# UID/GID remapping: the wrapper starts the container with
# `--user <host uid>:<host gid>`, so every process already runs as the host
# user. Docker socket access is granted at run time with `--group-add`
# (see config-lib.sh), not by editing /etc/group here.

# Resolve the project working directory (set by bin/pi-dockerized via
# PI_WORKDIR). Falls back to the container's Docker --workdir ($PWD) so
# one-off CLI commands that only pass --workdir still run in the project.
# Exported (not interpolated into the command string) so paths containing quotes
# or shell metacharacters are safe.
WORKDIR="${PI_WORKDIR:-$PWD}"
export WORKDIR

# Set HOME explicitly to ensure it points to /home/coder
export HOME=/home/coder
export USER=coder

# Ensure user-installed CLIs are on PATH for Pi and every process it spawns.
# Kept explicit here so it holds even if the image PATH changes.
export PATH="/home/coder/.local/bin:$PATH"

# Node.js is on PATH through the image's $NVM_DIR/default symlink; NVM itself is
# only sourced below when that is not the case.
export NVM_DIR="/home/coder/.nvm"

# Pi reads its agent directory from this variable (set by the image; re-assert
# the default so one-off commands still resolve it).
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-/home/coder/.pi/agent}"

# With GnuPG agent forwarding, start the local keyboxd so gpg can read the
# mirrored public keyring (public-keys.d/). The mirrored gpg.conf sets
# no-autostart, which only blocks on-demand autostart, not this explicit launch;
# the private-key operations still go to the host agent via the mounted socket.
# Best-effort: never block the container on it.
if [ -n "${GNUPGHOME:-}" ] && command -v gpgconf >/dev/null 2>&1; then
    gpgconf --launch keyboxd >/dev/null 2>&1 || true
fi

# Fail closed: refuse to start when the security guard is damaged (missing or
# empty pattern files, a canary call judged wrongly). The baked diagnostics
# skip it so `pi-dockerized doctor` can still run and report what is wrong.
GUARD_DIR="${PI_CODING_AGENT_DIR}/extensions/pi-security-guard"
case "${1:-}" in
/usr/local/lib/pi-dockerized/*) ;;
*)
    # The settings in effect are the host's settings.json (preferences only) or,
    # with Pi Packages, the ext-agent file. Either way the security keys must be
    # the sandbox's; the host file must also hold nothing but preferences. Unset
    # means the stricter host rules.
    check_args=(check "${PI_CODING_AGENT_DIR}/settings.json")
    if [ "${PI_DOCKERIZED_SETTINGS_SOURCE:-host}" = host ]; then
        check_args+=(--host)
    fi
    if ! node /usr/local/lib/pi-dockerized/ext-agent.mjs "${check_args[@]}"; then
        echo "pi-dockerized: the Pi settings loosen the sandbox; refusing to start." >&2
        echo "Fix the host settings.json (home/.pi/agent/, or ext-agent/ with Pi Packages), or remove it to get the defaults." >&2
        exit 5 # E_GUARD: security-guard refusal (stable code, see lib/config/core.sh)
    fi
    if ! node "$GUARD_DIR/selftest.mjs"; then
        echo "pi-dockerized: the security guard failed its self-test; refusing to start." >&2
        echo "Rebuild the image ('pi-dockerized build') and run 'pi-dockerized doctor'." >&2
        exit 5 # E_GUARD: security-guard refusal (stable code, see lib/config/core.sh)
    fi
    ;;
esac

# cd into the project working directory before executing. The script is single
# quoted so $WORKDIR is expanded by the child bash from the environment, not
# spliced into the command text. NVM is sourced only when node is not already
# on PATH (it is slow to load, and normally unnecessary).
exec bash -c 'command -v node >/dev/null 2>&1 || source "$NVM_DIR/nvm.sh"; cd "$WORKDIR" && exec "$@"' \
    -- "$@"
