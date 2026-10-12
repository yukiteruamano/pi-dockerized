#!/bin/bash
# Contract test for the wrapper's host-side behavior beyond docker argument
# building: mount policy, config loading/editing, session flags, profiles,
# output hygiene, audit, uninstall and the image/session commands (driven
# through a fake `docker` that records its calls). No Docker required.
#
# Usage: bash tests/wrapper-commands.test.sh
# shellcheck disable=SC2034  # globals below are consumed by sourced config-lib.sh functions
# shellcheck disable=SC2088 # literal tildes are test inputs, not paths to expand

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_DIR/bin/pi-dockerized"

export TMPDIR="${TMPDIR:-/tmp/pi}"
mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"
TMP="$(mktemp -d -p "$TMPDIR")"
trap 'rm -r "$TMP" 2>/dev/null || true' EXIT

export PI_DOCKERIZED_ALLOW_CONTAINER_SYNC=1
export PI_DOCKERIZED_TEST=1
export NO_COLOR=1

fail() {
    echo "FAIL: $1"
    exit 1
}
assert_contains() {
    case "$1" in
    *"$2"*) ;;
    *) fail "$3 (missing: $2; got: $1)" ;;
    esac
}
assert_not_contains() {
    case "$1" in
    *"$2"*) fail "$3 (unexpected: $2)" ;;
    esac
}
assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (want '$2', got '$1')"
}

export HOME="$TMP/home"
export PI_CONFIG_ROOT="$HOME/.config/pi-dockerized"
export CONFIG_DIR="$TMP/cfg"
export PI_HOME="$CONFIG_DIR/home"
export PATH="$REPO_DIR/bin:$PATH"
PROJECT="$TMP/proj"
AGENT="$PI_HOME/.pi/agent"
mkdir -p "$HOME" "$PROJECT"

# shellcheck source=/dev/null
source "$REPO_DIR/lib/config-lib.sh"
# shellcheck source=/dev/null
source "$REPO_DIR/lib/cmd/extensions.sh"
ensure_pi_dirs

# --- Output hygiene -----------------------------------------------------------------
out="$(print_error "boom" 2>/dev/null)"
assert_eq "$out" "" "errors must go to stderr"
out="$(print_warning "careful" 2>/dev/null)"
assert_eq "$out" "" "warnings must go to stderr"
out="$(print_info "fine" 2>/dev/null)"
assert_contains "$out" "fine" "info must go to stdout"
out="$(print_warning $'x\033]0;pwn\007y' 2>&1)"
assert_contains "$out" "x]0;pwny" "control characters must be stripped from messages"
assert_not_contains "$out" $'\033' "no escape byte may survive (NO_COLOR is set)"
out="$(print_info 'a\nb %s')"
assert_contains "$out" 'a\nb %s' "message text is printed literally (no echo -e / printf format)"

# --- Test seams ----------------------------------------------------------------------
out="$(PI_DOCKERIZED_TEST='' GPG_RELAY_CMD='touch /x' test_seam GPG_RELAY_CMD)"
assert_eq "$out" "" "test seams are ignored outside test mode"
out="$(PI_DOCKERIZED_TEST=1 GPG_RELAY_CMD='touch /x' test_seam GPG_RELAY_CMD)"
assert_eq "$out" "touch /x" "test seams work in test mode"

# --- State permissions ---------------------------------------------------------------------
chmod 755 "$PI_HOME" "$AGENT" 2>/dev/null
chmod 644 "$AGENT/auth.json"
ensure_pi_dirs
assert_eq "$(stat -c '%a' "$PI_HOME")" "700" "state tree must be private"
assert_eq "$(stat -c '%a' "$AGENT/auth.json")" "600" "auth.json must be private"
[ -f "$AGENT/audit.log" ] || fail "audit.log must be seeded"
[ -d "$PI_HOME/.cache/qmd" ] || fail "qmd cache dir must be created"

# --- normalize_path / container path policy -------------------------------------------------
assert_eq "$(normalize_path '/a/../b//c/.')" "/b/c" "normalize_path resolves . .. and //"
assert_eq "$(normalize_path '/../..')" "/" "normalize_path stops at the root"
validate_container_path /proj "x" >/dev/null 2>&1 || fail "/proj is a fine container path"
validate_container_path /etc/ssl/certs/ca.pem "x" internal >/dev/null 2>&1 || fail "mounting a file under /etc must be allowed"
for bad in / /etc /usr /usr/local /usr/local/bin /home /home/coder /home/coder/.pi /home/coder/.pi/agent /bin; do
    validate_container_path "$bad" "x" >/dev/null 2>&1 && fail "container path $bad would hide system paths"
