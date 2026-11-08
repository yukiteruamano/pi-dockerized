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
    local created created_epoch now age_days
    created=$(image_label "$IMAGE_NAME" org.opencontainers.image.created)
    if [ -n "$created" ] && [ "$created" != "<no value>" ]; then
        now=$(date +%s)
        if created_epoch=$(date -d "$created" +%s 2>/dev/null) && [ "$now" -gt "$created_epoch" ]; then
            age_days=$(((now - created_epoch) / 86400))
            if [ "$age_days" -gt 90 ]; then
                print_warning "The image is $age_days days old (built $created): run '$0 build' to pick up base-image security fixes."
            fi
        fi
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
# The guard must be root-owned and out of reach of the image user (uid 1000,
# the usual host uid); smoke_test_image repeats this for another uid.
/usr/local/lib/pi-dockerized/lock-check.sh || { echo "the security guard is not locked"; exit 1; }
test -x /usr/local/lib/pi-dockerized/doctor.sh || { echo "doctor.sh is missing"; exit 1; }
test -x /usr/local/lib/pi-dockerized/ext-install.sh && test -f /usr/local/lib/pi-dockerized/ext-agent.mjs || { echo "ext-install.sh/ext-agent.mjs missing"; exit 1; }
# The official Pi must read a seeded ext-agent directory, and the seed must keep
# the sandbox keys: this is what `extensions install` and every session rely on.
d=$(mktemp -d)
node /usr/local/lib/pi-dockerized/ext-agent.mjs seed "$d" >/dev/null || { echo "ext-agent seed failed"; exit 1; }
node /usr/local/lib/pi-dockerized/ext-agent.mjs check "$d/settings.json" || exit 1
PI_CODING_AGENT_DIR="$d" pi list >/dev/null 2>&1 || { echo "pi list fails on a seeded ext-agent directory"; exit 1; }
# Sandbox invariants: no privilege escalation binary, and a host settings.json
# carrying anything but preferences must be rejected.
command -v sudo >/dev/null 2>&1 && { echo "sudo must not exist in the image"; exit 1; }
d2=$(mktemp -d)
node /usr/local/lib/pi-dockerized/ext-agent.mjs seed "$d2" >/dev/null || { echo "ext-agent seed failed"; exit 1; }
jq ". + {piDockerizedEvil: true}" "$d2/settings.json" > "$d2/loose.json" && mv "$d2/loose.json" "$d2/settings.json"
node /usr/local/lib/pi-dockerized/ext-agent.mjs check "$d2/settings.json" --host >/dev/null 2>&1 && { echo "loose host settings accepted"; exit 1; }
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
    # Sessions run as the host uid, which is not always the image's 1000: the
    # guard must also be locked for any other uid in the coder group.
    local lock_out
    if ! lock_out=$(docker run --rm --user 4242:4242 --group-add coder \
        --entrypoint /usr/local/lib/pi-dockerized/lock-check.sh "$image" 2>&1); then
        print_error "Smoke test failed for $image (uid 4242):"
        printf '%s\n' "$lock_out" >&2
        return 1
    fi
    print_success "Smoke test passed (pi $(printf '%s' "$out" | tail -n 1))"
}

# Guard version baked into an image ("" when it cannot be read).
# Usage: image_guard_version <image>
image_guard_version() {
    docker run --rm --entrypoint node "$1" "$GUARD_DIR_IN_IMAGE/selftest.mjs" --version 2>/dev/null |
        tail -n 1 | tr -cd '0-9'
}

# Guard version of this checkout (GUARD_VERSION in policy.mjs; "" if unreadable).
checkout_guard_version() {
    sed -n 's/^export const GUARD_VERSION = \([0-9][0-9]*\);.*/\1/p' \
        "$REPO_ROOT/extensions/pi-security-guard/policy.mjs" 2>/dev/null | head -n 1
}

