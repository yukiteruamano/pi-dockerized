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
# The isolated CONFIG_DIR/PI_HOME below are honored only in test mode.
export PI_DOCKERIZED_TEST=1

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

assert_eq() { [ "$1" = "$2" ] || fail "$3 (want '$2', got '$1')"; }

export HOME="$TMP/home"
export CONFIG_DIR="$TMP/cfg"
export PI_HOME="$CONFIG_DIR/home"
# Simulate an installed user: this checkout's bin/ is on PATH (Doom-style,
# no symlink in ~/.local/bin). check_global_install requires PATH resolution.
export PATH="$REPO_DIR/bin:$PATH"
PROJECT="$TMP/proj"
AGENT="$PI_HOME/.pi/agent"

mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills" "$PROJECT/.git/hooks"
touch "$PROJECT/.gitmodules"

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
assert_contains "$vols" "$HOME/.claude/skills:/home/coder/.claude/skills:ro" "the .claude skills must be mounted read-only"
assert_contains "$vols" "$HOME/.agents/skills:/home/coder/.agents/skills:ro" "the .agents skills must be mounted read-only"
assert_not_contains "$vols" "$HOME/.claude:" "the whole .claude directory (Claude Code login) must never be mounted"
assert_not_contains "$vols" "$HOME/.agents:" "the whole .agents directory must never be mounted"
assert_contains "$vols" "$AGENT/trust.json:/home/coder/.pi/agent/trust.json:ro" "trust.json must be mounted read-only"
assert_not_contains "$vols" "trust.json:rw" "a session must never write saved trust decisions"
assert_contains "$vols" "type=bind,source=$PROJECT/.git,target=$PROJECT/.git,readonly" "the project .git must be mounted read-only"
assert_contains "$vols" "type=bind,source=$PROJECT/.gitmodules,target=$PROJECT/.gitmodules,readonly" "the project .gitmodules must be mounted read-only"
assert_not_contains "$vols" "PI_DOCKERIZED_ALLOW_FILE" "no allow file is named when the host has none"
GIT_READONLY=false
build_standard_volume_args "$PROJECT" false
assert_not_contains " ${VOLUME_ARGS[*]} " "source=$PROJECT/.git," "git_readonly=false must leave .git writable"
GIT_READONLY=true
mv "$PROJECT/.gitmodules" "$PROJECT/.gm" && ln -s "$HOME" "$PROJECT/.gitmodules"
build_standard_volume_args "$PROJECT" false
assert_not_contains " ${VOLUME_ARGS[*]} " "source=$PROJECT/.gitmodules" "a symlinked .gitmodules must not be bind-mounted (Docker would follow it)"
rm -f "$PROJECT/.gitmodules" && mv "$PROJECT/.gm" "$PROJECT/.gitmodules"
rmdir "$HOME/.agents/skills" && mkdir -p "$HOME/.ssh" && ln -s "$HOME/.ssh" "$HOME/.agents/skills"
build_standard_volume_args "$PROJECT" false
assert_not_contains " ${VOLUME_ARGS[*]} " "/home/coder/.agents/skills" "a compat skills link into a credential store must be refused"
rm -f "$HOME/.agents/skills" && mkdir -p "$HOME/.agents/skills"
if [ "$have_node" = true ]; then
    printf '[]\n' >"$AGENT/allow.json"
    build_standard_volume_args "$PROJECT" false
    assert_contains " ${VOLUME_ARGS[*]} " "PI_DOCKERIZED_ALLOW_FILE=/home/coder/.pi/agent/allow.json" "the allow file is named only when mounted"
    rm -f "$AGENT/allow.json"
fi
build_standard_volume_args "$PROJECT" false
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
assert_contains "$common" "PI_CODING_AGENT_SESSION_DIR=/home/coder/.pi/agent/sessions" "the session store must be pinned (project sessionDir)"
assert_contains "$common" "JITI_FS_CACHE=false" "the extension transpile cache must be off"
assert_not_contains "$common" "PI_DOCKERIZED_ALLOW_FILE" "the allow file is named by the volume args, only when mounted"
assert_not_contains "$common" "OPENCODE_CONFIG_CONTENT" "legacy OpenCode config must not be used"