done
for bad in /home/coder/.pi/agent/extensions/x /home/coder/.pi/agent/allow.json /usr/local/bin/evil /home/coder/.nvm/x; do
    validate_container_path "$bad" "x" internal >/dev/null 2>&1 && fail "custom mount target $bad must be refused"
done

# A project whose $HOME-stripped path lands on a system dir is refused.
mkdir -p "$HOME/etc" "$HOME/projects/etc"
(build_standard_volume_args "$HOME/etc" false >/dev/null 2>&1) && fail "a project in HOME/etc would shadow /etc and must be refused"
(build_standard_volume_args "$HOME/projects/etc" false >/dev/null 2>&1) || fail "HOME/projects/etc is fine"

# --- Mount source policy ---------------------------------------------------------------------
mkdir -p "$HOME/.ssh" "$HOME/.aws" "$HOME/.config/gcloud" "$HOME/.kube" "$HOME/data" "$HOME/.config/git"
: >"$HOME/.netrc"
: >"$HOME/.gitconfig"
: >"$HOME/.config/git/ignore"
ln -s "$HOME/.ssh" "$TMP/sshlink"
: >"$TMP/docker.sock"
refused() {
    CUSTOM_MOUNTS=("$1")
    CUSTOM_MOUNT_KEYS=(t)
    if (build_mount_args >/dev/null 2>&1); then
        fail "mount must be refused: $1"
    fi
}
refused "$HOME:/home/coder/h"
refused "$(dirname "$HOME"):/home/coder/h"
refused "$HOME/.ssh:/home/coder/.ssh"
refused "$HOME/.ssh/config:/home/coder/c"
refused "$TMP/sshlink:/home/coder/l"
refused "$HOME/.aws:/home/coder/a"
refused "$HOME/.kube:/home/coder/k"
refused "$HOME/.config/gcloud:/home/coder/g"
refused "$HOME/.config:/home/coder/cfg"
refused "$HOME/.netrc:/home/coder/n"
refused "$PI_CONFIG_ROOT:/home/coder/w"
refused "$CONFIG_DIR/env:/home/coder/e"
refused "$CONFIG_DIR:/home/coder/e"
refused "$TMP/docker.sock:/var/run/docker.sock"
refused "/var/run/docker.sock:/var/run/docker.sock"
refused "relative/path:/data"
refused "$HOME/data:/home/coder/.pi/agent/extensions/evil"
refused "$HOME/data:/etc"
refused "$HOME/data:relative"

CUSTOM_MOUNTS=("$HOME/.gitconfig:/home/coder/.gitconfig" "$HOME/.config/git/ignore:/home/coder/.config/git/ignore:rw" "$HOME/data:/data")
CUSTOM_MOUNT_KEYS=(a b c)
build_mount_args >/dev/null 2>&1 || fail "legitimate mounts must pass"
mnt=" ${DOCKER_MOUNT_ARGS[*]} "
assert_contains "$mnt" "source=$HOME/.gitconfig,target=/home/coder/.gitconfig,readonly" "default mount is read-only (--mount)"
assert_contains "$mnt" "source=$HOME/.config/git/ignore,target=/home/coder/.config/git/ignore " "rw mount has no readonly flag"
assert_not_contains "$mnt" "ignore,readonly" "rw mount must stay writable"

CUSTOM_MOUNTS=("$TMP/missing:/data")
CUSTOM_MOUNT_KEYS=(m)
build_mount_args 2>"$TMP/mount-warn.txt"
warn="$(cat "$TMP/mount-warn.txt")"
assert_contains "$warn" "does not exist" "a missing mount source must be reported"
assert_eq "${#DOCKER_MOUNT_ARGS[@]}" "0" "a missing mount source must not reach docker"
CUSTOM_MOUNTS=()
CUSTOM_MOUNT_KEYS=()

# --- Config loading ----------------------------------------------------------------------------
printf '%s\n' \
    '# a comment' \
    'setting.netwrok=bridge' \
    'setting.docker_socket=yes' \
    'setting.network=lan' \
    'bogus line' \
    'setting.cpus=2' >"$CONFIG_FILE"
printf 'setting.model=sonnet' >>"$CONFIG_FILE" # last line without a trailing newline
warn="$(load_config 2>&1)"
assert_contains "$warn" "config line 2: unknown setting 'netwrok'" "typos in setting names must be reported with their line"
assert_contains "$warn" "Invalid value 'yes' for setting.docker_socket" "invalid booleans must be reported"
assert_contains "$warn" "Invalid value 'lan' for setting.network" "invalid enums must be reported"
assert_contains "$warn" "config line 5: unrecognized entry" "stray lines must be reported"
load_config >/dev/null 2>&1
assert_eq "$MODEL" "sonnet" "the last line without a newline must still load"
assert_eq "$CPUS" "2" "valid settings load"
assert_eq "$DOCKER_SOCKET" "false" "invalid values keep the default"
assert_eq "$NETWORK" "host" "invalid enum keeps the default"

