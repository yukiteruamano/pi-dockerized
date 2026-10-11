#!/bin/bash
# Bootstrap installer: clone (or reuse) the self-contained checkout at
# ${XDG_DATA_HOME:-$HOME/.local/share}/pi-dockerized, then run the
# built-in `pi-dockerized install` wizard. bin/ holds only the
# `pi-dockerized` binary; there is no second `install` binary.
# Doom-style one-liner (does everything: download, config, PATH, completions,
# aliases — no second manual install needed):
#   curl -fsSL https://raw.githubusercontent.com/yukiteruamano/pi-dockerized/master/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --yes --only config,completions,aliases,global
# Override the source with PI_REPO_URL, the target with PI_INSTALL_DIR.
set -e

REPO_URL="${PI_REPO_URL:-https://github.com/yukiteruamano/pi-dockerized.git}"
INSTALL_DIR="${PI_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/pi-dockerized}"

# Forwarded install args. A piped `curl | bash` has no TTY for prompts, so
# default to --yes (full setup) unless the caller already passed --yes or
# asks for help. Explicit `bash -s -- --yes ...` keeps working.
FORWARD_ARGS=("$@")
_has_yes=false
_has_help=false
for _a in "$@"; do
    case "$_a" in
    --yes) _has_yes=true ;;
    -h | --help) _has_help=true ;;
    esac
done
if [ "$_has_help" = false ] && [ "$_has_yes" = false ] && [ ! -t 0 ]; then
    FORWARD_ARGS=(--yes "$@")
fi
unset _a _has_yes _has_help

# Running from a local checkout (./install.sh): use it directly, no cloning.
# When piped via curl BASH_SOURCE is empty/a pipe, so skip this branch.
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
OWN_ROOT=""
if [ -n "$SCRIPT_SRC" ] && [ -f "$SCRIPT_SRC" ]; then
    OWN_ROOT="$(cd "$(dirname "$(readlink -f "$SCRIPT_SRC" 2>/dev/null || dirname "$SCRIPT_SRC")")" && pwd)"
fi
if [ -n "$OWN_ROOT" ] && [ -x "$OWN_ROOT/bin/pi-dockerized" ]; then
    exec "$OWN_ROOT/bin/pi-dockerized" install "${FORWARD_ARGS[@]}"
fi
unset SCRIPT_SRC OWN_ROOT

if [ -d "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "error: $INSTALL_DIR exists and is not a git checkout (remove it or set PI_INSTALL_DIR)" >&2
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
    if ! command -v git >/dev/null 2>&1; then
        echo "error: git is required to install pi-dockerized" >&2
        exit 1
    fi
    echo "Cloning pi-dockerized into $INSTALL_DIR ..."
    git clone "$REPO_URL" "$INSTALL_DIR"
elif command -v git >/dev/null 2>&1; then
    # Reused checkout. Manual checkouts (init + remote add) lack an upstream
    # branch, which breaks `update`/`upgrade` and the fast-forward below: fix
    # that first with the same helper the wizard uses. Best-effort throughout.
    if [ -f "$INSTALL_DIR/lib/config-lib.sh" ] && [ -f "$INSTALL_DIR/lib/install-lib.sh" ]; then
        # shellcheck source=/dev/null
        (source "$INSTALL_DIR/lib/config-lib.sh" && source "$INSTALL_DIR/lib/install-lib.sh" &&
            ensure_git_upstream "$INSTALL_DIR") || true
    fi
    # Best-effort fast-forward so curl always installs latest.
    if git -C "$INSTALL_DIR" fetch origin >/dev/null 2>&1; then
        _lr=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || true)
        _rr=$(git -C "$INSTALL_DIR" rev-parse '@{u}' 2>/dev/null || true)
        _base=$(git -C "$INSTALL_DIR" merge-base HEAD '@{u}' 2>/dev/null || true)
        if [ -n "$_lr" ] && [ -n "$_rr" ] && [ "$_lr" != "$_rr" ] && [ "$_lr" = "$_base" ]; then
            git -C "$INSTALL_DIR" pull --ff-only >/dev/null 2>&1 || echo "warning: could not pull latest changes in $INSTALL_DIR" >&2
        fi
        unset _lr _rr _base
    fi
fi

if [ ! -x "$INSTALL_DIR/bin/pi-dockerized" ]; then
    echo "error: $INSTALL_DIR/bin/pi-dockerized not found or not executable" >&2
    exit 1
fi

exec "$INSTALL_DIR/bin/pi-dockerized" install "${FORWARD_ARGS[@]}"