# Process cap: on by default (fork bombs are contained by the kernel), tunable,
# removable only with the explicit "unlimited".
assert_contains "$common" "--pids-limit 4096" "the default pids limit must be set"
assert_contains "$common" "--label pi-dockerized.profile=default" "sessions must carry the profile label"
PIDS_LIMIT=1024
build_common_docker_args
assert_contains " ${DOCKER_COMMON_ARGS[*]} " "--pids-limit 1024" "setting.pids_limit must be honored"
PIDS_LIMIT=unlimited
build_common_docker_args
assert_not_contains " ${DOCKER_COMMON_ARGS[*]} " "--pids-limit" "pids_limit=unlimited must drop the cap"
PIDS_LIMIT=4096
(_apply_setting pids_limit "not-a-number" 2>/dev/null) && fail "an invalid pids_limit must be refused"
_apply_setting pids_limit unlimited 2>/dev/null || fail "pids_limit=unlimited must be accepted"
PIDS_LIMIT=4096

# --- profile.map resolution ----------------------------------------------------
mkdir -p "$PI_CONFIG_ROOT" "$HOME/work/acme/app" "$HOME/oss"
cat >"$PI_CONFIG_ROOT/config" <<EOF
profile.map.work=~/work:acme
profile.map.deep=~/work/acme/app:app-profile
profile.map.oss=~/oss:default
profile.map.bad=~/elsewhere:Bad Name
profile.map.broken=no-separator
EOF
assert_eq "$(profile_for_dir "$HOME/work/proj" 2>/dev/null)" "acme" "profile.map must match by prefix"
assert_eq "$(profile_for_dir "$HOME/work/acme/app/src" 2>/dev/null)" "app-profile" "the longest matching path must win"
assert_eq "$(profile_for_dir "$HOME/oss/tool" 2>/dev/null)" "default" "mapping back to the root profile must work"
assert_eq "$(profile_for_dir "$HOME/elsewhere/x" 2>/dev/null)" "" "an invalid mapped profile name must be ignored"
assert_eq "$(profile_for_dir "$HOME" 2>/dev/null)" "" "unmapped directories must resolve to nothing"
rm -f "$PI_CONFIG_ROOT/config"

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
for bad_src in /tmp /var/tmp /tmp/ /tmp/.X11-unix "/tmp/tmux-$(id -u)" /tmp/ssh-abc123 /var/tmp/vscode-ipc \
    "$HOME/.colima" "$HOME/.colima/default" "$HOME/.rd" "$HOME/.lima"; do
    validate_mount_source "$bad_src" "t" >/dev/null 2>&1 && fail "socket-holding source $bad_src must be refused"
done
validate_mount_source "$PROJECT" "t" >/dev/null 2>&1 || fail "a project below /tmp must stay allowed"
if command -v python3 >/dev/null 2>&1; then
    mkdir -p "$TMP/sockproj/a/b"
    python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMP/sockproj/a/b/agent.sock"
    validate_mount_source "$TMP/sockproj" "t" >/dev/null 2>&1 && fail "a tree holding a socket must be refused"
    validate_mount_source "$TMP/sockproj/a/b/agent.sock" "t" >/dev/null 2>&1 && fail "a socket itself must be refused"
    rm -rf "$TMP/sockproj"
fi
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

    # A common dir planted inside the project itself (swappable for a symlink
    # before docker run) is never mounted, even when it points back.
    mkdir -p "$TMP/evil/fake/objects" "$TMP/evil/fake/refs" "$TMP/evil/fake/worktrees/x"
    printf 'gitdir: %s\n' "$TMP/evil/fake/worktrees/x" >"$TMP/evil/.git"
    printf '%s\n' "$TMP/evil/.git" >"$TMP/evil/fake/worktrees/x/gitdir"
    [ -z "$(detect_git_worktree "$TMP/evil")" ] || fail "a common dir inside the project must not be mounted"

    # A FIFO as the back-pointer must not hang the wrapper.
    mkdir -p "$TMP/fifo-main/objects" "$TMP/fifo-main/refs" "$TMP/fifo-main/worktrees/y" "$TMP/fifo-wt"
    printf 'gitdir: %s\n' "$TMP/fifo-main/worktrees/y" >"$TMP/fifo-wt/.git"
    mkfifo "$TMP/fifo-main/worktrees/y/gitdir"
    out="$(timeout 5 bash -c 'source "$1/lib/config-lib.sh"; detect_git_worktree "$2"' _ "$REPO_DIR" "$TMP/fifo-wt")" ||
        fail "a FIFO back-pointer must not hang detect_git_worktree"
    [ -z "$out" ] || fail "a FIFO back-pointer must be ignored"
fi

