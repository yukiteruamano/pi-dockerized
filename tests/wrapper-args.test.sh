#!/bin/bash
# Contract test for the wrapper's docker argument building and host-side Pi
# state. No Docker required: it sources config-lib.sh with an isolated
# HOME/CONFIG_DIR and asserts the resulting files and docker flags.
#
# Usage: bash tests/wrapper-args.test.sh
# shellcheck disable=SC2034  # globals below are consumed by sourced config-lib.sh functions

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export TMPDIR="${TMPDIR:-/tmp/pi}"
mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"
TMP="$(mktemp -d -p "$TMPDIR")"
trap 'rm -r "$TMP" 2>/dev/null || true' EXIT

# Sync tests run through sync_pi_state, which refuses to run inside containers
# (host-only); allow it here. A dedicated assertion below verifies the refusal
# without this override.
export PI_DOCKERIZED_ALLOW_CONTAINER_SYNC=1

fail() {
    echo "FAIL: $1"
    exit 1
}

assert_contains() {
    # assert_contains <haystack-string> <needle> <message>
    case "$1" in
    *"$2"*) ;;
    *) fail "$3 (missing: $2)" ;;
    esac
}

assert_not_contains() {
    case "$1" in
    *"$2"*) fail "$3 (unexpected: $2)" ;;
    esac
}

export HOME="$TMP/home"
export CONFIG_DIR="$TMP/cfg"
export PI_HOME="$CONFIG_DIR/home"
# Simulate an installed user: this checkout's bin/ is on PATH (Doom-style,
# no symlink in ~/.local/bin). check_global_install requires PATH resolution.
export PATH="$REPO_DIR/bin:$PATH"
PROJECT="$TMP/proj"
AGENT="$PI_HOME/.pi/agent"

mkdir -p "$HOME/.claude" "$HOME/.agents" "$PROJECT"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"

# --- Host state seeding ------------------------------------------------------
ensure_pi_dirs

[ -f "$AGENT/mcp.json" ] || fail "mcp.json was not seeded"
grep -q '"mcpServers"' "$AGENT/mcp.json" || fail "mcp.json must have an mcpServers object"
[ -d "$AGENT/skills" ] || fail "skills dir was not created"
[ -d "$AGENT/sessions" ] || fail "sessions dir was not created"
for f in auth.json mcp-auth.json trust.json mcp.log; do
    [ -f "$AGENT/$f" ] || fail "runtime state file $f was not seeded"
done
[ -d "$PI_HOME/.npm" ] || fail ".npm cache dir was not created"
have_node=false
command -v node >/dev/null 2>&1 && have_node=true
if [ "$have_node" = true ]; then
    json_valid "$AGENT/mcp.json" || fail "seeded mcp.json is not valid JSON"
fi

# --- Standard volume args ----------------------------------------------------
# shellcheck disable=SC2034
DOCKER_SOCKET=false
parse_config
build_standard_volume_args "$PROJECT" false

vols=" ${VOLUME_ARGS[*]} "
assert_contains "$vols" "$PROJECT:" "project must be mounted"
assert_contains "$vols" "$AGENT/mcp.json:/home/coder/.pi/agent/mcp.json:ro" "mcp.json must be mounted read-only"
assert_contains "$vols" "$AGENT/skills:/home/coder/.pi/agent/skills:rw" "skills must be mounted read-write"
assert_contains "$vols" "$AGENT/sessions:/home/coder/.pi/agent/sessions:rw" "sessions must be mounted read-write"
assert_contains "$vols" "$AGENT/auth.json:/home/coder/.pi/agent/auth.json:rw" "auth.json must be mounted read-write"
assert_contains "$vols" "$AGENT/mcp-auth.json:/home/coder/.pi/agent/mcp-auth.json:rw" "mcp-auth.json must be mounted read-write"
assert_contains "$vols" "$HOME/.claude:/home/coder/.claude:ro" "~/.claude must be mounted read-only"
assert_contains "$vols" "$HOME/.agents:/home/coder/.agents:ro" "~/.agents must be mounted read-only"
assert_not_contains "$vols" "/var/run/docker.sock" "docker socket must not be mounted by default"