# Image ID of a local image ("" when missing).
# Usage: image_id <image>
image_id() {
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

# True when version $1 is strictly lower than $2 (x.y.z, `sort -V` order).
# Usage: version_lt <a> <b>
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

# Refuse an image older than what is in use: its wrapper version below the
# current image's or this checkout's, or its guard below theirs. A pulled tag
# can be any old signed release, and promoting it would silently bring back a
# weaker guard and older policies.
# Usage: check_not_downgrade <image>
check_not_downgrade() {
    local image="$1" new_ver new_guard cur_ver cur_guard floor_ver floor_guard
    new_ver=$(image_label "$image" org.opencontainers.image.version)
    new_guard=$(image_guard_version "$image")
    if ! [[ "$new_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ -z "$new_guard" ]; then
        print_error "Cannot tell the version of $image (wrapper '${new_ver:-?}', guard '${new_guard:-?}')."
        return 1
    fi
    floor_ver="$WRAPPER_VERSION"
    floor_guard=$(checkout_guard_version)
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        cur_ver=$(image_label "$IMAGE_NAME" org.opencontainers.image.version)
        cur_guard=$(image_guard_version "$IMAGE_NAME")
        if [[ "$cur_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_lt "$floor_ver" "$cur_ver"; then
            floor_ver="$cur_ver"
        fi
        if [ -n "$cur_guard" ] && { [ -z "$floor_guard" ] || [ "$cur_guard" -gt "$floor_guard" ]; }; then
            floor_guard="$cur_guard"
        fi
    fi
    if version_lt "$new_ver" "$floor_ver"; then
        print_error "$image is wrapper $new_ver, older than $floor_ver (current image / this checkout)."
        return 1
    fi
    if [ -n "$floor_guard" ] && [ "$new_guard" -lt "$floor_guard" ]; then
        print_error "$image carries guard $new_guard, older than guard $floor_guard (current image / this checkout)."
        return 1
    fi
    return 0
}

# Tag identifying this build: <wrapper version>-guard<guard version>.
# Usage: image_version_tag <image>
image_version_tag() {
    local guard version
    guard=$(image_guard_version "$1")
    # A pulled image carries its own release; a local build is this wrapper's.
    version=$(image_label "$1" org.opencontainers.image.version)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || version="$WRAPPER_VERSION"
    printf '%s-guard%s' "$version" "${guard:-0}"
}

# Best-effort local SBOM for the promoted image (CI already publishes one
# for prebuilt images). Never fails the build: old Docker versions lack it.
# Usage: write_sbom <image>
write_sbom() {
    local image="$1" sbom_dir="$PI_HOME/sbom" out
    command -v docker >/dev/null 2>&1 || return 0
    mkdir -p "$sbom_dir" 2>/dev/null || return 0
    out="$sbom_dir/$(echo "$image" | tr -cd '[:alnum:]._-').spdx.json"
    if docker sbom --format spdx-json -o "$out" "$image" >/dev/null 2>&1; then
        print_info "SBOM written to $out"
    else
        print_info "SBOM skipped (docker sbom unavailable)"
    fi
}

# Make a tested image the current one, keeping the one it replaces.
# Usage: promote_image <tag-or-ref>
promote_image() {
    local candidate="$1" vtag cur_id new_id
    vtag=$(image_version_tag "$candidate")
    cur_id=$(image_id "$IMAGE_NAME")
    new_id=$(image_id "$candidate")
    # Re-promoting the image already in use (same pull twice, a no-op rebuild)
    # must not overwrite :previous with it, or the real previous image is lost.
    if [ -n "$cur_id" ] && [ "$cur_id" = "$new_id" ]; then
        print_info "$IMAGE_NAME is already this image; $IMAGE_REPO:previous left as it was."
    elif docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        docker tag "$IMAGE_NAME" "$IMAGE_REPO:previous"
    fi
    docker tag "$candidate" "$IMAGE_NAME"
    docker tag "$candidate" "$IMAGE_REPO:$vtag"
    # Drops only the candidate's own tag; the image lives on under the others.
    docker rmi "$candidate" >/dev/null 2>&1 || true
    print_success "Image ready: $IMAGE_NAME (also $IMAGE_REPO:$vtag; the replaced one is $IMAGE_REPO:previous)"
    write_sbom "$IMAGE_NAME"
}

# Build the image, smoke-test it and promote it.
# Usage: build_image [--pi-version X|latest] [--bust-cache] [--fresh]
build_image() {
    local pi_version="" bust=false fresh=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --pi-version)
            pi_version="${2:?--pi-version needs a value}"
            shift
            ;;
        --bust-cache) bust=true ;;
        --fresh) fresh=true ;;
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
    # Build timestamp as an OCI label so check_image_drift can warn about
    # stale base images (kept out of the Dockerfile to avoid busting its cache).
    args+=(--label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    # Only `update` busts the cache, so the requested Pi release is re-fetched.
    # --fresh also pulls a newer base image instead of reusing cached layers.
    [ "$bust" = true ] && args+=(--build-arg "PI_BUILD_TIME=$(date +%s)")
    [ "$fresh" = true ] && args+=(--pull)

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

# Release images are signed by the publish workflow (image.yml) running on a
# version tag; nothing else in the repository (another workflow, a branch run)
# may vouch for an image.
COSIGN_IDENTITY_REGEXP='^https://github\.com/yukiteruamano/pi-dockerized/\.github/workflows/image\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'

# Fetch the prebuilt image from the registry, verify its signature and promote
# it. The signature is checked against the digest that was actually pulled, so
# a tag that moves in between cannot swap the image. An image older than the
# current one or this checkout (wrapper or guard version) is refused unless
# --allow-downgrade is given.
# Usage: pull_image [TAG] [--no-verify] [--allow-downgrade]
pull_image() {
    local tag="" verify=true allow_downgrade=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --no-verify) verify=false ;;
        --allow-downgrade) allow_downgrade=true ;;
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
            --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
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
    if ! check_not_downgrade "$ref"; then
        if [ "$allow_downgrade" != true ]; then
            docker rmi "$ref" >/dev/null 2>&1 || true
            print_error "Refusing to downgrade; the image was discarded (pass --allow-downgrade to force it)."
            print_info "To run this checkout's guard, build the image locally: '$0 build'."
            return 1
        fi
        print_warning "Downgrading the image (--allow-downgrade)."
    fi
    promote_image "$ref"
}

# Point `latest` back at the image the last build/pull replaced. The image it
# replaces becomes the new `:previous`, so a second rollback undoes the first.
rollback_image() {
    if ! docker image inspect "$IMAGE_REPO:previous" >/dev/null 2>&1; then
        print_error "There is no previous image to roll back to."
        return 1
    fi
    local cur_id prev_id
    cur_id=$(image_id "$IMAGE_NAME")
    prev_id=$(image_id "$IMAGE_REPO:previous")
    if [ -n "$cur_id" ] && [ "$cur_id" = "$prev_id" ]; then
        print_info "$IMAGE_NAME already is the previous image; nothing to roll back."
        return 0
    fi
    docker tag "$IMAGE_REPO:previous" "$IMAGE_NAME"
    if [ -n "$cur_id" ]; then
        docker tag "$cur_id" "$IMAGE_REPO:previous"
    fi
    print_success "Rolled back $IMAGE_NAME to the previous image (the replaced one is now $IMAGE_REPO:previous)."
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
    check_image "$IMAGE_NAME" || exit "$E_DOCKER"
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