# parse_config reads the file once per process.
_CONFIG_LOADED=false
first="$(parse_config 2>&1; parse_config 2>&1)"
count="$(printf '%s' "$first" | grep -c "unknown setting 'netwrok'")"
assert_eq "$count" "1" "parse_config must not repeat warnings"

# --- `~` in path settings -------------------------------------------------------------------------
assert_eq "$(expand_tilde '~')" "$HOME" "a bare tilde expands"
assert_eq "$(expand_tilde '~/a/b')" "$HOME/a/b" "~/path expands"
assert_eq "$(expand_tilde '~other/a')" '~other/a' "~user is not expanded to the wrong home"
assert_eq "$(expand_tilde '/x/~/y')" '/x/~/y' "a tilde in the middle is left alone"
assert_eq "$(expand_tilde 'rel/path')" 'rel/path' "plain paths are unchanged"

# Regression: `config sync --check` reported an existing `~/...` env file as missing.
: >"$HOME/tilde-env"
chmod 600 "$HOME/tilde-env"
ENV_FILE='~/tilde-env'
check_pi_state >"$TMP/state-out.txt" 2>&1
out="$(cat "$TMP/state-out.txt")"
assert_not_contains "$out" "env file not found" "an existing ~/ env file must be found"
assert_contains "$out" "env file permissions ok" "the ~/ env file's permissions are checked"
chmod 644 "$HOME/tilde-env"
check_pi_state >"$TMP/state-out.txt" 2>&1
assert_contains "$(cat "$TMP/state-out.txt")" "readable by group/others ($HOME/tilde-env)" "a group-readable ~/ env file is reported with its real path"
ENV_FILE='~/does-not-exist-env'
check_pi_state >"$TMP/state-out.txt" 2>&1
assert_contains "$(cat "$TMP/state-out.txt")" "env file not found: $HOME/does-not-exist-env" "a missing env file is reported with its expanded path"
ENV_FILE=""
rm -f "$HOME/tilde-env"

# --- config get / set / save preserve the file --------------------------------------------------
init_config_file >/dev/null
printf '%s\n' '# my own note' 'custom.thing=1' >>"$CONFIG_FILE"
config_set_value network bridge >/dev/null || fail "config set network bridge"
assert_eq "$(config_get_value network)" "bridge" "config get returns what config set stored"
config_set_value setting.memory 4g >/dev/null || fail "config set accepts the setting. prefix"
config_set_value network lan >/dev/null 2>&1 && fail "config set must reject an invalid enum"
config_set_value nope 1 >/dev/null 2>&1 && fail "config set must reject unknown keys"
config_set_value model $'a\nb' >/dev/null 2>&1 && fail "config set must reject newlines"
assert_eq "$(config_get_value network)" "bridge" "a rejected value must not change the file"
SSH_AGENT_SUPPORT=true
CUSTOM_MOUNTS=("$HOME/data:/data")
CUSTOM_MOUNT_KEYS=(data)
save_config >/dev/null
grep -q '^# my own note$' "$CONFIG_FILE" || fail "save_config must keep user comments"
grep -q '^custom.thing=1$' "$CONFIG_FILE" || fail "save_config must keep unknown entries"
grep -q '^setting.ssh_agent_support=true$' "$CONFIG_FILE" || fail "save_config must write settings"
grep -q '^mount.data=' "$CONFIG_FILE" || fail "save_config must write mounts"
assert_eq "$(grep -c '^setting.network=' "$CONFIG_FILE")" "1" "a setting must appear once after save"
grep -q '^# Docker socket' "$CONFIG_FILE" || fail "save_config must keep the template comments"
save_config >/dev/null
assert_eq "$(grep -c '^mount.data=' "$CONFIG_FILE")" "1" "saving twice must not duplicate mounts"

