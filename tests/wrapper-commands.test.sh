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
validate_container_path /etc/ssl/certs/ca.pem "x" >/dev/null 2>&1 || fail "mounting a CA certificate under /etc/ssl/certs must be allowed"
validate_container_path /usr/local/share/ca-certificates/corp.crt "x" >/dev/null 2>&1 || fail "mounting an extra CA certificate must be allowed"
for bad in / /etc /usr /usr/local /usr/local/bin /home /home/coder /home/coder/.pi /home/coder/.pi/agent /bin; do
    validate_container_path "$bad" "x" >/dev/null 2>&1 && fail "container path $bad would hide system paths"
done
for bad in /home/coder/.pi/agent/extensions/x /home/coder/.pi/agent/allow.json /usr/local/bin/evil /home/coder/.nvm/x; do
    validate_container_path "$bad" "x" >/dev/null 2>&1 && fail "custom mount target $bad must be refused"
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
first="$(
    parse_config 2>&1
    parse_config 2>&1
)"
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

# --- Session flag parsing (resume/list/timeout) ---------------------------------------
parse_session_flags --resume abc123 --policy strict
assert_eq "$SESSION_RESUME" "abc123" "--resume takes an id"
assert_eq "$SESSION_POLICY" "strict" "flags after --resume ID still parse"
parse_session_flags --resume
assert_eq "$SESSION_RESUME" "select" "bare --resume selects interactively"
parse_session_flags --resume=abc123
assert_eq "$SESSION_RESUME" "abc123" "--resume= takes an id"
parse_session_flags --list
assert_eq "$SESSION_LIST" "true" "--list is parsed"
parse_session_flags --timeout 5m
assert_eq "$SESSION_TIMEOUT" "5m" "--timeout is parsed"
(parse_session_flags --timeout bogus >/dev/null 2>&1) && fail "invalid --timeout must be rejected"
parse_session_flags --policy strict
assert_eq "${SESSION_RESUME:-}" "" "resume resets between parses"
assert_eq "$SESSION_LIST" "false" "list resets between parses"
assert_eq "$SESSION_TIMEOUT" "" "timeout resets between parses"

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
run)
    [ "${FAKE_RUN_FAIL:-}" = 1 ] && { echo "boom" >&2; exit 1; }
    case "$*" in
    *ghcr.io*selftest.mjs*--version*) echo "${FAKE_PULLED_GUARD:-${FAKE_GUARD_VERSION:-}}" ;;
    *selftest.mjs*--version*) echo "${FAKE_GUARD_VERSION:-}" ;;
    esac
    ;;
ps) printf '%s\n' ${FAKE_PS_NAMES:-} ;;
image)
    if [ "$2" = inspect ]; then
        case "$*" in
        *:previous*)
            [ "${FAKE_NO_PREVIOUS:-}" = 1 ] && exit 1
            case "$*" in *.Id*) echo "${FAKE_PREVIOUS_ID:-${FAKE_IMAGE_ID:-}}" ;; esac
            ;;
        *.Id*) echo "${FAKE_IMAGE_ID:-}" ;;
        *org.opencontainers.image.version*ghcr.io*) echo "${FAKE_PULLED_VERSION:-${FAKE_IMAGE_VERSION:-}}" ;;
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
DRY_RUN=true bin exec --dir "$PROJECT" --timeout abc "hi" >/dev/null 2>&1 && fail "exec must reject a bad --timeout"
out="$(DRY_RUN=true bin exec --dir "$PROJECT" --timeout 60 "hi" 2>&1)" || fail "exec with --timeout must work"
assert_contains "$out" "timeout" "exec --timeout wraps the docker command"