# --- GnuPG relay dir and socket overrides ------------------------------------------------
out="$(env -u PI_DOCKERIZED_TEST GPG_RELAY_DIR="$HOME/work" bash -c 'source "$1/lib/config-lib.sh"; printf %s "$GPG_RELAY_DIR"' _ "$REPO_DIR")"
assert_eq "$out" "$HOME/.config/pi-dockerized/profiles/default/gnupg-relay" "GPG_RELAY_DIR from the environment must be ignored outside test mode"
out="$(env -u PI_DOCKERIZED_TEST GPG_AGENT_SOCKET="$TMP/owned.sock" bash -c 'source "$1/lib/config-lib.sh"; resolve_gpg_agent_socket' _ "$REPO_DIR" 2>/dev/null)"
assert_not_contains "$out" "$TMP/owned.sock" "GPG_AGENT_SOCKET must be ignored outside test mode"
# Even in test mode, cleanup only removes the relay entries it created.
RELAY_TEST="$TMP/relays"
mkdir -p "$RELAY_TEST/projA/src" "$RELAY_TEST/99999999"
: >"$RELAY_TEST/99999999/pid"
PI_DOCKERIZED_TEST=1 GPG_RELAY_DIR="$RELAY_TEST" GPG_AGENT_SUPPORT=true cleanup_stale_relays
[ -d "$RELAY_TEST/projA/src" ] || fail "relay cleanup must never delete unrelated directories"
[ ! -e "$RELAY_TEST/99999999" ] || fail "relay cleanup must remove a stale relay entry"

# --- Concurrent sessions: nothing of a running session is touched by another ----------------
# A real background process stands in for a second wrapper that is running.
sleep 60 &
OTHER_WRAPPER=$!
# A relay that is still starting (socat PID not written yet) must survive.
mkdir -p "$RELAY_TEST/$OTHER_WRAPPER"
PI_DOCKERIZED_TEST=1 GPG_RELAY_DIR="$RELAY_TEST" GPG_AGENT_SUPPORT=true cleanup_stale_relays
[ -d "$RELAY_TEST/$OTHER_WRAPPER" ] || fail "relay cleanup must keep the entry of a running wrapper"

HOST_GNUPG="$TMP/host-gnupg"
mkdir -p "$HOST_GNUPG/public-keys.d"
printf 'keyring\n' >"$HOST_GNUPG/pubring.kbx"
printf 'db\n' >"$HOST_GNUPG/public-keys.d/pubring.db"
MIRRORS="$(gpg_mirror_root)"
# The other session's mirror, with what its container wrote into it.
mkdir -p "$MIRRORS/$OTHER_WRAPPER" "$MIRRORS/99999998"
: >"$MIRRORS/$OTHER_WRAPPER/S.keyboxd"
ln -sfn /home/coder/.gnupg-agent/S.gpg-agent "$MIRRORS/$OTHER_WRAPPER/S.gpg-agent"
: >"$MIRRORS/$OTHER_WRAPPER/pubring.kbx.lock"
cleanup_stale_gpg_mirrors
GNUPGHOME="$HOST_GNUPG" ensure_gpg_mirror >/dev/null 2>&1
[ -e "$MIRRORS/$OTHER_WRAPPER/S.keyboxd" ] && [ -L "$MIRRORS/$OTHER_WRAPPER/S.gpg-agent" ] &&
    [ -e "$MIRRORS/$OTHER_WRAPPER/pubring.kbx.lock" ] ||
    fail "starting a session must not touch the keyboxd socket, agent link or locks of a running one"
[ ! -e "$MIRRORS/99999998" ] || fail "the mirror of a dead session must be cleaned up"
assert_eq "$GPG_MIRROR_DIR" "$MIRRORS/$$" "each session mirrors into its own directory"
[ ! -L "$GPG_MIRROR_DIR/gpg.conf" ] && grep -qx 'no-autostart' "$GPG_MIRROR_DIR/gpg.conf" || fail "gpg.conf must be a real file with no-autostart"
assert_eq "$(cat "$GPG_MIRROR_DIR/public-keys.d/pubring.db")" "db" "the keyboxd database must be mirrored"
assert_eq "$(cat "$GPG_MIRROR_DIR/pubring.kbx")" "keyring" "the public keyring must be mirrored"
# A second call in the same process starts from a fresh directory.
: >"$GPG_MIRROR_DIR/S.keyboxd"
GNUPGHOME="$HOST_GNUPG" ensure_gpg_mirror >/dev/null 2>&1
[ ! -e "$GPG_MIRROR_DIR/S.keyboxd" ] || fail "a session's mirror must start empty"
remove_gpg_mirror
[ ! -e "$MIRRORS/$$" ] || fail "a session must remove its mirror when it ends"
[ -d "$MIRRORS/$OTHER_WRAPPER" ] || fail "ending a session must keep the other session's mirror"
kill "$OTHER_WRAPPER" 2>/dev/null
wait "$OTHER_WRAPPER" 2>/dev/null
cleanup_stale_gpg_mirrors
[ ! -e "$MIRRORS/$OTHER_WRAPPER" ] || fail "the mirror is cleaned once its wrapper is gone"