# --- Session flags -------------------------------------------------------------------------------
parse_session_flags --untrusted --policy strict "$PROJECT" --extra || fail "valid session flags"
assert_eq "${SESSION_REST[*]}" "$PROJECT --extra" "flags stop at the first non-flag"
assert_eq "$SESSION_UNTRUSTED" "true" "--untrusted is parsed"
parse_session_flags --dir "$PROJECT" -- --not-a-flag || fail "-- ends flag parsing"
assert_eq "$SESSION_DIR" "$PROJECT" "--dir is parsed"
assert_eq "${SESSION_REST[*]}" "--not-a-flag" "-- keeps the rest verbatim"
(parse_session_flags --policy bogus >/dev/null 2>&1) && fail "invalid --policy must be rejected"
(parse_session_flags --network >/dev/null 2>&1) && fail "--network without a value must be rejected"
parse_session_flags --untrusted --policy off
(apply_session_overrides >/dev/null 2>&1) && fail "--untrusted with --policy off must be refused"
parse_session_flags --untrusted --network host
(apply_session_overrides >/dev/null 2>&1) && fail "--untrusted with --network host must be refused"
SSH_AGENT_SUPPORT=true GPG_AGENT_SUPPORT=true DOCKER_SOCKET=true SECURITY_POLICY=off NETWORK=host
CUSTOM_MOUNTS=("$HOME/data:/data")
parse_session_flags --untrusted
apply_session_overrides || fail "--untrusted alone must apply"
assert_eq "$SECURITY_POLICY/$NETWORK/$SSH_AGENT_SUPPORT/$GPG_AGENT_SUPPORT/$DOCKER_SOCKET/${#CUSTOM_MOUNTS[@]}" \
    "strict/bridge/false/false/false/0" "--untrusted must tighten everything"
parse_session_flags --policy off --network bridge
SECURITY_POLICY=balanced NETWORK=host
apply_session_overrides
assert_eq "$SECURITY_POLICY/$NETWORK" "off/bridge" "explicit flags override the config"
SESSION_POLICY="" SESSION_NETWORK="" SESSION_UNTRUSTED=false
reset_settings

# --- Exposure summary ----------------------------------------------------------------------------
out="$(print_session_exposure 2>&1)"
assert_contains "$out" "network=host policy=balanced" "exposure line shows network and policy"
assert_contains "$out" "docker-socket=off" "exposure line shows the docker socket"
SECURITY_POLICY=off
out="$(print_session_exposure 2>&1)"
assert_contains "$out" "is 'off'" "policy off must be called out"
SECURITY_POLICY=balanced

# --- Host allow file -------------------------------------------------------------------------------
printf '[]\n' >"$AGENT/allow.json"
build_standard_volume_args "$PROJECT" false
assert_contains " ${VOLUME_ARGS[*]} " "$AGENT/allow.json:/home/coder/.pi/agent/allow.json:ro" "allow.json must be mounted read-only"
assert_contains " ${VOLUME_ARGS[*]} " "$AGENT/audit.log:/home/coder/.pi/agent/audit.log:rw" "audit.log must be mounted"
assert_contains " ${VOLUME_ARGS[*]} " "$PI_HOME/.cache/qmd:/home/coder/.cache/qmd:rw" "qmd cache must be mounted"
SESSION_UNTRUSTED=true
build_standard_volume_args "$PROJECT" false
assert_not_contains " ${VOLUME_ARGS[*]} " "allow.json" "untrusted sessions must not get host allow rules"
SESSION_UNTRUSTED=false
printf '{ nope' >"$AGENT/allow.json"
if [ -n "$(command -v node)" ]; then
    (build_standard_volume_args "$PROJECT" false >/dev/null 2>&1) && fail "a broken allow.json must stop the session"
fi
rm -f "$AGENT/allow.json"

# --- Common args -------------------------------------------------------------------------------------
ALLOWED_TOOLS="mcp_a,mcp_b"
build_common_docker_args
common=" ${DOCKER_COMMON_ARGS[*]} "
assert_contains "$common" "--label pi-dockerized=1" "sessions must be labeled"
assert_contains "$common" "PI_DOCKERIZED_ALLOWED_TOOLS=mcp_a,mcp_b" "allowed tools must reach the guard"
assert_contains "$common" "PI_DOCKERIZED_AUDIT_FILE=/home/coder/.pi/agent/audit.log" "audit path must reach the guard"
ALLOWED_TOOLS=""

# --- Commands driven through a fake docker ------------------------------------------------------------
FAKE_BIN="$TMP/fakebin"
export FAKE_DOCKER_LOG="$TMP/docker.log"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/docker" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_DOCKER_LOG"
case "$1" in
run) [ "${FAKE_RUN_FAIL:-}" = 1 ] && { echo "boom" >&2; exit 1; } ;;
ps) printf '%s\n' ${FAKE_PS_NAMES:-} ;;
image)
    if [ "$2" = inspect ]; then
        case "$*" in
        *:previous*) [ "${FAKE_NO_PREVIOUS:-}" = 1 ] && exit 1 ;;
        *org.opencontainers.image.version*) echo "${FAKE_IMAGE_VERSION:-}" ;;
        *pi-dockerized.docker-cli*) echo "${FAKE_DOCKER_CLI:-}" ;;
        esac
    elif [ "$2" = ls ]; then
        printf '%s\n' pi-dockerized:latest pi-dockerized:previous 'pi-dockerized:<none>'
    fi
    ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/docker"
