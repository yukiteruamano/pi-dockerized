#!/bin/bash
# Checks that the session cannot change the baked security guard: every file of
# the guard and AGENTS.md is root-owned and not writable by the current user,
# and every directory from the guard up to / is root-owned and either not
# writable or sticky (in a writable directory without the sticky bit, a
# root-owned entry can still be renamed away and replaced). Prints the first
# offending path to stderr and exits 1; exits 0 when the lock holds.
# Baked into the image (/usr/local/lib/pi-dockerized/); run by entrypoint.sh
# (fail closed), doctor.sh (report) and the image smoke test.
# Usage: lock-check.sh [agent_dir]
set -e

agent="${1:-${PI_CODING_AGENT_DIR:-/home/coder/.pi/agent}}"
guard="$agent/extensions/pi-security-guard"

fail() {
    printf 'lock-check: %s\n' "$1" >&2
    exit 1
}

[ -d "$guard" ] || fail "security guard missing: $guard"
[ -f "$agent/AGENTS.md" ] || fail "AGENTS.md missing: $agent/AGENTS.md"
bad=$(find "$guard" "$agent/AGENTS.md" \( ! -user 0 -o -writable \) -print -quit) ||
    fail "cannot inspect $guard"
[ -z "$bad" ] || fail "not locked (not root-owned, or writable by uid $(id -u)): $bad"

dir="$guard"
while [ "$dir" != / ]; do
    dir=$(dirname "$dir")
    [ "$(stat -c %u "$dir")" = 0 ] || fail "directory not root-owned: $dir"
    if [ -w "$dir" ] && [ ! -k "$dir" ]; then
        fail "directory writable without the sticky bit: $dir"
    fi
done
exit 0
