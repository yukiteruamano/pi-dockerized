#!/bin/bash

# config-lib.sh - Shared configuration module for pi-dockerized
# This file is sourced by other scripts (not executed directly)
# Provides: config parsing, docker arg building, shared volume logic, and
# interactive prompts for running Pi (the earendil-works agent CLI) in a
# sandboxed container. The implementation lives in lib/config/*.sh, one
# responsibility per module; this file only loads them.

# NOTE: Do not use "set -e" here — this is a library file sourced by callers.
# Let calling scripts control their own error handling.

_CONFIG_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/config"

# core first: it defines the constants and logging the other modules rely on.
for _config_module in core mount-policy state gpg-ssh docker-args settings parse overrides prompts; do
    # shellcheck source=/dev/null
    source "$_CONFIG_LIB_DIR/$_config_module.sh"
done
unset _config_module
