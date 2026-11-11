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
assert_contains "$vols" "$AGENT/skills:/home/coder/.pi/agent/skills:ro" "skills must be mounted read-only"
assert_contains "$vols" "$AGENT/sessions:/home/coder/.pi/agent/sessions:rw" "sessions must be mounted read-write"
assert_contains "$vols" "$AGENT/auth.json:/home/coder/.pi/agent/auth.json:rw" "auth.json must be mounted read-write"
assert_contains "$vols" "$AGENT/mcp-auth.json:/home/coder/.pi/agent/mcp-auth.json:rw" "mcp-auth.json must be mounted read-write"
assert_contains "$vols" "$HOME/.claude:/home/coder/.claude:ro" "the .claude directory must be mounted read-only"
assert_contains "$vols" "$HOME/.agents:/home/coder/.agents:ro" "the .agents directory must be mounted read-only"
assert_not_contains "$vols" "/var/run/docker.sock" "docker socket must not be mounted by default"
assert_contains "$vols" "$AGENT/prompts:/home/coder/.pi/agent/prompts:rw" "prompts must be mounted read-write"
assert_contains "$vols" "$AGENT/themes:/home/coder/.pi/agent/themes:rw" "themes must be mounted read-write"
assert_contains "$vols" "$PI_HOME/.pi-lens:/home/coder/.pi-lens:rw" "pi-lens state must be mounted read-write"
[ -d "$PI_HOME/.pi-lens" ] || fail "pi-lens state dir was not created"
cmp -s "$AGENT/settings.json" "$REPO_DIR/container/settings.base.json" || fail "settings.json must be seeded from the baked defaults"

# settings.json source: the host file in host mode, the packages file when Pi
# Packages are installed (and never for --untrusted).
assert_contains " ${VOLUME_ARGS[*]} " "$AGENT/settings.json:/home/coder/.pi/agent/settings.json:ro" "host settings.json must be mounted read-only over the baked one"
build_common_docker_args
assert_contains " ${DOCKER_COMMON_ARGS[*]} " "PI_DOCKERIZED_SETTINGS_SOURCE=host" "the session must tell the entrypoint it checks the host file"
mkdir -p "$EXT_AGENT_DIR"
printf '{}\n' >"$EXT_AGENT_DIR/settings.json"
build_standard_volume_args "$PROJECT" false
assert_contains " ${VOLUME_ARGS[*]} " "$EXT_AGENT_DIR/settings.json:/home/coder/.pi/agent/settings.json:ro" "packages settings must replace the host file while packages are installed"
assert_not_contains " ${VOLUME_ARGS[*]} " "$AGENT/settings.json:" "host settings.json must not be mounted alongside packages"
build_common_docker_args
assert_contains " ${DOCKER_COMMON_ARGS[*]} " "PI_DOCKERIZED_SETTINGS_SOURCE=ext" "the session must check the packages file rules"
SESSION_UNTRUSTED=true
build_standard_volume_args "$PROJECT" false
SESSION_UNTRUSTED=false
assert_contains " ${VOLUME_ARGS[*]} " "$AGENT/settings.json:/home/coder/.pi/agent/settings.json:ro" "--untrusted must use the host settings.json, never packages"
rm -f "$EXT_AGENT_DIR/settings.json"
rmdir "$EXT_AGENT_DIR" 2>/dev/null || true
build_standard_volume_args "$PROJECT" false
assert_not_contains "$vols" "models.json" "models.json must not be mounted when the file is absent"

# models.json: read-only when valid, refused when broken, never with --untrusted.
if [ "$have_node" = true ]; then
    printf '{"providers":{}}\n' >"$AGENT/models.json"
    build_standard_volume_args "$PROJECT" false
    assert_contains " ${VOLUME_ARGS[*]} " "$AGENT/models.json:/home/coder/.pi/agent/models.json:ro" "models.json must be mounted read-only"
    SESSION_UNTRUSTED=true
    build_standard_volume_args "$PROJECT" false
    SESSION_UNTRUSTED=false
    assert_not_contains " ${VOLUME_ARGS[*]} " "models.json" "models.json must not be mounted with --untrusted"
    printf '{ broken' >"$AGENT/models.json"
    (build_standard_volume_args "$PROJECT" false) >/dev/null 2>&1 && fail "invalid models.json must be refused"
    rm -f "$AGENT/models.json"
