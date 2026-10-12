#!/bin/bash
# In-container diagnostics for the security layer and agent-forwarding setup.
# Baked into the image (/usr/local/lib/pi-dockerized/) and run by
# `pi-dockerized doctor`. Read-only: it only reports what is actually usable and
# exits non-zero on a real failure.

status=0
note() { printf "%s\n" "$1"; }

agent="${PI_CODING_AGENT_DIR:-/home/coder/.pi/agent}"
guard_dir="$agent/extensions/pi-security-guard"

echo "== pi =="
pi --version 2>&1 || true

echo "== security guard =="
if [ -f "$guard_dir/selftest.mjs" ]; then
    note "guard version: $(node "$guard_dir/selftest.mjs" --version 2>&1)"
    note "policy mode: ${PI_DOCKERIZED_POLICY:-balanced}"
    if [ -f "$guard_dir/policies/VERSION" ]; then
        note "policy set version: $(cat "$guard_dir/policies/VERSION")"
    fi
    # The same boot check entrypoint.sh enforces: pattern files present and a
    # set of canary calls judged correctly by the real policy code.
    if selftest_out=$(node "$guard_dir/selftest.mjs" 2>&1); then
        note "self-test: passed"
    else
        note "self-test: FAILED"
        printf "%s\n" "$selftest_out"
        status=1
    fi
else
    note "MISSING security-guard extension"
    status=1
fi
if [ -f "$agent/allow.json" ]; then note "host allow rules: mounted (read-only)"; else note "host allow rules: none"; fi
if [ -w "$agent/audit.log" ]; then note "audit log: writable"; else note "audit log: not mounted (blocked calls are not recorded)"; fi

echo "== agent config =="
[ -f "$agent/settings.json" ] && note "settings.json: present" || { note "settings.json: MISSING"; status=1; }
if [ -f "$agent/mcp.json" ]; then
    if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$agent/mcp.json" >/dev/null 2>&1; then
        note "mcp.json: valid"
    else
        note "mcp.json: INVALID JSON"
        status=1
    fi
else
    note "mcp.json: MISSING"
    status=1
fi
if [ -w "$agent/skills" ]; then
    note "skills: WRITABLE (expected read-only)"
    status=1
else
    note "skills: read-only"
fi
if [ -w "$agent/extensions" ] || [ -w "$agent/settings.json" ]; then
    note "baked agent files: WRITABLE (expected read-only)"
    status=1
else
    note "baked agent files: read-only"
fi

echo "== pi packages =="
# The settings in effect keep the sandbox's security keys, whether they are the
# baked ones or the host's ext-agent file (the entrypoint enforces the same).
doctor_check=(check "$agent/settings.json")
if [ "${PI_DOCKERIZED_SETTINGS_SOURCE:-host}" = host ]; then doctor_check+=(--host); fi
if check_out=$(node /usr/local/lib/pi-dockerized/ext-agent.mjs "${doctor_check[@]}" 2>&1); then
    note "settings security keys: intact"
else
    note "settings security keys: BROKEN"
    printf "%s\n" "$check_out"
    status=1
fi
if [ -d "$agent/npm" ] || [ -d "$agent/git" ]; then
    note "host packages: mounted"
    if [ -w "$agent/npm" ] || [ -w "$agent/git" ] || [ -w "$agent/settings.json" ]; then
        note "host packages: WRITABLE (expected read-only)"
        status=1
    else
        note "host packages: read-only"
    fi
else
    note "host packages: none mounted (nothing installed, or an --untrusted session)"
fi
pi list 2>&1 || true

echo "== credentials =="
for v in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY; do
    if [ -n "${!v:-}" ]; then note "$v: present"; fi
done

echo "== self-update =="
if [ "${PI_SKIP_VERSION_CHECK:-}" = 1 ]; then
    note "version check: disabled"
else
    note "version check: ENABLED (expected PI_SKIP_VERSION_CHECK=1)"
    status=1
fi

echo "== ssh agent =="
if [ "${PI_DOCKERIZED_SSH_AGENT:-false}" != true ]; then
    note "ssh agent forwarding: disabled in wrapper config (skipped)"
elif [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    ssh-add -l 2>&1 || true
else
    note "SSH_AUTH_SOCK is unset or not a socket"
    status=1
fi

echo "== gnupg =="
if [ "${PI_DOCKERIZED_GPG_AGENT:-false}" != true ]; then
    note "gnupg forwarding: disabled in wrapper config (skipped)"
else
    gpg_home="${GNUPGHOME:-$HOME/.gnupg}"
    if [ -S "$gpg_home/S.gpg-agent" ]; then
        note "agent socket: ok"
    else
        note "agent socket: MISSING ($gpg_home/S.gpg-agent)"
        status=1
    fi
    if [ -f "$gpg_home/pubring.kbx" ] || [ -f "$gpg_home/public-keys.d/pubring.db" ]; then
        note "public keyring: ok"
    else
        note "public keyring: MISSING (signed commits will fail)"
        status=1
    fi
fi

echo "== env file =="
if [ "${PI_DOCKERIZED_ENV_FILE:-no}" = yes ]; then note "env file: loaded (--env-file)"; else note "env file: not configured"; fi

echo "== result =="
if [ "$status" -eq 0 ]; then note "all good"; else note "problems detected"; fi
exit "$status"