# exec: stdin prompt, --dir, exit code propagation.
out="$(echo "summarize this" | DRY_RUN=true bin exec --dir "$PROJECT" 2>&1)" || fail "exec reads the prompt from stdin"
assert_contains "$out" "--print" "exec runs pi --print"
assert_contains "$out" "summarize this" "exec passes the stdin prompt"
assert_contains "$out" "$PROJECT:$PROJECT" "exec --dir mounts that directory"
out="$(echo "from stdin" | DRY_RUN=true bin exec - --model x 2>&1)" || fail "exec - reads stdin"
assert_contains "$out" "from stdin" "exec - passes the stdin prompt"
assert_contains "$out" "--model" "exec keeps Pi's own flags"
# A message starting with `-` must not become a pi flag.
out="$(DRY_RUN=true bin exec --dir "$PROJECT" -- "-weird flag-like message" 2>&1)" || fail "exec with a dash message must work"
printf '%s\n' "$out" | grep -qx -- "--" || fail "exec must separate the message with --"
assert_contains "$out" '"-weird flag-like message"' "exec passes the dash message through"
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
FAKE_PS_NAMES="pi-a pi-b" bin stop --all --yes >/dev/null 2>&1 || fail "stop --all --yes"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "stop pi-a pi-b" "stop --all --yes stops every session"
FAKE_PS_NAMES="pi-a pi-b" bin stop --all >/dev/null 2>&1 </dev/null && fail "stop --all without --yes must fail"
out="$(FAKE_PS_NAMES="pi-a pi-b" bin stop pi-zzz 2>&1)" && fail "stop with an unknown name must fail"
assert_contains "$out" "No session named 'pi-zzz'" "stop names the unknown session"
out="$(FAKE_PS_NAMES="pi-a pi-b" bin stop pi- 2>&1)" && fail "stop with a prefix must fail (exact names only)"
assert_contains "$out" "Did you mean" "stop suggests similar names"
bin stop >/dev/null 2>&1 && fail "stop without a target must fail"
bin doctor --bogus >/dev/null 2>&1 && fail "doctor must reject unknown flags"
bin doctor --fix >/dev/null 2>&1 || fail "doctor --fix must repair and diagnose"

# --- audit --explain ---------------------------------------------------------------
printf '%s\n' '{"ts":"2026-01-01T00:00:00.000Z","tool":"bash","rule":"backstop/unknown-tool","target":"mcp_x"}' \
    '{"ts":"2026-01-02T00:00:00.000Z","tool":"bash","rule":"pi-policy/env-direct-2","target":"printenv"}' >>"$AGENT/audit.log"
out="$(bin audit --explain 2>&1)" || fail "audit --explain must work"
assert_contains "$out" "pi-policy/env-direct-2" "explain defaults to the newest entry"
assert_contains "$out" "Leaks environment variables" "explain shows the rule reason"
assert_contains "$out" "allow edit" "explain tells how to relax vendored rules"
out="$(bin audit --explain 2 2>&1)" || fail "audit --explain 2 must work"
assert_contains "$out" "backstop/unknown-tool" "explain N picks the Nth entry"
assert_contains "$out" "allowed_tools" "explain tells how to allow unknown tools"
bin audit --explain 99 >/dev/null 2>&1 && fail "explain past the end must fail"
bin audit --explain 0 >/dev/null 2>&1 && fail "explain 0 must fail"

# --- run --list / --resume -----------------------------------------------------------
mkdir -p "$AGENT/sessions"
printf '%s\n' '{"type":"session","id":"abc12345-xxxx","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp/proj"}' >"$AGENT/sessions/2026-01-01T00-00-00-000Z_abc12345-xxxx.jsonl"
out="$(bin run --list 2>&1)" || fail "run --list must work without a container"
assert_contains "$out" "abc12345" "run --list shows the session id"
assert_contains "$out" "/tmp/proj" "run --list shows the session project"
rm -f "$AGENT/sessions/2026-01-01T00-00-00-000Z_abc12345-xxxx.jsonl"
out="$(DRY_RUN=true bin run --resume abc123 "$PROJECT" 2>&1)" || fail "run --resume must work"
assert_contains "$out" "--session" "run --resume forwards --session to pi"
assert_contains "$out" "abc123" "run --resume forwards the id"

# ps --json: one JSON object per session (scriptable).
: >"$FAKE_DOCKER_LOG"
out="$(FAKE_PS_NAMES="pi-a pi-b" bin ps --json 2>&1)" || fail "ps --json must work"
assert_contains "$out" '"name":"pi-a"' "ps --json lists sessions as JSON"
printf '%s\n' "$out" | grep -q '^{"name":' || fail "ps --json prints one object per line"