fi

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
assert_not_contains "$common" "OPENCODE_CONFIG_CONTENT" "legacy OpenCode config must not be used"

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
assert_contains "$mnt" "type=bind,source=$HOME/.gitconfig,target=/home/coder/.gitconfig,readonly" "custom mounts default to read-only"
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

# --- Failed-build code rollback --------------------------------------------------
# Throwaway repos only: the real checkout is never reset.
# shellcheck source=/dev/null
source "$REPO_DIR/lib/cmd/update.sh"
if command -v git >/dev/null 2>&1; then
    RB="$TMP/rb"
    mkdir -p "$RB"
    git -c init.defaultBranch=main -C "$RB" init -q
    git -C "$RB" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
    REV1=$(git -C "$RB" rev-parse HEAD)
    echo two >"$RB/f"
    git -C "$RB" add f
    git -C "$RB" -c user.email=t@t -c user.name=t commit -q -m two
    # with --yes a failed build rolls the code back to prev
    (REPO_ROOT="$RB" _UP_YES=true rollback_code_after_failed_build "$REV1" >/dev/null 2>&1) || true
    [ "$(git -C "$RB" rev-parse HEAD)" = "$REV1" ] || fail "with --yes a failed build must roll the code back"
    # dirty worktree is never reset
    echo three >"$RB/f"
    git -C "$RB" add f
    git -C "$RB" -c user.email=t@t -c user.name=t commit -q -m three
    echo dirty >"$RB/dirty"
    (REPO_ROOT="$RB" _UP_YES=true rollback_code_after_failed_build "$REV1" >/dev/null 2>&1) && fail "rollback must refuse a dirty worktree"
    [ -f "$RB/dirty" ] || fail "a dirty worktree must be left untouched"
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

# --- Mount-policy escapes ------------------------------------------------------
# A symlink pointing at $HOME must not slip past the literal-path check.
ln -s "$HOME" "$TMP/evil-home"
if validate_mount_source "$TMP/evil-home" "evil" >/dev/null 2>&1; then
    fail "a symlink to HOME must be refused as a mount source"
fi
if validate_mount_source "$HOME/.ssh" "evil" >/dev/null 2>&1; then
    fail "\$HOME/.ssh must be refused as a mount source"
fi
# A project that would land on /etc in the container must be refused.
if validate_container_path "/etc" "project" >/dev/null 2>&1; then
    fail "/etc must be refused as a container path"
fi

# --- Forwarding-socket ownership ------------------------------------------------
# A regular file is not a socket and must never be forwarded.
touch "$TMP/not-a-socket"
if forwarding_socket_ok "$TMP/not-a-socket" "test" >/dev/null 2>&1; then
    fail "a non-socket must be refused for forwarding"
fi
# A socket owned by this user is fine.
python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.bind('$TMP/owned.sock')"
forwarding_socket_ok "$TMP/owned.sock" "test" >/dev/null 2>&1 || fail "an owned socket must be accepted for forwarding"

# --- Settings values containing '=' -------------------------------------------------
config_upsert "setting.model" "a=b"
grep -q '^setting\.model=a=b$' "$CONFIG_FILE" || fail "values containing = must survive config_upsert"

# --- config get --source -------------------------------------------------------
config_set_value "theme" "dark" >/dev/null
src_out=$(config_get_value theme --source)
assert_contains "$src_out" "dark" "get --source prints the value"
assert_contains "$src_out" "(config file)" "get --source reports the config file"
src_out=$(config_get_value network --source)
assert_contains "$src_out" "(config file)" "seeded keys report the config file"
grep -v '^setting\.memory=' "$CONFIG_FILE" >"$TMP/cfg-stripped" && mv "$TMP/cfg-stripped" "$CONFIG_FILE"
load_config >/dev/null 2>&1 || true
src_out=$(config_get_value memory --source)
assert_contains "$src_out" "(default)" "get --source reports defaults"