# --- Env file: dangerous keys and a symlinked config dir --------------------------------------
for bad_key in LD_PRELOAD LD_BIND_NOW NODE_OPTIONS PI_DOCKERIZED_POLICY PI_CODING_AGENT_DIR BASH_ENV PATH \
    PI_SELF_UPDATE_COMMAND PI_CODING_AGENT_SESSION_DIR JITI_FS_CACHE npm_config_registry GIT_CONFIG_COUNT \
    GIT_SSH_COMMAND PYTHONPATH PROMPT_COMMAND SSH_AUTH_SOCK; do
    printf 'ANTHROPIC_API_KEY=x\n%s=y\n' "$bad_key" >"$env_ok"
    (
        ENV_FILE="$env_ok"
        build_env_file_args >/dev/null 2>&1
    ) && fail "env file setting $bad_key must be refused"
done
printf 'export NODE_OPTIONS=--require=/x\n' >"$env_ok"
(ENV_FILE="$env_ok" build_env_file_args >/dev/null 2>&1) && fail "an 'export' prefix must not hide a forbidden key"
printf 'ANTHROPIC_API_KEY=x\nGIT_AUTHOR_NAME=me\nNODE_EXTRA_CA_CERTS=/etc/ssl/certs/x.pem\n' >"$env_ok"
(ENV_FILE="$env_ok" build_env_file_args >/dev/null 2>&1) || fail "harmless keys (GIT_AUTHOR_NAME, NODE_EXTRA_CA_CERTS) must stay allowed"
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
COMP_WORDS=(pi-dockerized --profile work profile fix "")
COMP_CWORD=5
_pi_dockerized
assert_contains "${COMPREPLY[*]}" "default" "completion must offer profile names after 'profile fix'"
COMP_WORDS=(pi-dockerized config set security_policy "")
COMP_CWORD=4
_pi_dockerized
assert_eq "${COMPREPLY[*]}" "strict balanced off" "completion must offer the values of an enum setting"

# Both completion files must cover every command of the help text and every
# setting (single sources: show_help and SETTING_KEYS).
# shellcheck source=/dev/null
source "$REPO_DIR/lib/cmd/help.sh"
help_cmds=$(show_help | sed -n '/^Commands:/,/^$/p' | awk 'NR > 1 && NF { print $1 }' | sort -u)
for _c in $help_cmds; do
    [[ " $_PI_COMMANDS " == *" $_c "* ]] || fail "bash completion misses the '$_c' command"
    grep -q "'$_c:" "$REPO_DIR/completions/zsh.sh" || fail "zsh completion misses the '$_c' command"
done
assert_eq "$_PI_SETTINGS" "${SETTING_KEYS[*]}" "bash completion must list every setting"
for _k in "${SETTING_KEYS[@]}"; do
    grep -qw "$_k" "$REPO_DIR/completions/zsh.sh" || fail "zsh completion misses setting $_k"
done
unset _c _k help_cmds

# --- Output hygiene, portable paths and environment roots -------------------------------
out="$(printf 'a\033]0;x\007b\302\233c\n' | strip_control_chars)"
assert_eq "$out" "a]0;xbc" "C0 and C1 control characters must be stripped"
assert_eq "$(json_escape "$(printf 'x\033[2J"\\\ty')")" 'x[2J\"\\y' "json_escape must drop control characters and escape quotes"

SESS="$PI_HOME/.pi/agent/sessions"
printf '{"cwd":"/p\033]0;PWNED\007"}\n' >"$SESS/20260101T000000_abcdef12.jsonl"
mkfifo "$SESS/20260101T000001_fifo0000.jsonl"
ln -s /etc/passwd "$SESS/20260101T000002_link0000.jsonl"
out="$(NO_COLOR=1 timeout 5 bash -c 'source "$1/lib/config-lib.sh"; source "$1/lib/cmd/sessions.sh"; list_pi_sessions' _ "$REPO_DIR" 2>&1)" ||
    fail "run --list must not hang on a FIFO in sessions/"
[[ "$out" != *$'\033'* && "$out" != *$'\007'* ]] || fail "run --list must strip terminal escapes from session data"
assert_contains "$out" "abcdef12" "run --list must list regular session files"
assert_not_contains "$out" "link0000" "run --list must skip symlinks in sessions/"
rm -f "$SESS"/2026010*