# stats --json: local session files as JSON (no container needed).
touch "$AGENT/sessions/sess-1.json"
out="$(bin stats --json 2>&1)" || fail "stats --json must work"
assert_contains "$out" '"sessions"' "stats --json lists sessions"
assert_contains "$out" 'sess-1.json' "stats --json names session files"
rm -f "$AGENT/sessions/sess-1.json"

# pull: refuses to proceed without cosign unless --no-verify.
out="$(PATH="$FAKE_BIN:/usr/bin:/bin" "$BIN" pull 2>&1)" && fail "pull without cosign must fail"
assert_contains "$out" "cosign is required" "pull explains why it refused"
: >"$FAKE_DOCKER_LOG"
FAKE_PULLED_VERSION=0.16.0 FAKE_PULLED_GUARD=999 bin pull v0.16.0 --no-verify >/dev/null 2>&1 || fail "pull --no-verify"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "pull ghcr.io/yukiteruamano/pi-dockerized:v0.16.0" "pull fetches the requested tag"

# --- Image lifecycle: lock smoke test, downgrade refusal, previous/rollback ----------
# The smoke test also checks the guard lock for a uid other than the image's.
: >"$FAKE_DOCKER_LOG"
bin build >/dev/null 2>&1 || fail "build must succeed with a healthy image"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "--user 4242:4242 --group-add coder --entrypoint /usr/local/lib/pi-dockerized/lock-check.sh" \
    "the smoke test checks the guard lock for another uid"
# pull: an image older than this checkout's guard or wrapper is refused.
: >"$FAKE_DOCKER_LOG"
out="$(FAKE_PULLED_VERSION=0.16.0 FAKE_PULLED_GUARD=1 bin pull v0.16.0 --no-verify 2>&1)" &&
    fail "pull must refuse an image with an older guard"
assert_contains "$out" "older than guard" "pull names the guard downgrade"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "rmi ghcr.io/yukiteruamano/pi-dockerized:v0.16.0" "a refused downgrade is discarded"
assert_not_contains "$(cat "$FAKE_DOCKER_LOG")" "tag ghcr.io/yukiteruamano/pi-dockerized:v0.16.0 pi-dockerized:latest" "a refused downgrade is not promoted"
out="$(FAKE_PULLED_VERSION=0.1.0 FAKE_PULLED_GUARD=999 bin pull v0.1.0 --no-verify 2>&1)" &&
    fail "pull must refuse an older wrapper release"
assert_contains "$out" "older than" "pull names the release downgrade"
out="$(FAKE_IMAGE_VERSION=9.9.9 FAKE_PULLED_VERSION=1.0.0 FAKE_PULLED_GUARD=999 bin pull v1.0.0 --no-verify 2>&1)" &&
    fail "pull must refuse a release older than the current image"
out="$(FAKE_PULLED_VERSION='' FAKE_PULLED_GUARD=999 bin pull v0.16.0 --no-verify 2>&1)" &&
    fail "pull must refuse an image without a version label"
: >"$FAKE_DOCKER_LOG"
FAKE_PULLED_VERSION=0.16.0 FAKE_PULLED_GUARD=1 bin pull v0.16.0 --no-verify --allow-downgrade >/dev/null 2>&1 ||
    fail "pull --allow-downgrade must accept an older image"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "tag ghcr.io/yukiteruamano/pi-dockerized:v0.16.0 pi-dockerized:latest" "an allowed downgrade is promoted"
assert_contains "$(cat "$FAKE_DOCKER_LOG")" "pi-dockerized:0.16.0-guard1" "the version tag names the pulled image's own guard"
# Pull verification only trusts the publish workflow on a version tag.
grep -q 'image\\.yml@refs/tags/v' "$REPO_DIR/lib/cmd/image.sh" || fail "cosign identity must be pinned to image.yml on a version tag"
# Promoting the image already in use keeps the real previous image.
: >"$FAKE_DOCKER_LOG"
FAKE_IMAGE_ID=sha256:same bin build >/dev/null 2>&1 || fail "a no-op rebuild must succeed"
assert_not_contains "$(cat "$FAKE_DOCKER_LOG")" "tag pi-dockerized:latest pi-dockerized:previous" \
    "re-promoting the same image must not overwrite :previous"