# --- Common docker args ------------------------------------------------------
build_common_docker_args
common=" ${DOCKER_COMMON_ARGS[*]} "
assert_contains "$common" "--rm" "--rm must be present"
assert_contains "$common" "--cap-drop=ALL" "capabilities must be dropped"
assert_contains "$common" "--security-opt no-new-privileges:true" "no-new-privileges must be set"
assert_contains "$common" "--user $(id -u):$(id -g)" "container must run as the host uid:gid"
assert_contains "$common" "--group-add coder" "coder group must be added"
assert_contains "$common" "PI_CODING_AGENT_DIR=/home/coder/.pi/agent" "agent dir env must be set"
assert_contains "$common" "PI_SKIP_VERSION_CHECK=1" "self-update check must be disabled"
assert_contains "$common" "PI_DOCKERIZED_POLICY=balanced" "policy mode must be forwarded"
assert_not_contains "$common" "OPENCODE_CONFIG_CONTENT" "OpenCode config must not be used"

# --- Env-file containment ----------------------------------------------------
# A secrets file outside $CONFIG_DIR must be refused.
(
    ENV_FILE="$TMP/outside-env"
    printf 'ANTHROPIC_API_KEY=x\n' >"$ENV_FILE"
    build_env_file_args >/dev/null 2>&1
) && fail "env file outside CONFIG_DIR must be refused"

# A valid env file under CONFIG_DIR must be accepted and validated.
env_ok="$CONFIG_DIR/env"
printf 'ANTHROPIC_API_KEY=x\n' >"$env_ok"
chmod 600 "$env_ok"
ENV_FILE="$env_ok"
build_env_file_args
envargs=" ${DOCKER_ENV_FILE_ARGS[*]} "
assert_contains "$envargs" "--env-file $env_ok" "valid env file must be passed with --env-file"
ENV_FILE=""

# --- Mount validation --------------------------------------------------------
CUSTOM_MOUNTS=("$HOME/.ssh:/home/coder/.ssh")
if (build_mount_args >/dev/null 2>&1); then
    fail "mounting ~/.ssh must be refused"
fi
CUSTOM_MOUNTS=("$HOME/.gnupg:/home/coder/.gnupg")
if (build_mount_args >/dev/null 2>&1); then
    fail "mounting ~/.gnupg must be refused"
fi
# A well-formed read-only custom mount must land as :ro.
CUSTOM_MOUNTS=("$HOME/.gitconfig:/home/coder/.gitconfig")
: >"$HOME/.gitconfig"
build_mount_args
mnt=" ${DOCKER_MOUNT_ARGS[*]} "
assert_contains "$mnt" "$HOME/.gitconfig:/home/coder/.gitconfig:ro" "custom mounts default to read-only"
CUSTOM_MOUNTS=()

# --- Config file round-trip -------------------------------------------------
init_config_file >/dev/null
config_exists || fail "config file was not created"
SSH_AGENT_SUPPORT=true
GPG_AGENT_SUPPORT=false
NETWORK="bridge"
SECURITY_POLICY="strict"
THEME="system"
MODEL="sonnet"
MEMORY="4g"
CPUS="2"
ENV_FILE=""
CUSTOM_MOUNTS=("$HOME/.gitconfig:/home/coder/.gitconfig")
CUSTOM_MOUNT_KEYS=(gitconfig)
save_config >/dev/null
load_config >/dev/null
[ "$SSH_AGENT_SUPPORT" = true ] || fail "ssh_agent_support did not round-trip"
[ "$NETWORK" = bridge ] || fail "network did not round-trip"
[ "$SECURITY_POLICY" = strict ] || fail "security_policy did not round-trip"
[ "$THEME" = system ] || fail "theme did not round-trip"
[ "$MODEL" = sonnet ] || fail "model did not round-trip"
[ "$MEMORY" = 4g ] || fail "memory did not round-trip"
[ "${CUSTOM_MOUNTS[0]}" = "$HOME/.gitconfig:/home/coder/.gitconfig" ] || fail "custom mount did not round-trip"

