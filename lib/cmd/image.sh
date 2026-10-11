#!/bin/bash

# image.sh - the Docker image lifecycle: build, pull, roll back, remove, inspect.
# Sourced by bin/pi-dockerized (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# A new image is never tagged `latest` blindly: it is built under a candidate
# tag, smoke-tested, and only then promoted. The image it replaces is kept as
# `:previous` so `rollback` can undo a bad update, and every build also gets a
# `<wrapper>-guard<N>` tag so versions stay identifiable.

IMAGE_REPO="${IMAGE_NAME%%:*}"
REGISTRY_IMAGE="${PI_DOCKERIZED_REGISTRY_IMAGE:-ghcr.io/yukiteruamano/pi-dockerized}"
GUARD_DIR_IN_IMAGE="/home/coder/.pi/agent/extensions/pi-security-guard"

# Value of one label on an image ("" when the image or label is missing).
# Usage: image_label <image> <label>
image_label() {
    docker image inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true
}

# Warn when the image no longer matches this checkout: built by another wrapper
# release (stale scripts/guard), or without the Docker CLI while the socket is on.
check_image_drift() {
    local built
    built=$(image_label "$IMAGE_NAME" org.opencontainers.image.version)
    if [ -z "$built" ]; then
        print_warning "The image has no version label (built by an older wrapper): run '$0 build'."
    elif [ "$built" != "$WRAPPER_VERSION" ]; then
        print_warning "The image was built by wrapper $built but this is $WRAPPER_VERSION: run '$0 build'."
    fi
    if [ "$DOCKER_SOCKET" = true ] &&
        [ "$(image_label "$IMAGE_NAME" pi-dockerized.docker-cli)" = false ]; then
        print_warning "setting.docker_socket is on but the image has no Docker CLI: run '$0 build'."
    fi
}

# Boot checks run inside a freshly built or pulled image before it is promoted:
# Pi must report a real version, the guard's own self-test must pass, and the
# baked diagnostics must be present.
# shellcheck disable=SC2016 # expanded inside the container, not here
SMOKE_SCRIPT='
v=$(pi --version 2>&1 | tail -n 1)
if [ -z "$v" ] || [ "$v" = "0.0.0" ]; then echo "pi reports version [$v]"; exit 1; fi
node /home/coder/.pi/agent/extensions/pi-security-guard/selftest.mjs || exit 1
test -x /usr/local/lib/pi-dockerized/doctor.sh || { echo "doctor.sh is missing"; exit 1; }
echo "$v"
'

# Usage: smoke_test_image <image>
smoke_test_image() {
    local image="$1" out
    if ! out=$(docker run --rm --entrypoint bash "$image" -c "$SMOKE_SCRIPT" 2>&1); then
        print_error "Smoke test failed for $image:"
        printf '%s\n' "$out" >&2
        return 1
    fi
    print_success "Smoke test passed (pi $(printf '%s' "$out" | tail -n 1))"
}

# Tag identifying this build: <wrapper version>-guard<guard version>.
# Usage: image_version_tag <image>
image_version_tag() {
    local guard
    guard=$(docker run --rm --entrypoint node "$1" "$GUARD_DIR_IN_IMAGE/selftest.mjs" --version 2>/dev/null | tail -n 1)
    printf '%s-guard%s' "$WRAPPER_VERSION" "${guard:-0}"
}

# Make a tested image the current one, keeping the one it replaces.
# Usage: promote_image <tag-or-ref>
promote_image() {
    local candidate="$1" vtag
    vtag=$(image_version_tag "$candidate")
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        docker tag "$IMAGE_NAME" "$IMAGE_REPO:previous"
    fi
    docker tag "$candidate" "$IMAGE_NAME"
    docker tag "$candidate" "$IMAGE_REPO:$vtag"
    # Drops only the candidate's own tag; the image lives on under the others.
    docker rmi "$candidate" >/dev/null 2>&1 || true
    print_success "Image ready: $IMAGE_NAME (also $IMAGE_REPO:$vtag; the replaced one is $IMAGE_REPO:previous)"
}

# Build the image, smoke-test it and promote it.
# Usage: build_image [--pi-version X|latest] [--bust-cache]
build_image() {
    local pi_version="" bust=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --pi-version)
            pi_version="${2:?--pi-version needs a value}"
            shift
            ;;
        --bust-cache) bust=true ;;
        *)
            print_error "Unknown build option: $1"
            return 1
            ;;
        esac
        shift
    done

    parse_config
    # The Docker CLI is only useful with the socket mounted; leave it out of the
    # image otherwise (less to patch, less to abuse).
    local cli=false
    [ "$DOCKER_SOCKET" = true ] && cli=true

    local candidate="$IMAGE_REPO:candidate-$$" revision
    revision=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
    local -a args=(
        --build-arg "WRAPPER_VERSION=$WRAPPER_VERSION"
        --build-arg "VCS_REF=$revision"
        --build-arg "INSTALL_DOCKER_CLI=$cli"
    )
    [ -n "$pi_version" ] && args+=(--build-arg "PI_VERSION=$pi_version")
    # Only `update` busts the cache, so the requested Pi release is re-fetched.
    [ "$bust" = true ] && args+=(--build-arg "PI_BUILD_TIME=$(date +%s)")

    print_info "Building Pi Docker image..."
    if ! docker build "${args[@]}" -t "$candidate" "$REPO_ROOT"; then
        print_error "Docker build failed; the current image was left untouched."
        return 1
    fi
    if ! smoke_test_image "$candidate"; then
        docker rmi "$candidate" >/dev/null 2>&1 || true
        print_error "The new image failed its smoke test and was discarded; the current image was left untouched."
        return 1
    fi
    promote_image "$candidate"
}