# --- State permissions -------------------------------------------------------
harden_state_permissions
[ "$(stat -c %a "$PI_HOME/.pi/agent")" = 700 ] || fail "agent dir must be 0700"
[ "$(stat -c %a "$AGENT/audit.log")" = 600 ] || fail "audit.log must be 0600"

# --- Project-secret warning ----------------------------------------------------
SESSION_PROJECT="$PROJECT"
touch "$PROJECT/.env" "$PROJECT/creds.pem" "$PROJECT/.env.example"
secret_warn=$(warn_project_secrets 2>&1)
assert_contains "$secret_warn" ".env" "warning must name the .env file"
assert_contains "$secret_warn" "creds.pem" "warning must name the .pem file"
assert_not_contains "$secret_warn" ".env.example" "warning must ignore *.example templates"
rm -f "$PROJECT/.env" "$PROJECT/creds.pem" "$PROJECT/.env.example"
empty_warn=$(warn_project_secrets 2>&1)
[ -z "$empty_warn" ] || fail "warning must stay silent without secrets (got: $empty_warn)"
SESSION_PROJECT=""

# --- Project directory gate (same policy as custom mounts) -----------------------
# `run` is driven through the fake docker; a refused project exits non-zero.
dry_run() { PATH="$FAKE_BIN:$PATH" DRY_RUN=true "$REPO_DIR/bin/pi-dockerized" "$@"; }
mkdir -p "$HOME/.ssh" "$HOME/.config/pi-dockerized"
dry_run run "$HOME/.ssh" >/dev/null 2>&1 && fail "\$HOME/.ssh must be refused as the project"
dry_run run "$CONFIG_DIR" >/dev/null 2>&1 && fail "the wrapper config dir must be refused as the project"
dry_run run "$HOME/.config/pi-dockerized" >/dev/null 2>&1 && fail "the config root must be refused as the project"
dry_run run "$PI_HOME" >/dev/null 2>&1 && fail "the state tree must be refused as the project"
if [ -d /run ]; then
    dry_run run /run >/dev/null 2>&1 && fail "/run (Docker and agent sockets) must be refused as the project"
fi
# A project whose container path lands inside the agent dir would replace the guard.
mkdir -p "$HOME/home/coder/.pi/agent/extensions/x"
dry_run run "$HOME/home/coder/.pi/agent/extensions/x" >/dev/null 2>&1 && fail "a project over the agent dir must be refused"

# A symlinked $HOME (macOS /Users, NFS): the project path is resolved, $HOME is not.
mkdir -p "$TMP/realhome/proj"
ln -s "$TMP/realhome" "$TMP/linkhome"
HOME="$TMP/linkhome" dry_run run "$TMP/linkhome" >/dev/null 2>&1 && fail "a symlinked HOME must be refused as the project"
HOME="$TMP/linkhome" dry_run run "$TMP/realhome" >/dev/null 2>&1 && fail "the resolved HOME must be refused as the project"
out="$(HOME="$TMP/linkhome" dry_run run "$TMP/linkhome/proj" 2>&1)" || fail "a project in a symlinked HOME must work (got: $out)"
assert_contains "$out" "$TMP/realhome/proj:/proj" "the symlinked HOME prefix must be stripped from the container path"

# --- Mount sources and targets ------------------------------------------------------
for bad_src in /run /var/run /proc/1/root /sys /dev; do
    validate_mount_source "$bad_src" "t" >/dev/null 2>&1 && fail "mount source $bad_src must be refused"
done
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    validate_mount_source "$XDG_RUNTIME_DIR" "t" >/dev/null 2>&1 && fail "XDG_RUNTIME_DIR must be refused"
fi
validate_mount_source /run/media/user/usb/proj "t" >/dev/null 2>&1 || fail "removable media under /run/media must stay allowed"
for bad_dst in /etc/ld.so.preload /bin/sh /usr/lib /usr/lib/x86_64-linux-gnu/libc.so.6 /usr/local/bin/pi; do
    validate_container_path "$bad_dst" "t" >/dev/null 2>&1 && fail "mount target $bad_dst must be refused"
