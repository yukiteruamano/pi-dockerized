#!/bin/bash

# update.sh - self-update: `update` and `upgrade`.
# Sourced by bin/pi-dockerized (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# Both perform the full upgrade (git pull from GitHub + host-state sync + image
# rebuild). They differ only in prompting: `upgrade` asks before pulling when
# interactive, `update` pulls without asking. Both accept
# [--check] [--yes] [--no-build] [--verify] [--pi-version X].
#
# Pulling runs new code on the host, so the commits are listed before anything
# changes, and with --verify (or setting.verify_updates=true) the upstream head
# must carry a valid signature.

# Fetch upstream and, when the checkout is behind, show what would change.
# Returns 0 after pulling, 1 on error/abort/pending-check, 2 when up to date.
# Usage: _git_pull_wrapper <yes:true|false> <check_only:true|false> <verify:true|false>
_git_pull_wrapper() {
    local yes="$1" check_only="$2" verify="$3"
    if [ ! -d "$REPO_ROOT/.git" ]; then
        print_error "Not a git checkout ($REPO_ROOT); reinstall with install.sh to enable self-update."
        return 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        print_error "git is required for self-update."
        return 1
    fi
    if ! git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        print_error "No upstream tracking branch; set one with 'git branch --set-upstream-to=origin/<branch>'."
        return 1
    fi
    git -C "$REPO_ROOT" fetch origin >/dev/null 2>&1 || {
        print_error "Could not fetch from origin."
        return 1
    }
    local local_rev remote_rev base
    local_rev=$(git -C "$REPO_ROOT" rev-parse HEAD)
    remote_rev=$(git -C "$REPO_ROOT" rev-parse '@{u}')
    base=$(git -C "$REPO_ROOT" merge-base HEAD '@{u}')
    if [ "$local_rev" = "$remote_rev" ]; then
        print_success "Already up to date."
        return 2
    fi
    if [ "$local_rev" != "$base" ]; then
        print_error "Local checkout diverged from upstream; resolve manually with git (no --force pull attempted)."
        git -C "$REPO_ROOT" status -sb | head -5
        return 1
    fi
    local n
    n=$(git -C "$REPO_ROOT" rev-list --count HEAD..'@{u}')
    print_info "Update available: $n commit(s) behind upstream:"
    git -C "$REPO_ROOT" log --oneline --no-decorate -n 20 HEAD..'@{u}' | sed 's/^/    /'
    [ "$n" -gt 20 ] && echo "    ... and $((n - 20)) more"
    git -C "$REPO_ROOT" diff --stat HEAD..'@{u}' | tail -n 1 | sed 's/^/  /'
    if [ "$check_only" = true ]; then
        return 1
    fi
    if [ "$verify" = true ]; then
        if ! git -C "$REPO_ROOT" verify-commit "$remote_rev" >/dev/null 2>&1; then
            print_error "The upstream head ${remote_rev:0:12} has no valid signature; refusing to pull."
            print_info "Import the maintainer's key, or turn off setting.verify_updates / --verify."
            return 1
        fi
        print_success "Upstream head signature verified."
    fi
    if [ "$yes" != true ] && [ -t 0 ]; then
        local ans
        read -r -p "Pull $n commit(s)? (Y/n): " ans || ans=""
        case "${ans:-y}" in
        [Yy] | "") ;;
        *)
            print_info "Aborted."
            return 1
            ;;
        esac
    fi
    git -C "$REPO_ROOT" pull --ff-only || {
        print_error "Pull failed."
        return 1
    }
    print_success "Code updated to latest version."
    return 0
}