# rollback swaps latest and previous, so a second rollback undoes the first.
: >"$FAKE_DOCKER_LOG"
FAKE_IMAGE_ID=sha256:new FAKE_PREVIOUS_ID=sha256:old bin rollback >/dev/null 2>&1 || fail "rollback with distinct images"
log="$(cat "$FAKE_DOCKER_LOG")"
assert_contains "$log" "tag pi-dockerized:previous pi-dockerized:latest" "rollback re-tags previous as latest"
assert_contains "$log" "tag sha256:new pi-dockerized:previous" "rollback keeps the replaced image as previous"
: >"$FAKE_DOCKER_LOG"
FAKE_IMAGE_ID=sha256:same bin rollback >/dev/null 2>&1 || fail "rollback onto the same image is a no-op"
assert_not_contains "$(cat "$FAKE_DOCKER_LOG")" "tag " "rollback onto the same image re-tags nothing"

# --- Self-update: merge the verified commit, pinned release signers ------------------
UPD="$TMP/upd"
mkdir -p "$UPD"
gitq() { git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
gitq init --bare -b master "$UPD/upstream.git"
gitq clone "$UPD/upstream.git" "$UPD/pusher"
(cd "$UPD/pusher" && echo 1 >f && gitq add f && gitq commit -m one && gitq push origin HEAD:master)
gitq clone "$UPD/upstream.git" "$UPD/checkout"
(cd "$UPD/pusher" && echo 2 >f && gitq commit -am two && gitq push origin HEAD:master)
rev_two="$(git -C "$UPD/pusher" rev-parse HEAD)"
out="$(
    # shellcheck source=/dev/null
    source "$REPO_DIR/lib/cmd/update.sh"
    REPO_ROOT="$UPD/checkout"
    # Upstream moves again right after the fetch: only the commit that was
    # fetched (and shown, and verified) may be merged.
    git() {
        command git "$@"
        local rc=$?
        if [ "${3:-}" = fetch ]; then
            (cd "$UPD/pusher" && echo 3 >f && gitq commit -am three && gitq push origin HEAD:master)
        fi
        return "$rc"
    }
    _git_pull_wrapper true false false 2>&1
)" || fail "self-update must fast-forward a clean checkout: $out"
assert_eq "$(git -C "$UPD/checkout" rev-parse HEAD)" "$rev_two" "self-update merges the fetched commit, not a newer one"
signers_case() {
    (
        # shellcheck source=/dev/null
        source "$REPO_DIR/lib/cmd/update.sh"
        git() {
            case "$*" in
            *verify-commit*) return 0 ;;
            *%GF*) echo "SIGNINGKEY" ;;
            *%GP*) echo "PRIMARYKEY" ;;
            esac
        }
        verify_upstream_signature "$UPD/checkout" HEAD 2>&1
    )
}
mkdir -p "$UPD/checkout/.github"
rm -f "$UPD/checkout/.github/release-signers"
out="$(signers_case)" || fail "without a signer list any trusted signature passes"
assert_contains "$out" "any key your git trusts" "verification warns when no signer list is pinned"
printf '%s\n' '# release keys' 'OTHERKEY' >"$UPD/checkout/.github/release-signers"
out="$(signers_case)" && fail "a signature from a key outside release-signers must be refused"
assert_contains "$out" "not in .github/release-signers" "the refusal names the signer list"
printf '%s\n' 'OTHERKEY' ' PRIMARYKEY  # maintainer' >"$UPD/checkout/.github/release-signers"
signers_case >/dev/null || fail "a subkey of a listed primary key must pass"
printf '%s\n' 'SIGNINGKEY' >"$UPD/checkout/.github/release-signers"
signers_case >/dev/null || fail "a listed signing key must pass"

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

validate_container_path /home/coder/.pi/agent/npm/x "x" >/dev/null 2>&1 && fail "a custom mount inside the agent dir must be refused"
validate_container_path /home/coder/.pi/ext-agent/x "x" >/dev/null 2>&1 && fail "a custom mount inside ext-agent must be refused"

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