done

# --- --untrusted ----------------------------------------------------------------------
parse_session_flags --untrusted --policy balanced
(apply_session_overrides >/dev/null 2>&1) && fail "--untrusted must refuse --policy balanced"
dry_run run --untrusted --policy balanced "$PROJECT" >/dev/null 2>&1 && fail "run --untrusted --policy balanced must fail"
parse_session_flags --untrusted --policy strict
ALLOWED_TOOLS="bash_evil"
apply_session_overrides || fail "--untrusted --policy strict must apply"
[ -z "$ALLOWED_TOOLS" ] || fail "--untrusted must clear allowed_tools"
mkdir -p "$AGENT/prompts" "$AGENT/themes"
build_standard_volume_args "$PROJECT" false
vols=" ${VOLUME_ARGS[*]} "
for shared in "/home/coder/.npm" "/home/coder/.cache/qmd" "/home/coder/.pi-lens" "mcp-auth.json" "trust.json" \
    "mcp.json" "/home/coder/.claude" "/home/coder/.agents" "$AGENT/sessions:"; do
    assert_not_contains "$vols" "$shared" "--untrusted must not share $shared"
done
assert_contains "$vols" "$AGENT/sessions-untrusted:/home/coder/.pi/agent/sessions:rw" "--untrusted uses its own session store"
assert_contains "$vols" "$AGENT/prompts:/home/coder/.pi/agent/prompts:ro" "--untrusted reads prompt templates only"
assert_contains "$vols" "$AGENT/auth.json:/home/coder/.pi/agent/auth.json:rw" "--untrusted keeps provider logins"
[ "$(stat -c %a "$AGENT/sessions-untrusted")" = 700 ] || fail "the untrusted session store must be private"
SESSION_UNTRUSTED=false SESSION_POLICY=""
ALLOWED_TOOLS=""

# --- Git worktree mount ---------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
    WT_MAIN="$TMP/wt-main"
    mkdir -p "$WT_MAIN"
    git -c init.defaultBranch=main -C "$WT_MAIN" init -q
    git -C "$WT_MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
    git -C "$WT_MAIN" worktree add -q "$TMP/wt-linked" -b side 2>/dev/null
    assert_contains "$(detect_git_worktree "$TMP/wt-linked")" "$WT_MAIN/.git" "a real linked worktree is detected"
    SESSION_UNTRUSTED=true
    build_git_worktree_args "$TMP/wt-linked"
    SESSION_UNTRUSTED=false
    [ "${#GIT_WORKTREE_ARGS[@]}" -eq 0 ] || fail "--untrusted must not mount the main .git directory"

    # A planted pointer must not mount another private repo.
    VICTIM="$TMP/victim"
    mkdir -p "$VICTIM/.git/objects" "$VICTIM/.git/refs" "$TMP/evil/gd"
    printf 'gitdir: %s\n' "$TMP/evil/gd" >"$TMP/evil/.git"
    printf 'ref: refs/heads/main\n' >"$TMP/evil/gd/HEAD"
    printf '%s\n' "$VICTIM/.git" >"$TMP/evil/gd/commondir"
    [ -z "$(detect_git_worktree "$TMP/evil")" ] || fail "a planted commondir must not be mounted"
    mkdir -p "$VICTIM/.git/worktrees/x"
    printf 'gitdir: %s\n' "$VICTIM/.git/worktrees/x" >"$TMP/evil/.git"
    [ -z "$(detect_git_worktree "$TMP/evil")" ] || fail "a worktree entry that does not point back must not be mounted"
fi