bin() { PATH="$FAKE_BIN:$PATH" "$BIN" "$@"; }
: >"$FAKE_DOCKER_LOG"
init_config_file >/dev/null # start the command tests from a pristine config

# run: flags, labels, exposure, DRY_RUN.
out="$(DRY_RUN=true bin run --untrusted --network bridge "$PROJECT" 2>&1)" || fail "untrusted dry-run must work"
assert_contains "$out" "Exposure: untrusted network=bridge policy=strict" "run prints the exposure summary"
assert_contains "$out" "PI_DOCKERIZED_POLICY=strict" "untrusted forces the strict policy"
assert_contains "$out" "pi-dockerized.project=$PROJECT" "sessions carry the project label"
DRY_RUN=true bin run --untrusted --policy off "$PROJECT" >/dev/null 2>&1 && fail "contradictory flags must fail"

# exec: stdin prompt, --dir, exit code propagation.
out="$(echo "summarize this" | DRY_RUN=true bin exec --dir "$PROJECT" 2>&1)" || fail "exec reads the prompt from stdin"
assert_contains "$out" "--print" "exec runs pi --print"
assert_contains "$out" "summarize this" "exec passes the stdin prompt"
assert_contains "$out" "$PROJECT:$PROJECT" "exec --dir mounts that directory"
out="$(echo "from stdin" | DRY_RUN=true bin exec - --model x 2>&1)" || fail "exec - reads stdin"
assert_contains "$out" "from stdin" "exec - passes the stdin prompt"
assert_contains "$out" "--model" "exec keeps Pi's own flags"
bin exec </dev/null >/dev/null 2>&1 && fail "exec without a prompt must fail"
FAKE_RUN_FAIL=1 bin exec "hello" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail "exec must propagate a failing container exit code"

# shell
out="$(DRY_RUN=true bin shell "$PROJECT" 2>&1)" || fail "shell dry-run must work"
assert_contains "$out" "pi-dockerized:latest" "shell runs in the image"
assert_contains "$out" "bash" "shell starts bash"

# Image drift warnings.
out="$(FAKE_IMAGE_VERSION=0.0.1 DRY_RUN=true bin run "$PROJECT" 2>&1)"
assert_contains "$out" "built by wrapper 0.0.1" "a stale image must be reported"
printf 'setting.docker_socket=true\n' >"$CONFIG_FILE"
out="$(FAKE_IMAGE_VERSION=0.16.0 FAKE_DOCKER_CLI=false DRY_RUN=true bin run "$PROJECT" 2>&1)"
assert_contains "$out" "no Docker CLI" "docker socket without the CLI in the image must be reported"
init_config_file >/dev/null

# build: candidate -> smoke test -> promote, keeping the previous image.
: >"$FAKE_DOCKER_LOG"
bin build >/dev/null 2>&1 || fail "build must succeed with a healthy image"
log="$(cat "$FAKE_DOCKER_LOG")"
assert_contains "$log" "build --build-arg WRAPPER_VERSION=" "build stamps the wrapper version"
assert_contains "$log" "INSTALL_DOCKER_CLI=false" "the docker CLI is left out unless the socket is enabled"
assert_contains "$log" "tag pi-dockerized:latest pi-dockerized:previous" "the replaced image is kept as previous"
assert_contains "$log" "pi-dockerized:candidate-" "build goes through a candidate tag"
assert_contains "$log" "tag pi-dockerized:candidate-" "the candidate is promoted"
build_line="$(grep -n '^build ' "$FAKE_DOCKER_LOG" | head -1 | cut -d: -f1)"
promote_line="$(grep -n 'tag pi-dockerized:candidate-' "$FAKE_DOCKER_LOG" | head -1 | cut -d: -f1)"
[ "$build_line" -lt "$promote_line" ] || fail "promotion must come after the build and smoke test"
printf 'setting.docker_socket=true\n' >"$CONFIG_FILE"
: >"$FAKE_DOCKER_LOG"
bin build >/dev/null 2>&1
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "INSTALL_DOCKER_CLI=true" "docker_socket=true builds the image with the CLI"
init_config_file >/dev/null
: >"$FAKE_DOCKER_LOG"
FAKE_RUN_FAIL=1 bin build >/dev/null 2>&1 && fail "a failing smoke test must fail the build"
assert_not_contains "$(cat "$FAKE_DOCKER_LOG")" "tag pi-dockerized:candidate" "a failed smoke test must not promote the image"

# update --pi-version: not passed unless asked; --verify is accepted.
out="$(bin update --help 2>&1)"
assert_contains "$out" "--verify" "update documents --verify"
out="$(bin update --pi-version 'x;rm' 2>&1)" && fail "update must reject a bad --pi-version"