# --- sync / check ------------------------------------------------------------
# Break the state and confirm sync repairs it.
rm -f "$AGENT/mcp.json" "$AGENT/mcp-auth.json"
if check_pi_state >/dev/null 2>&1; then
    fail "check_pi_state must report stale state"
fi
sync_pi_state >/dev/null 2>&1 || fail "sync_pi_state must repair the state"
[ -f "$AGENT/mcp.json" ] || fail "sync_pi_state must recreate mcp.json"
[ -f "$AGENT/mcp-auth.json" ] || fail "sync_pi_state must recreate mcp-auth.json"
check_pi_state >/dev/null 2>&1 || fail "check_pi_state must pass after sync"

# A broken mcp.json is backed up and reseeded.
printf '{ not json' >"$AGENT/mcp.json"
sync_pi_state >/dev/null 2>&1 || true
[ -f "$AGENT/mcp.json.bak" ] || fail "broken mcp.json must be backed up"
if [ "$have_node" = true ]; then
    json_valid "$AGENT/mcp.json" || fail "mcp.json must be reseeded valid"
fi

# --- Pi invocation args --------------------------------------------------------
# Regression: build_pi_args must return 0 when theme/model are empty, otherwise
# the wrapper (set -e) exits silently before `docker run`.
# Run in a separate bash: `set -e` is ignored inside `( ... ) || cmd`, which
# would hide exactly this failure mode.
run_pi_args() {
    # run_pi_args <theme> <model>: prints the resulting args, set -e active.
    bash -c 'set -e
        source "$1/lib/config-lib.sh"
        THEME="$2" MODEL="$3"
        args=()
        build_pi_args args
        echo "${args[*]}"' _ "$REPO_DIR" "$1" "$2"
}
out="$(run_pi_args "" "")" || fail "build_pi_args must succeed with empty theme/model"
[ -z "$out" ] || fail "build_pi_args must add nothing with empty theme/model (got: $out)"
out="$(run_pi_args "dark" "sonnet")" || fail "build_pi_args must succeed with theme/model set"
[ "$out" = "--use-theme dark --model sonnet" ] || fail "build_pi_args args mismatch (got: $out)"

# --- `run` end to end without Docker ------------------------------------------
# A fake docker lets the wrapper reach the final `docker run` (DRY_RUN prints it).
FAKE_BIN="$TMP/fakebin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/docker"
chmod +x "$FAKE_BIN/docker"
run_out="$(PATH="$FAKE_BIN:$PATH" DRY_RUN=true "$REPO_DIR/bin/pi-dockerized" run "$PROJECT" 2>&1)" ||
    fail "DRY_RUN run must exit 0 (got: $run_out)"
assert_contains "$run_out" "pi-dockerized:latest" "DRY_RUN run must print the docker command"

# --- update --pi-version validation ---------------------------------------------
# The value ends up in `docker build --build-arg`; reject anything but a version.
if PATH="$FAKE_BIN:$PATH" "$REPO_DIR/bin/pi-dockerized" update --pi-version 'x;rm' >/dev/null 2>&1; then
    fail "update must reject an invalid --pi-version"
fi
if PATH="$FAKE_BIN:$PATH" "$REPO_DIR/bin/pi-dockerized" update --pi-version >/dev/null 2>&1; then
    fail "update must reject --pi-version without a value"
fi

# --- Container-sync refusal --------------------------------------------------
# Only meaningful where a container marker exists (CI runners are bare metal).
if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    if (
        unset PI_DOCKERIZED_ALLOW_CONTAINER_SYNC
        sync_pi_state >/dev/null 2>&1
    ); then
        fail "sync must be host-only inside a container"
    fi
fi

echo "All wrapper-args tests passed."