# --- GnuPG relay dir and socket overrides ------------------------------------------------
out="$(env -u PI_DOCKERIZED_TEST GPG_RELAY_DIR="$HOME/work" bash -c 'source "$1/lib/config-lib.sh"; printf %s "$GPG_RELAY_DIR"' _ "$REPO_DIR")"
assert_eq() { [ "$1" = "$2" ] || fail "$3 (want '$2', got '$1')"; }
assert_eq "$out" "$CONFIG_DIR/gnupg-relay" "GPG_RELAY_DIR from the environment must be ignored outside test mode"
out="$(env -u PI_DOCKERIZED_TEST GPG_AGENT_SOCKET="$TMP/owned.sock" bash -c 'source "$1/lib/config-lib.sh"; resolve_gpg_agent_socket' _ "$REPO_DIR" 2>/dev/null)"
assert_not_contains "$out" "$TMP/owned.sock" "GPG_AGENT_SOCKET must be ignored outside test mode"
# Even in test mode, cleanup only removes the relay entries it created.
RELAY_TEST="$TMP/relays"
mkdir -p "$RELAY_TEST/projA/src" "$RELAY_TEST/99999999"
: >"$RELAY_TEST/99999999/pid"
PI_DOCKERIZED_TEST=1 GPG_RELAY_DIR="$RELAY_TEST" GPG_AGENT_SUPPORT=true cleanup_stale_relays
[ -d "$RELAY_TEST/projA/src" ] || fail "relay cleanup must never delete unrelated directories"
[ ! -e "$RELAY_TEST/99999999" ] || fail "relay cleanup must remove a stale relay entry"

# --- GnuPG mirror: no host writes through planted symlinks ---------------------------------
HOST_GNUPG="$TMP/host-gnupg"
mkdir -p "$HOST_GNUPG/public-keys.d" "$PI_HOME/.gnupg"
printf 'keyring\n' >"$HOST_GNUPG/pubring.kbx"
printf 'db\n' >"$HOST_GNUPG/public-keys.d/pubring.db"
printf 'untouched\n' >"$TMP/victim-file"
mkdir -p "$TMP/victim-dir"
ln -sfn "$TMP/victim-file" "$PI_HOME/.gnupg/gpg.conf"
ln -sfn "$TMP/victim-file" "$PI_HOME/.gnupg/pubring.kbx"
ln -sfn "$TMP/victim-dir" "$PI_HOME/.gnupg/public-keys.d"
GNUPGHOME="$HOST_GNUPG" ensure_gpg_mirror >/dev/null 2>&1
assert_eq "$(cat "$TMP/victim-file")" "untouched" "the mirror must not write through a planted symlink"
[ ! -e "$TMP/victim-dir/pubring.db" ] || fail "the mirror must not write into a planted directory symlink"
[ ! -L "$PI_HOME/.gnupg/gpg.conf" ] && grep -qx 'no-autostart' "$PI_HOME/.gnupg/gpg.conf" || fail "gpg.conf must be a real file with no-autostart"
assert_eq "$(cat "$PI_HOME/.gnupg/public-keys.d/pubring.db")" "db" "the keyboxd database must be mirrored"

# --- Env file: dangerous keys and a symlinked config dir --------------------------------------
for bad_key in LD_PRELOAD NODE_OPTIONS PI_DOCKERIZED_POLICY PI_CODING_AGENT_DIR BASH_ENV PATH PI_SELF_UPDATE_COMMAND; do
    printf 'ANTHROPIC_API_KEY=x\n%s=y\n' "$bad_key" >"$env_ok"
    (
        ENV_FILE="$env_ok"
        build_env_file_args >/dev/null 2>&1
    ) && fail "env file setting $bad_key must be refused"
done
printf 'export NODE_OPTIONS=--require=/x\n' >"$env_ok"
(ENV_FILE="$env_ok" build_env_file_args >/dev/null 2>&1) && fail "an 'export' prefix must not hide a forbidden key"
printf 'ANTHROPIC_API_KEY=x\n' >"$env_ok"
ln -s "$CONFIG_DIR" "$TMP/cfglink"
(CONFIG_DIR="$TMP/cfglink" ENV_FILE="$TMP/cfglink/env" build_env_file_args >/dev/null 2>&1) ||
    fail "an env file under a symlinked config dir must be accepted"