mkdir -p "$TMP/cp/real/sub" && ln -s "$TMP/cp/real" "$TMP/cp/link" && ln -s ../real/sub "$TMP/cp/rel"
for p in "$TMP/cp/link/sub" "$TMP/cp/link/../x" "$TMP/cp/rel/missing/y" "$TMP/cp//real/./sub/" "/"; do
    assert_eq "$(_canonical_path_portable "$p")" "$(readlink -m -- "$p")" "the portable canonical_path must match readlink -m for $p"
done
ln -s loop1 "$TMP/cp/loop2" && ln -s loop2 "$TMP/cp/loop1"
timeout 5 bash -c 'source "$1/lib/config-lib.sh"; _canonical_path_portable "$2/cp/loop1/x" >/dev/null' _ "$REPO_DIR" "$TMP" ||
    fail "the portable canonical_path must stop on symlink loops"
(
    HOST_CASE_INSENSITIVE=true
    validate_mount_source "$HOME/.SSH" "t" >/dev/null 2>&1 && fail "\$HOME/.SSH must be refused on a case-insensitive host"
    path_within "/A/B/c" "/a/b" || fail "case-insensitive hosts must fold case in path_within"
)

out="$(env -u PI_DOCKERIZED_TEST CONFIG_DIR="$TMP/evil-cfg" PI_HOME="$TMP/evil-home" PI_CONFIG_ROOT="$TMP/evil-root" \
    bash -c 'source "$1/lib/config-lib.sh"; printf "%s|%s|%s" "$CONFIG_DIR" "$PI_HOME" "$PI_CONFIG_ROOT"' _ "$REPO_DIR" 2>/dev/null)"
assert_not_contains "$out" "evil" "config roots from the environment must be ignored outside test mode"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/install/sections.sh"
rc_path_safe "/home/u/.local/share/pi-dockerized" || fail "a plain install path is rc-safe"
for bad in '/x/$(touch y)' '/x/a"b' '/x/`id`' '/x/a\b'; do
    rc_path_safe "$bad" && fail "install path $bad must not be embedded in an rc file"
done

(
    CONFIG_FILE="$TMP/sp ace/config"
    mkdir -p "$TMP/sp ace"
    printf 'x\n' >"$CONFIG_FILE"
    for i in 1 2 3 4 5 6 7; do : >"$CONFIG_FILE.bak.2026010${i}000000"; done
    CONFIG_BACKED_UP=false
    backup_config_file
    n=$(find "$TMP/sp ace" -name 'config.bak.*' | wc -l)
    [ "$n" -eq 5 ] || fail "backups must be trimmed to five in a path with spaces (got $n)"
    [ ! -e "$CONFIG_FILE.bak.20260101000000" ] || fail "the oldest backups must go first"
)

# install.sh with PI_DOCKERIZED_VERIFY=1: an unsigned clone is removed (never
# reused by the next run), and a reused unsigned checkout is never executed.
if command -v git >/dev/null 2>&1; then
    UPSTREAM="$TMP/upstream"
    git -c init.defaultBranch=master init -q "$UPSTREAM"
    mkdir -p "$UPSTREAM/bin" && printf '#!/bin/bash\necho RAN\n' >"$UPSTREAM/bin/pi-dockerized" && chmod +x "$UPSTREAM/bin/pi-dockerized"
    git -C "$UPSTREAM" add -A && git -C "$UPSTREAM" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm unsigned
    INST="$TMP/inst"
    for attempt in 1 2; do
        out="$(PI_REPO_URL="$UPSTREAM" PI_INSTALL_DIR="$INST" PI_DOCKERIZED_VERIFY=1 GIT_CONFIG_GLOBAL=/dev/null \
            bash -s <"$REPO_DIR/install.sh" 2>&1)" && fail "an unsigned clone must not install (attempt $attempt)"
        assert_not_contains "$out" "RAN" "an unverified checkout must never run (attempt $attempt)"
        [ ! -e "$INST" ] || fail "a clone that failed verification must be removed (attempt $attempt)"
    done
    git clone -q "$UPSTREAM" "$INST"
    out="$(PI_REPO_URL="$UPSTREAM" PI_INSTALL_DIR="$INST" PI_DOCKERIZED_VERIFY=1 GIT_CONFIG_GLOBAL=/dev/null \
        bash -s <"$REPO_DIR/install.sh" 2>&1)" && fail "a reused unsigned checkout must not run with verification on"
    assert_not_contains "$out" "RAN" "a reused unsigned checkout must never run"
fi

echo "All wrapper-args tests passed."