# Fetch the prebuilt image from the registry, verify its signature and promote
# it. The signature is checked against the digest that was actually pulled, so
# a tag that moves in between cannot swap the image.
# Usage: pull_image [TAG] [--no-verify]
pull_image() {
    local tag="" verify=true
    while [ $# -gt 0 ]; do
        case "$1" in
        --no-verify) verify=false ;;
        -*)
            print_error "Unknown pull option: $1"
            return 1
            ;;
        *) tag="$1" ;;
        esac
        shift
    done
    tag="${tag:-v$WRAPPER_VERSION}"
    local ref="$REGISTRY_IMAGE:$tag"

    if [ "$verify" = true ] && ! command -v cosign >/dev/null 2>&1; then
        print_error "cosign is required to verify the image signature (install it, or pass --no-verify)."
        return 1
    fi

    print_info "Pulling $ref ..."
    docker pull "$ref" || return 1

    if [ "$verify" = true ]; then
        local digest_ref
        digest_ref=$(docker image inspect --format '{{ index .RepoDigests 0 }}' "$ref" 2>/dev/null)
        if [ -z "$digest_ref" ] || ! cosign verify \
            --certificate-identity-regexp '^https://github.com/yukiteruamano/pi-dockerized/\.github/workflows/' \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com \
            "$digest_ref" >/dev/null 2>&1; then
            docker rmi "$ref" >/dev/null 2>&1 || true
            print_error "Signature verification failed for $ref; the image was discarded."
            return 1
        fi
        print_success "Signature verified ($digest_ref)"
    else
        print_warning "Signature NOT verified (--no-verify)."
    fi

    if ! smoke_test_image "$ref"; then
        docker rmi "$ref" >/dev/null 2>&1 || true
        return 1
    fi
    promote_image "$ref"
}

# Point `latest` back at the image the last build/pull replaced.
rollback_image() {
    if ! docker image inspect "$IMAGE_REPO:previous" >/dev/null 2>&1; then
        print_error "There is no previous image to roll back to."
        return 1
    fi
    docker tag "$IMAGE_REPO:previous" "$IMAGE_NAME"
    print_success "Rolled back $IMAGE_NAME to the previous image."
}

# Remove every local tag of the image (latest, previous, version tags).
clean_image() {
    # Drop any relay processes/dirs left by crashed sessions.
    cleanup_stale_relays
    if relay_dir_ok; then
        rm -rf "$GPG_RELAY_DIR" 2>/dev/null || true
    fi
    local -a tags=()
    local tag
    while IFS= read -r tag; do
        [ -n "$tag" ] && [[ "$tag" != *"<none>"* ]] && tags+=("$tag")
    done < <(docker image ls "$IMAGE_REPO" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
    if [ "${#tags[@]}" -eq 0 ]; then
        print_info "No '$IMAGE_REPO' images to remove"
        return 0
    fi
    print_info "Removing Docker images: ${tags[*]}"
    docker rmi "${tags[@]}"
    print_success "Docker images removed"
}

# Wrapper, image, guard, policy-set and Pi versions at a glance.
show_version() {
    check_image "$IMAGE_NAME" || exit 1
    local built info line guard="" policies="" pi=""
    built=$(image_label "$IMAGE_NAME" org.opencontainers.image.version)
    # shellcheck disable=SC2016 # expanded inside the container, not here
    info=$(docker run --rm --entrypoint bash "$IMAGE_NAME" -c '
        d=/home/coder/.pi/agent/extensions/pi-security-guard
        printf "guard=%s\npolicies=%s\npi=%s\n" \
            "$(node "$d/selftest.mjs" --version 2>/dev/null)" \
            "$(cat "$d/policies/VERSION" 2>/dev/null)" \
            "$(pi --version 2>&1 | tail -n 1)"
    ')
    while IFS= read -r line; do
        case "$line" in
        guard=*) guard="${line#guard=}" ;;
        policies=*) policies="${line#policies=}" ;;
        pi=*) pi="${line#pi=}" ;;
        esac
    done <<<"$info"
    echo "pi-dockerized $WRAPPER_VERSION (image ${built:-unknown}, guard ${guard:-unknown}, policies ${policies:-unknown})"
    echo "pi ${pi:-unknown}"
}