# rollback / clean / ps / stop.
: >"$FAKE_DOCKER_LOG"
bin rollback >/dev/null 2>&1 || fail "rollback must succeed when a previous image exists"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "tag pi-dockerized:previous pi-dockerized:latest" "rollback re-tags previous as latest"
FAKE_NO_PREVIOUS=1 bin rollback >/dev/null 2>&1 && fail "rollback without a previous image must fail"
: >"$FAKE_DOCKER_LOG"
bin clean >/dev/null 2>&1 || fail "clean must succeed"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "rmi pi-dockerized:latest pi-dockerized:previous" "clean removes every tag"
assert_not_contains "$(cat "$FAKE_DOCKER_LOG")" "<none>" "clean must skip untagged entries"
: >"$FAKE_DOCKER_LOG"
FAKE_PS_NAMES="pi-a pi-b" bin stop pi-a >/dev/null 2>&1 || fail "stop NAME"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "stop pi-a" "stop NAME stops that session"
: >"$FAKE_DOCKER_LOG"
FAKE_PS_NAMES="pi-a pi-b" bin stop --all >/dev/null 2>&1 || fail "stop --all"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "stop pi-a pi-b" "stop --all stops every session"
bin stop >/dev/null 2>&1 && fail "stop without a target must fail"

# pull: refuses to proceed without cosign unless --no-verify.
out="$(PATH="$FAKE_BIN:/usr/bin:/bin" "$BIN" pull 2>&1)" && fail "pull without cosign must fail"
assert_contains "$out" "cosign is required" "pull explains why it refused"
: >"$FAKE_DOCKER_LOG"
bin pull v0.16.0 --no-verify >/dev/null 2>&1 || fail "pull --no-verify"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "pull ghcr.io/yukiteruamano/pi-dockerized:v0.16.0" "pull fetches the requested tag"

# --- Pi Packages (extensions) -----------------------------------------------------------------------------
[ -d "$EXT_AGENT_DIR" ] || fail "the ext-agent directory must be created"
[ ! -e "$EXT_AGENT_DIR/settings.json" ] || fail "settings.json is seeded inside the image, never on the host"
if command -v node >/dev/null 2>&1; then
    node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if("packages" in s) process.exit(1)' \
        "$REPO_DIR/container/settings.base.json" || fail "the baked settings must not declare packages"
fi

# Until something is installed, sessions use the host settings.json (see
# wrapper-args.test.sh); nothing from ext-agent is mounted.
build_standard_volume_args "$PROJECT" false
assert_not_contains " ${VOLUME_ARGS[*]} " "ext-agent" "nothing is mounted before the first install"
out="$(print_session_exposure 2>&1)"
assert_contains "$out" "extensions=off" "no packages: extensions off"

# After an install the three paths Pi uses are mounted over the agent's own, read-only.
mkdir -p "$EXT_AGENT_DIR/npm" "$EXT_AGENT_DIR/git"
printf '{"packages":["npm:x"]}\n' >"$EXT_AGENT_DIR/settings.json"
build_standard_volume_args "$PROJECT" false
vols=" ${VOLUME_ARGS[*]} "
assert_contains "$vols" "$EXT_AGENT_DIR/settings.json:/home/coder/.pi/agent/settings.json:ro" "host settings.json mounted read-only"
assert_contains "$vols" "$EXT_AGENT_DIR/npm:/home/coder/.pi/agent/npm:ro" "npm/ mounted read-only"
assert_contains "$vols" "$EXT_AGENT_DIR/git:/home/coder/.pi/agent/git:ro" "git/ mounted read-only"
out="$(print_session_exposure 2>&1)"
assert_contains "$out" "extensions=on" "installed packages: extensions on"
rmdir "$EXT_AGENT_DIR/git"
build_standard_volume_args "$PROJECT" false
assert_not_contains " ${VOLUME_ARGS[*]} " "agent/git" "an absent git/ is not mounted"
mkdir -p "$EXT_AGENT_DIR/git"

SESSION_UNTRUSTED=true
build_standard_volume_args "$PROJECT" false
assert_not_contains " ${VOLUME_ARGS[*]} " "ext-agent" "--untrusted sessions load no host packages"
out="$(print_session_exposure 2>&1)"
assert_contains "$out" "extensions=off" "--untrusted: extensions off"
SESSION_UNTRUSTED=false

if command -v node >/dev/null 2>&1; then
    printf '{ nope' >"$EXT_AGENT_DIR/settings.json"
    (build_standard_volume_args "$PROJECT" false >/dev/null 2>&1) && fail "a broken ext-agent settings.json must stop the session"
fi
printf '{"packages":["npm:x"]}\n' >"$EXT_AGENT_DIR/settings.json"

