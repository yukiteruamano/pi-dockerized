#!/bin/bash

# Alternative simple runner for Pi Docker.
# Delegates to bin/pi-dockerized so there is a single code path.
# DEPRECATED: `pi-dockerized run` does the same; this script will be removed
# in v1.0.

set -e

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMAGE_NAME="pi-dockerized:latest"

# Source the shared config module (provides colors, logging, config functions)
# shellcheck source=lib/config-lib.sh
source "$ROOT/lib/config-lib.sh"

# Refuse to run as root: the wrapper maps the invoking user into the container,
# and building the image as root would create root-owned layers.
if [ "$(id -u)" -eq 0 ]; then
    config_error "Do not run this script as root."
    exit 1
fi

echo "run-simple.sh is deprecated and will be removed in v1.0; use 'pi-dockerized run'" >&2

# Show help if requested
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
    cat << EOF
Pi Docker Simple Runner

Usage: $(basename "$0") [DIR]

Runs Pi in a Docker container with a simplified setup.
Delegates to 'pi-dockerized run', so it shares the full feature set.

Arguments:
    DIR     Project directory to mount (default: current directory)

Options:
    --help, -h    Show this help message

For the full command set, use pi-dockerized instead.
EOF
    exit 0
fi

# Get project directory (default to current directory)
PROJECT_DIR="${1:-$(pwd)}"

# Validate project directory exists
if [ ! -d "$PROJECT_DIR" ]; then
    config_error "Project directory does not exist: $PROJECT_DIR"
    exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

# Build the image if it doesn't exist (the main runner expects it to exist)
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    config_info "Docker image not found, building..."
    "$ROOT/bin/pi-dockerized" build || exit 1
fi

# Single code path: hand off to the main runner
exec "$ROOT/bin/pi-dockerized" run "$PROJECT_DIR"
