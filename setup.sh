#!/bin/bash
# Compat shim: setup.sh moved to `pi-dockerized install` (lib/install-lib.sh).
set -e
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
echo "setup.sh is deprecated; use 'pi-dockerized install'" >&2
exec "$ROOT/bin/pi-dockerized" install "$@"