validate_container_path /home/coder/.pi/agent/npm/x "x" internal >/dev/null 2>&1 && fail "a custom mount inside the agent dir must be refused"
validate_container_path /home/coder/.pi/ext-agent/x "x" internal >/dev/null 2>&1 && fail "a custom mount inside ext-agent must be refused"

# Package sources: what `pi install` takes, nothing that could be an option or a local path.
for ok in "npm:@scope/pkg@1.2.3" "npm:pkg" "git:github.com/o/r@v1.0.0" "https://github.com/o/r"; do
    validate_ext_source "$ok" >/dev/null 2>&1 || fail "package source must be accepted: $ok"
done
# shellcheck disable=SC2088 # a literal tilde is the point: it must be rejected, not expanded
for bad in "" "pkg" "./local" "/abs/path" '~/x' "-l" "--local" "npm:-g" "npm:--foo" "npm:a b" 'npm:a;b' 'npm:$(id)' "git:" "npm:" "file:///x" "http://insecure/x" "npm:a|b"; do
    validate_ext_source "$bad" >/dev/null 2>&1 && fail "package source must be rejected: '$bad'"
done

# `extensions` command: the official `pi` in a throwaway container.
out="$(DRY_RUN=true bin extensions install npm:@scope/pkg@1.0.0 2>&1)" || fail "extensions install dry-run"
assert_contains "$out" "$EXT_AGENT_DIR:/home/coder/.pi/ext-agent:rw" "the installer mounts ext-agent read-write"
assert_contains "$out" "/usr/local/lib/pi-dockerized/ext-install.sh" "the installer runs the baked wrapper around pi"
assert_contains "$out" "npm:@scope/pkg@1.0.0" "the source reaches pi install"
assert_contains "$out" "npm_config_ignore_scripts=true" "install scripts are skipped by default"
assert_not_contains "$out" "--env-file" "the installer must not receive the secrets file"
assert_not_contains "$out" "/home/coder/.pi/agent/auth.json" "the installer must not mount session state"
assert_contains "$out" "bridge" "the installer runs on the bridge network, not the host's"
last_agent_dir="$(printf '%s\n' "$out" | grep 'PI_CODING_AGENT_DIR=' | tail -1)"
assert_eq "$last_agent_dir" "PI_CODING_AGENT_DIR=/home/coder/.pi/ext-agent" "the installer's agent dir wins over the common one"
out="$(DRY_RUN=true bin extensions install npm:pkg --allow-scripts 2>&1)" || fail "extensions install --allow-scripts"
assert_not_contains "$out" "npm_config_ignore_scripts" "--allow-scripts lets install scripts run"
assert_not_contains "$out" "--allow-scripts
" "--allow-scripts is not passed on to pi"
out="$(DRY_RUN=true bin extensions list 2>&1)" || fail "extensions list dry-run"
assert_contains "$out" "ext-install.sh" "list goes through the same container"
out="$(DRY_RUN=true bin extensions 2>&1)" || fail "bare extensions lists"
assert_contains "$out" "ext-install.sh" "bare extensions defaults to list"
out="$(DRY_RUN=true bin extensions remove npm:pkg 2>&1)" || fail "extensions remove dry-run"
assert_contains "$out" "remove" "remove reaches pi"
out="$(DRY_RUN=true bin extensions update 2>&1)" || fail "extensions update dry-run"
assert_contains "$out" "--extensions" "update without a source reconciles all packages"
out="$(DRY_RUN=true bin extensions update npm:pkg 2>&1)" || fail "extensions update SRC dry-run"
assert_contains "$out" "npm:pkg" "update with a source targets it"
for bad_cmd in "install" "install npm:a npm:b" "install ./local" "install -l" "remove" "remove npm:a --allow-scripts" "update npm:a npm:b" "list extra" "frobnicate"; do
    # shellcheck disable=SC2086 # word splitting of the arguments is intended
    DRY_RUN=true bin extensions $bad_cmd >/dev/null 2>&1 && fail "extensions $bad_cmd must fail"
done
assert_eq "$(bin extensions path 2>&1)" "$EXT_AGENT_DIR" "extensions path prints the host directory"
rm -f "$EXT_AGENT_DIR/settings.json"
bin extensions edit >/dev/null 2>&1 && fail "extensions edit needs an installed package first"
out="$(DRY_RUN=true bin run "$PROJECT" 2>&1)"
assert_contains "$out" "extensions=off" "run reports extensions off before any install"
printf '{"packages":["npm:x"]}\n' >"$EXT_AGENT_DIR/settings.json"
out="$(DRY_RUN=true bin run "$PROJECT" 2>&1)"
assert_contains "$out" "extensions=on" "run reports extensions on after an install"
assert_contains "$out" "$EXT_AGENT_DIR/settings.json:/home/coder/.pi/agent/settings.json:ro" "run mounts the host settings"
rm -f "$EXT_AGENT_DIR/settings.json"