# env_file_upsert stages next to the file (never in a shared temp dir) and keeps it private.
UPSERT="$CONFIG_DIR/upsert-env"
printf 'A=1\nB=2\n' >"$UPSERT"
TMPDIR="$TMP/no-such-dir" env_file_upsert "$UPSERT" A 3 || fail "env_file_upsert must not depend on TMPDIR"
assert_eq "$(cat "$UPSERT")" "$(printf 'B=2\nA=3')" "env_file_upsert replaces the key"
assert_eq "$(stat -c %a "$UPSERT")" "600" "the secrets file must stay 0600"
env_file_upsert "$UPSERT" B 4 && env_file_upsert "$UPSERT" A 5 || fail "env_file_upsert of the last remaining key"
[ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name 'upsert-env.*')" ] || fail "env_file_upsert must not leave temp files"

# --- Audit output hygiene -------------------------------------------------------------------
printf '{"ts":"t","tool":"bash","rule":"x\033]0;pwn\007","target":"y\033[2J"}\n' >"$AGENT/audit.log"
out="$(NO_COLOR=1 PATH="$FAKE_BIN:$PATH" "$REPO_DIR/bin/pi-dockerized" audit 2>&1)"
assert_not_contains "$out" $'\033' "audit must strip escape bytes written by the container"
out="$(NO_COLOR=1 PATH="$FAKE_BIN:$PATH" "$REPO_DIR/bin/pi-dockerized" audit --summary 2>&1)"
assert_not_contains "$out" $'\033' "audit --summary must strip escape bytes"
: >"$AGENT/audit.log"

# --- exec prompt size ------------------------------------------------------------------------
out="$(head -c 130000 /dev/zero | tr '\0' a | dry_run exec - 2>&1)" && fail "an oversized exec prompt must be refused"
assert_contains "$out" "limit" "an oversized exec prompt explains the limit"

# --- rc files: only the installer's exact lines are managed ------------------------------------
# shellcheck source=/dev/null
source "$REPO_DIR/lib/install-lib.sh"
RC2="$TMP/rc-test"
# shellcheck disable=SC2016 # literal rc file content
printf '%s\n' '# old: pi-dockerized/bin was here' >"$RC2"
ensure_path_in_rc "$RC2" || fail "a commented mention must not count as the PATH line"
# shellcheck disable=SC2016 # literal rc file content
printf '%s\n' 'export PATH="$HOME/bin:$HOME/.local/share/pi-dockerized/bin:$PATH"' \
    '[ -f "/opt/other/completions/bash.sh" ] && source "/opt/other/completions/bash.sh"' >>"$RC2"
remove_managed_rc_lines "$RC2" || fail "uninstall must remove the installer's lines"
assert_contains "$(cat "$RC2")" 'export PATH="$HOME/bin:' "uninstall must keep a user's combined PATH line"
assert_contains "$(cat "$RC2")" "/opt/other/completions/bash.sh" "uninstall must keep another tool's completion line"
assert_not_contains "$(cat "$RC2")" "# Added by pi-dockerized install" "uninstall removes the marker"

# --- Docs coverage ---------------------------------------------------------------
# docs/config-reference.md must document every setting (single source: SETTING_KEYS).
ref_file="$REPO_DIR/docs/config-reference.md"
[ -f "$ref_file" ] || fail "docs/config-reference.md is missing"
for _k in "${SETTING_KEYS[@]}"; do
    grep -q "\`$_k\`" "$ref_file" || fail "docs/config-reference.md misses setting.$_k"
done
unset _k

# --- Completion smoke test ---------------------------------------------------
# The second-level branches must work with and without the global --profile.
# shellcheck source=/dev/null
source "$REPO_DIR/completions/bash.sh"
COMP_WORDS=(pi-dockerized config get "")
COMP_CWORD=3
_pi_dockerized
assert_contains "${COMPREPLY[*]}" "theme" "completion must offer settings after 'config get'"
COMP_WORDS=(pi-dockerized --profile work config get "")
COMP_CWORD=5
_pi_dockerized
assert_contains "${COMPREPLY[*]}" "theme" "completion must offer settings with --profile"
COMP_WORDS=(pi-dockerized stop "")
COMP_CWORD=2
_pi_dockerized
assert_contains "${COMPREPLY[*]}" "--all" "completion must offer --all for stop"

echo "All wrapper-args tests passed."
