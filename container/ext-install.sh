#!/bin/bash
# Runs the official `pi install|remove|update|list` for `pi-dockerized extensions`
# in a throwaway container whose PI_CODING_AGENT_DIR is the host's ext-agent
# directory (mounted read-write). Baked into the image, root-owned.
#
# Pi writes that directory's settings.json, and sessions later mount it in place
# of the baked one, so the security keys are seeded before and reapplied after
# every Pi command (see ext-agent.mjs): a package install can add packages, never
# loosen the sandbox.
#
# Usage: ext-install.sh <pi arguments...>   e.g. install npm:@scope/pkg@1.2.3

set -uo pipefail

LIB=/usr/local/lib/pi-dockerized
dir="${PI_CODING_AGENT_DIR:?PI_CODING_AGENT_DIR must point at the ext-agent directory}"

node "$LIB/ext-agent.mjs" seed "$dir" || exit 1

rc=0
pi "$@" || rc=$?

# Repair even when Pi failed half way: the file may have been rewritten.
node "$LIB/ext-agent.mjs" enforce "$dir" || rc=1
exit "$rc"
