#!/bin/bash
# Compat shim: the binary moved to bin/pi-dockerized (no symlink in ~/.local/bin).
set -e
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
echo "pi-dockerized.sh is deprecated; use 'pi-dockerized' on PATH (bin/pi-dockerized)" >&2
exec "$ROOT/bin/pi-dockerized" "$@"