# --- Audit ---------------------------------------------------------------------------------------------
printf '%s\n' \
    '{"ts":"2026-01-01T00:00:00Z","tool":"bash","rule":"backstop/bash","target":"x"}' \
    '{"ts":"2026-01-01T00:00:01Z","tool":"read","rule":"backstop/read","target":"y"}' \
    '{"ts":"2026-01-01T00:00:02Z","tool":"bash","rule":"backstop/bash","target":"z"}' >"$AGENT/audit.log"
out="$(bin audit -n 1 2>&1)"
assert_contains "$out" '"target":"z"' "audit -n 1 shows the newest entry"
assert_not_contains "$out" '"target":"x"' "audit -n 1 shows only one entry"
out="$(bin audit --summary 2>&1)"
assert_contains "$out" "2 \"rule\":\"backstop/bash\"" "audit --summary counts by rule"
bin audit -n x >/dev/null 2>&1 && fail "audit -n needs a number"
bin audit --clear >/dev/null 2>&1 || fail "audit --clear"
[ ! -s "$AGENT/audit.log" ] || fail "audit --clear must empty the log"

# --- config command (profiles, get/set) -----------------------------------------------------------------
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile work config path 2>&1)"
assert_eq "$out" "$TMP/root/profiles/work/config" "--profile selects its own config directory"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" config path 2>&1)"
assert_eq "$out" "$TMP/root/config" "the default profile lives in the root"
env -u CONFIG_DIR -u PI_HOME "$BIN" --profile 'Bad Name' config path >/dev/null 2>&1 && fail "invalid profile names must be rejected"
env -u CONFIG_DIR -u PI_HOME "$BIN" --profile '../evil' config path >/dev/null 2>&1 && fail "path traversal in a profile name must be rejected"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile work config set network bridge >/dev/null 2>&1 || fail "config set in a profile"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile work config get network 2>&1)"
assert_eq "$out" "bridge" "profile settings are stored separately"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" config profiles 2>&1)"
assert_contains "$out" "work" "config profiles lists the existing profiles"
bin config set network lan >/dev/null 2>&1 && fail "bin config set must reject invalid values"
bin config get nosuchkey >/dev/null 2>&1 && fail "bin config get must reject unknown keys"
out="$(bin config allow path 2>&1)"
assert_eq "$out" "$AGENT/allow.json" "config allow path"

# --- uninstall -----------------------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$REPO_DIR/lib/install-lib.sh"
RC="$HOME/.bashrc"
printf '%s\n' '# my own line' 'export FOO=bar' >"$RC"
ensure_path_in_rc "$RC" >/dev/null
ensure_aliases_in_rc "$RC" >/dev/null
_install_bash_completion "$REPO_DIR" >/dev/null
printf '%s\n' 'alias ll="ls -l"' >>"$RC"
grep -q 'pi-dockerized/bin' "$RC" || fail "setup: PATH line missing"
bin uninstall >/dev/null 2>&1 || fail "uninstall must succeed"
assert_not_contains "$(cat "$RC")" "pi-dockerized" "uninstall removes every managed line"
assert_not_contains "$(cat "$RC")" "completions/bash.sh" "uninstall removes the completion line"
assert_contains "$(cat "$RC")" "# my own line" "uninstall keeps the user's own lines"
assert_contains "$(cat "$RC")" 'alias ll="ls -l"' "uninstall keeps the user's own aliases"
[ -f "$RC.pi-dockerized.bak" ] || fail "uninstall must back up the rc file"
[ -d "$CONFIG_DIR" ] || fail "uninstall must keep the config by default"
out="$(bin uninstall 2>&1)"
assert_contains "$out" "Nothing to remove" "uninstall is idempotent"
PURGE_DIR="$HOME/.config/purge-test"
mkdir -p "$PURGE_DIR"
CONFIG_DIR="$PURGE_DIR" bin uninstall --purge-config --yes >/dev/null 2>&1 || fail "uninstall --purge-config"
[ ! -d "$PURGE_DIR" ] || fail "--purge-config must delete the config dir"
[ -d "$CONFIG_DIR" ] || fail "--purge-config must only touch the profile it was asked for"
OUTSIDE="$TMP/not-in-home"
mkdir -p "$OUTSIDE"
CONFIG_DIR="$OUTSIDE" bin uninstall --purge-config --yes >/dev/null 2>&1
[ -d "$OUTSIDE" ] || fail "--purge-config must refuse directories outside the home"

echo "All wrapper-commands tests passed."