# --- profile and config commands -----------------------------------------------------------------
# Migration: profiles created implicitly by older versions (directory present,
# config file sometimes missing) must keep working — the existence check is on
# the directory, which every old flow created. Only truly unknown names fail.
mkdir -p "$TMP/root/profiles/legacy/home/.pi/agent" # old profile, no config file
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile legacy config path 2>&1)" ||
    fail "a pre-existing profile from an older version must keep working"
assert_eq "$out" "$TMP/root/profiles/legacy/config" "legacy profiles resolve to their own config"
rm -r "$TMP/root/profiles/legacy"

# A profile must exist before it can be used: a typo must not silently run on
# a fresh empty profile with default settings.
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile work config path 2>&1)" &&
    fail "an unknown profile must be refused"
assert_contains "$out" "does not exist" "the unknown-profile error names the problem"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile create work >/dev/null 2>&1 ||
    fail "profile create"
[ -f "$TMP/root/profiles/work/config" ] || fail "profiles create must seed the profile's config file"
[ -d "$TMP/root/profiles/work/home/.pi/agent" ] || fail "profiles create must seed the profile's state tree"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile create work >/dev/null 2>&1 &&
    fail "creating an existing profile must fail"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile create default >/dev/null 2>&1 &&
    fail "the reserved profile name 'default' must be refused"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile work config path 2>&1)"
assert_eq "$out" "$TMP/root/profiles/work/config" "--profile selects its own config directory"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" config path 2>&1)"
assert_eq "$out" "$TMP/root/profiles/default/config" "the default profile lives in profiles/ like any other"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile default config path 2>&1)"
assert_eq "$out" "$TMP/root/profiles/default/config" "--profile default names the default profile"
env -u CONFIG_DIR -u PI_HOME "$BIN" --profile 'Bad Name' config path >/dev/null 2>&1 && fail "invalid profile names must be rejected"
env -u CONFIG_DIR -u PI_HOME "$BIN" --profile '../evil' config path >/dev/null 2>&1 && fail "path traversal in a profile name must be rejected"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile work config set network bridge >/dev/null 2>&1 || fail "config set in a profile"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile work config get network 2>&1)"
assert_eq "$out" "bridge" "profile settings are stored separately"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile list 2>&1)"
assert_contains "$out" "work" "profile list shows the existing profiles"

# setting.default_profile (root config) picks the profile when --profile is
# not given; a broken value is an error, --profile default escapes it.
printf 'setting.default_profile=work\n' >>"$TMP/root/config"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" config path 2>&1)"
assert_eq "$out" "$TMP/root/profiles/work/config" "setting.default_profile selects the profile"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" --profile default config path 2>&1)"
assert_eq "$out" "$TMP/root/profiles/default/config" "--profile default escapes setting.default_profile"
sed -i 's/^setting\.default_profile=work$/setting.default_profile=nope/' "$TMP/root/config"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" config path >/dev/null 2>&1 &&
    fail "a default_profile pointing at a missing profile must be an error"
sed -i '/^setting\.default_profile=/d' "$TMP/root/config"

# profiles remove deletes the whole tree (confirmation required unless --yes).
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile create scratch >/dev/null 2>&1 ||
    fail "profiles create scratch"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile remove scratch </dev/null 2>&1)"
[ -d "$TMP/root/profiles/scratch" ] || fail "profiles remove without confirmation must not delete"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile remove scratch --yes >/dev/null 2>&1 ||
    fail "profiles remove --yes"
[ ! -d "$TMP/root/profiles/scratch" ] || fail "profiles remove --yes must delete the profile tree"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" profile remove default --yes >/dev/null 2>&1 &&
    fail "the default profile must not be removable"

