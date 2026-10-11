#!/bin/bash
# In-container provider credential check for `pi-dockerized auth`. Pi has no
# `auth login` subcommand (interactive login happens through the TUI `/login`);
# credentials are supplied as provider API keys through the secrets file. This
# only reports whether the keys in the environment resolve to a usable
# credential. Baked into the image (/usr/local/lib/pi-dockerized/).

status=0
found=0

echo "== provider credentials =="

check() {
    provider="$1"
    var="$2"
    [ -n "${!var:-}" ] || return 0
    found=1
    printf "%s: " "$var"
    if pi auth check --provider "$provider" >/dev/null 2>&1; then
        echo "ready ($provider)"
    else
        echo "not ready ($provider)"
        status=1
    fi
}

check anthropic ANTHROPIC_API_KEY
check openai OPENAI_API_KEY
check google GEMINI_API_KEY
check google GOOGLE_API_KEY

if [ "$found" -eq 0 ]; then
    echo "No provider API keys found in the container environment."
    echo "Set them in setting.env_file (e.g. ANTHROPIC_API_KEY=...) and re-run."
    status=1
fi
exit "$status"