# Parse self-update flags shared by `update` and `upgrade`.
# Sets: _UP_CHECK, _UP_YES, _UP_NO_BUILD, _UP_VERIFY, _UP_PI_VERSION. Returns 0 on
# success/--help, 1 on bad usage. _UP_PI_VERSION stays empty unless given, so the
# image keeps the Dockerfile's pinned Pi release by default.
# Usage: _parse_self_update_flags <command-name> [flags...]
_parse_self_update_flags() {
    local cmd="$1"
    shift
    _UP_CHECK=false
    _UP_YES=false
    _UP_NO_BUILD=false
    _UP_VERIFY=false
    _UP_PI_VERSION=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --check) _UP_CHECK=true ;;
        --yes) _UP_YES=true ;;
        --no-build) _UP_NO_BUILD=true ;;
        --verify) _UP_VERIFY=true ;;
        --pi-version)
            if [ -z "${2:-}" ]; then
                print_error "--pi-version needs a value (latest or x.y.z)"
                return 1
            fi
            if ! [[ "$2" =~ ^(latest|v?[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?)$ ]]; then
                print_error "Invalid --pi-version '$2' (use latest or x.y.z)"
                return 1
            fi
            _UP_PI_VERSION="$2"
            shift
            ;;
        --help | -h)
            echo "Usage: $0 $cmd [--check] [--yes] [--no-build] [--verify] [--pi-version X]"
            echo "  --check            only report whether an update is available"
            echo "  --yes              pull and rebuild without asking"
            echo "  --no-build         pull + sync only, skip the image rebuild"
            echo "  --verify           require a valid signature on the upstream head"
            echo "  --pi-version X     Pi release to install: x.y.z or latest (default: the pinned one)"
            return 0
            ;;
        *)
            print_error "Unknown $cmd option: $1 (use --check|--yes|--no-build|--verify|--pi-version)"
            return 1
            ;;
        esac
        shift
    done
    return 0
}

# Full upgrade: git pull + host-state sync + image rebuild.
# Usage: full_upgrade <command-name> [--check] [--yes] [--no-build] [--verify] [--pi-version X]
full_upgrade() {
    local cmd="$1"
    shift
    _parse_self_update_flags "$cmd" "$@" || return $?
    case " $* " in
    *" --help "* | *" -h "*) return 0 ;;
    esac
    parse_config || true
    local verify=false
    if [ "$_UP_VERIFY" = true ] || [ "$VERIFY_UPDATES" = true ]; then
        verify=true
    fi

    if [ "$_UP_CHECK" = true ]; then
        local check_rc=0
        _git_pull_wrapper true true "$verify" || check_rc=$?
        [ "$check_rc" -eq 2 ] && return 0
        return 1
    fi
    local pull_rc=0
    # `update` never prompts (historic one-shot); `upgrade` prompts when tty.
    if [ "$cmd" = "update" ]; then
        _git_pull_wrapper true false "$verify" || pull_rc=$?
    else
        _git_pull_wrapper "$_UP_YES" false "$verify" || pull_rc=$?
    fi
    if [ "$pull_rc" -eq 1 ]; then
        return 1
    fi
    print_success "Refreshing host state..."
    parse_config --reload || true
    sync_pi_state || true
    if [ "$_UP_NO_BUILD" = true ]; then
        print_info "Skipping image rebuild (--no-build)."
        print_success "Upgrade complete (code + config synced, image untouched)."
        return 0
    fi
    check_docker || return 1
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        print_info "Current Pi version:"
        docker run --rm --entrypoint bash "$IMAGE_NAME" -c "pi --version" 2>/dev/null || true
    else
        print_info "Image not found, building fresh..."
    fi
    local -a build_args=(--bust-cache)
    [ -n "$_UP_PI_VERSION" ] && build_args+=(--pi-version "$_UP_PI_VERSION")
    build_image "${build_args[@]}" || return 1
    print_info "Updated Pi version:"
    docker run --rm --entrypoint bash "$IMAGE_NAME" -c "pi --version" 2>/dev/null || true
    print_success "Upgrade complete (code + config + image)."
}

# Self-update the wrapper checkout from GitHub (Doom-style `doom upgrade`).
# Usage: upgrade_wrapper [--check] [--yes] [--no-build] [--verify] [--pi-version X]
upgrade_wrapper() {
    full_upgrade upgrade "$@"
}

# Update Pi (full upgrade: git pull + sync + rebuild).
# Usage: update_pi [--check] [--yes] [--no-build] [--verify] [--pi-version X]
update_pi() {
    full_upgrade update "$@"
}