# Profile names are unique: case or -/_ variants of an existing name are
# refused, by `profile create` and by an implicit `--profile NAME install`.
pr() { env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$TMP/root" "$BIN" "$@"; }
pr profile create work_a >/dev/null 2>&1 || fail "profile create work_a"
out="$(pr profile create work-a 2>&1)" && fail "a -/_ variant of an existing profile must be refused"
assert_contains "$out" "duplicate" "the duplicate-name error names the problem"
pr --profile work-a install --yes --only config >/dev/null 2>&1 && fail "install must not create a duplicate profile"
[ ! -e "$TMP/root/profiles/work-a" ] || fail "a refused duplicate must leave no directory behind"
mkdir "$TMP/root/profiles/Work" # made by hand, outside the wrapper
out="$(pr profile list 2>&1)"
assert_contains "$out" "not a valid profile name" "list reports entries the wrapper cannot use"
assert_contains "$out" "work (duplicate" "list flags a profile that has a look-alike"
rmdir "$TMP/root/profiles/Work"

# A symlinked profile is the same tree under two names: check reports it,
# fix refuses to write through it and remove drops only the link.
ln -s work "$TMP/root/profiles/alias"
out="$(pr profile check work 2>&1)" && fail "check must fail on an aliased profile"
assert_contains "$out" "same directory" "check names the alias"
out="$(pr profile fix alias 2>&1)"
assert_contains "$out" "Not repairing" "fix must not write through a symlinked profile"
pr profile remove alias --yes >/dev/null 2>&1 || fail "profile remove of an alias"
[ -d "$TMP/root/profiles/work" ] || fail "removing an alias must keep the real profile"
pr profile remove work_a --yes >/dev/null 2>&1 || fail "profile remove work_a"

# check/fix audit and repair the whole profile: config file, root-only
# entries, borrowed secrets, permissions and the state tree.
WORK="$TMP/root/profiles/work"
assert_contains "$(cat "$WORK/config")" "profiles/work/env" "a profile's config template points at its own secrets file"
out="$(pr profile check work 2>&1)" || fail "a fresh profile must pass check (got: $out)"
printf 'setting.default_profile=work\nprofile.map.x=~/x:work\nsetting.env_file=%s/env\n' "$TMP/root" >>"$WORK/config"
chmod 644 "$WORK/config"
rm "$WORK/home/.pi/agent/mcp.json" "$WORK/home/.pi/agent/auth.json"
out="$(pr profile check work 2>&1)" && fail "check must fail on a damaged profile"
assert_contains "$out" "root-only" "check reports root-only entries in a profile"
assert_contains "$out" "outside this profile" "check reports secrets borrowed from another profile"
assert_contains "$out" "mcp.json missing" "check reports a missing state file"
[ ! -e "$WORK/home/.pi/agent/mcp.json" ] || fail "check must not write"
(umask 077 && : >"$WORK/env")
out="$(pr profile fix work 2>&1)" || fail "fix must leave a healthy profile (got: $out)"
assert_contains "$out" "is healthy" "fix ends with a passing check"
[ -f "$WORK/home/.pi/agent/mcp.json" ] && [ -s "$WORK/home/.pi/agent/auth.json" ] || fail "fix reseeds the state tree"
assert_eq "$(stat -c '%a' "$WORK/config")" "600" "fix restores the config file permissions"
assert_contains "$(cat "$WORK/config")" "# (root config only, ignored in a profile) setting.default_profile=work" "fix comments out root-only entries"
assert_contains "$(cat "$WORK/config")" "setting.env_file=$WORK/env" "fix points env_file at the profile's own secrets file"
ls "$WORK"/config.bak.* >/dev/null 2>&1 || fail "fix backs up the config before editing it"

# The default profile's check also covers the root config's routing, and
# `profile` keeps working while default_profile dangles.
printf 'setting.default_profile=gone\n' >>"$TMP/root/config"
out="$(pr profile check default 2>&1)" && fail "check default must fail on a dangling default_profile"
assert_contains "$out" "default_profile=gone" "check default names the dangling default_profile"
sed -i '/^setting\.default_profile=gone$/d' "$TMP/root/config"

# show/path/run act on the named profile; config profiles points at profile.
assert_eq "$(pr profile path work)" "$WORK" "profile path prints the profile directory"
assert_eq "$(pr --profile work profile path)" "$WORK" "profile path defaults to the active profile"
assert_contains "$(pr profile show work 2>&1)" "Network:            bridge" "profile show prints that profile's settings"
pr profile show nope >/dev/null 2>&1 && fail "profile show must refuse a missing profile"
out="$(DRY_RUN=true PATH="$FAKE_BIN:$PATH" pr profile run work "$PROJECT" 2>&1)" || fail "profile run dry-run (got: $out)"
assert_contains "$out" "pi-dockerized.profile=work" "profile run starts the session under that profile"
out="$(pr config profiles 2>&1)" && fail "config profiles moved to the profile command"
assert_contains "$out" "profile list" "config profiles points at the profile command"

# The default profile must not take a named profile's secrets file.
pr --profile default config set env_file "$WORK/env" >/dev/null 2>&1 || fail "config set env_file in the default profile"
out="$(DRY_RUN=true PATH="$FAKE_BIN:$PATH" pr run "$PROJECT" 2>&1)" && fail "the default profile must refuse a named profile's secrets file"
assert_contains "$out" "another profile" "the refusal explains the secrets mix-up"
pr --profile default config set env_file "" >/dev/null 2>&1

# default_profile is routing: `config set` writes it to the root config from
# any profile, and refuses a profile that does not exist.
pr --profile work config set default_profile work >/dev/null 2>&1 || fail "config set default_profile"
assert_contains "$(cat "$TMP/root/config")" "setting.default_profile=work" "default_profile is written to the root config"
assert_not_contains "$(cat "$WORK/config")" $'\nsetting.default_profile=work' "default_profile never lands in a profile's config"
assert_eq "$(pr --profile default config get default_profile)" "work" "config get default_profile reads the root config"
pr config set default_profile nope >/dev/null 2>&1 && fail "default_profile must name an existing profile"
pr config set default_profile "" >/dev/null 2>&1 || fail "clearing default_profile"
assert_eq "$(pr profile root path)" "$TMP/root/config" "profile root path prints the routing config"

# --- Migration from the old layout (default profile in the config root) ---------------------
# Up to 0.16 the default profile's config, secrets file and state lived in
# the root itself. The first run of the new wrapper moves them into
# profiles/default, keeps routing in the root config and follows env_file.
LEGACY="$HOME/legacy-cfg"
mkdir -p "$LEGACY/home/.pi/agent/sessions" "$LEGACY/profiles/work"
: >"$LEGACY/profiles/work/config"
printf '# my comment\nsetting.network=bridge\nsetting.env_file=~/legacy-cfg/env\nsetting.default_profile=work\nprofile.map.w=~/w:work\nmount.x=/opt/x:/opt/x\n' >"$LEGACY/config"
(umask 077 && printf 'ANTHROPIC_API_KEY=x\n' >"$LEGACY/env")
: >"$LEGACY/home/.pi/agent/sessions/s1.jsonl"
: >"$LEGACY/config.bak.20250101000000"
lg() { env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$LEGACY" "$BIN" "$@"; }
out="$(lg --profile default config path 2>/dev/null)" || fail "the first run after an upgrade must migrate and continue"
assert_eq "$out" "$LEGACY/profiles/default/config" "migration output stays off stdout"
D="$LEGACY/profiles/default"
[ -f "$D/env" ] && [ -f "$D/home/.pi/agent/sessions/s1.jsonl" ] && [ -f "$D/config.bak.20250101000000" ] ||
    fail "migration moves the secrets file, the state tree and the backups"
[ ! -e "$LEGACY/env" ] && [ ! -e "$LEGACY/home" ] || fail "migration leaves nothing of the old profile in the root"
[ ! -e "$LEGACY/profiles/.default.migrating" ] || fail "migration removes its staging directory"
assert_eq "$(stat -c '%a' "$D/env")" "600" "migration keeps the secrets file private"
root_cfg="$(cat "$LEGACY/config")"
assert_contains "$root_cfg" "setting.default_profile=work" "the root config keeps default_profile"
assert_contains "$root_cfg" "profile.map.w=~/w:work" "the root config keeps profile.map"
assert_not_contains "$root_cfg" "setting.network" "profile settings leave the root config"
def_cfg="$(cat "$D/config")"
assert_contains "$def_cfg" "# my comment" "the default profile's config keeps the user's comments"
assert_contains "$def_cfg" $'\nsetting.network=bridge' "the default profile keeps its settings"
assert_contains "$def_cfg" "mount.x=/opt/x:/opt/x" "the default profile keeps its mounts"
assert_contains "$def_cfg" "setting.env_file=~/legacy-cfg/profiles/default/env" "env_file follows the moved secrets file"
assert_contains "$def_cfg" "# (root config only, ignored in a profile) setting.default_profile=work" "routing lines are commented out in the profile"
assert_eq "$(lg config path 2>/dev/null)" "$LEGACY/profiles/work/config" "default_profile still routes after the migration"
out="$(lg --profile default config path 2>&1)"
assert_not_contains "$out" "Moving" "the migration runs once"
out="$(lg profile fix default 2>&1)" || fail "fix must make a migrated default profile healthy (got: $out)"
assert_contains "$out" "root config ok" "the migrated root config passes its check"
# An interrupted migration (some entries already staged) resumes.
LEGACY2="$HOME/legacy-cfg2"
mkdir -p "$LEGACY2/profiles/.default.migrating/home" "$LEGACY2/gnupg-relay"
printf 'setting.network=bridge\n' >"$LEGACY2/config"
out="$(env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$LEGACY2" "$BIN" --profile default config get network 2>/dev/null)" ||
    fail "an interrupted migration must resume"
assert_eq "$out" "bridge" "the resumed migration keeps the settings"
[ -d "$LEGACY2/profiles/default/home" ] && [ -d "$LEGACY2/profiles/default/gnupg-relay" ] ||
    fail "the resumed migration gathers staged and remaining entries"
# A root config with only routing (or nothing at all) is the new layout.
NEWROOT="$HOME/new-cfg"
mkdir -p "$NEWROOT"
printf 'setting.default_profile=\n' >"$NEWROOT/config"
env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$NEWROOT" "$BIN" config path >/dev/null 2>&1
assert_eq "$(cat "$NEWROOT/config")" "setting.default_profile=" "a routing-only root config is left alone"
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
PURGE_DIR="$HOME/.config/purge-test/pi-dockerized"
mkdir -p "$PURGE_DIR"
CONFIG_DIR="$PURGE_DIR" bin uninstall --purge-config --yes >/dev/null 2>&1 || fail "uninstall --purge-config"
[ ! -d "$PURGE_DIR" ] || fail "--purge-config must delete the config dir"
[ -d "$CONFIG_DIR" ] || fail "--purge-config must only touch the profile it was asked for"
OUTSIDE="$TMP/not-in-home"
mkdir -p "$OUTSIDE"
CONFIG_DIR="$OUTSIDE" bin uninstall --purge-config --yes >/dev/null 2>&1
[ -d "$OUTSIDE" ] || fail "--purge-config must refuse directories outside the home"
# Never another app's directory or ~/.config itself.
mkdir -p "$HOME/.config/other-app"
CONFIG_DIR="$HOME/.config" bin uninstall --purge-config --yes >/dev/null 2>&1
CONFIG_DIR="$HOME/.config/other-app" bin uninstall --purge-config --yes >/dev/null 2>&1
[ -d "$HOME/.config/other-app" ] || fail "--purge-config must refuse ~/.config and non pi-dockerized dirs"
# --purge-config deletes the active profile only; --all-profiles the root.
PURGE_DIR="$HOME/.config/purge-test/pi-dockerized"
mkdir -p "$PURGE_DIR/profiles/work" "$PURGE_DIR/profiles/default"
: >"$PURGE_DIR/config"
purge() { env -u CONFIG_DIR -u PI_HOME PI_CONFIG_ROOT="$PURGE_DIR" PATH="$FAKE_BIN:$PATH" "$BIN" uninstall --purge-config "$@"; }
purge --yes >/dev/null 2>&1 || fail "purge with profiles"
[ ! -e "$PURGE_DIR/profiles/default" ] || fail "--purge-config must delete the default profile"
[ -d "$PURGE_DIR/profiles/work" ] && [ -f "$PURGE_DIR/config" ] || fail "--purge-config must keep other profiles and the routing config"
purge --all-profiles --yes >/dev/null 2>&1 || fail "purge --all-profiles"
[ ! -d "$PURGE_DIR" ] || fail "--all-profiles must delete every profile"
bin uninstall --all-profiles >/dev/null 2>&1 && fail "--all-profiles needs --purge-config"

echo "All wrapper-commands tests passed."
