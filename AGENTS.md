# Agent Guidelines for Pi Dockerized

## Project Overview

Shell script-based Docker wrapper for running [Pi](https://github.com/earendil-works/pi)
(`@earendil-works/pi-coding-agent`) in secure, isolated containers. Sandboxes Pi
so its blast radius is limited to the mounted project directory. Source is Bash
scripts, a Dockerfile, one TypeScript security extension
(`extensions/pi-security-guard/`) with dependency-free policy logic
(`policy.mjs`) and vendored JSON policy data (`policies/`), plus Node/Bash tests.
No package manager files and no build step for the wrapper itself.

**Key files:**
- `bin/pi-dockerized` — Main wrapper, no extension (run, auth, models, exec, mcp,
  extensions, stats, doctor, install, upgrade, update, build, version, config,
  clean). Reached via `<install>/bin` on PATH; `bin/` holds only this binary.
- `install.sh` — Curl-able bootstrap: runs the local `bin/pi-dockerized install`
  when present, else clones to `~/.local/share/pi-dockerized` and runs it there.
- `lib/config-lib.sh` — Shared library sourced by other scripts (config parsing,
  mount/env arg building, host-state seeding, interactive prompts). **Not
  executable directly.**
- `lib/install-lib.sh` — Install wizard library sourced by the wrapper's
  `install` command. **Not executable directly.**
- `pi-dockerized.sh`, `setup.sh` (root) — Compat shims forwarding to `bin/`+`lib/`.
- `Dockerfile` — Container image (Debian trixie-slim + Node.js/NVM + pnpm + uv +
  Pi; bakes `container/`, `extensions/` and the packages in `install-extensions`).
- `entrypoint.sh` — Container entrypoint (unprivileged; resolves workdir, loads
  NVM, sets `PI_CODING_AGENT_DIR`, execs the command).
- `container/settings.base.json`, `container/AGENTS.md` — Baked Pi config/agents
  rules (copied into the image's agent dir).
- `install-extensions` — Build-time manifest of `pi install` sources.
- `extensions/pi-security-guard/` — Security extension (`index.ts`,
  `policy.mjs`, `policies/`).
- `policies/` — Vendored `opencode-policy` pattern sets (source for the guard).
- `tests/` — `security-guard.test.mjs`, `wrapper-args.test.sh`.
- `SECURITY.md`, `CONTRIBUTING.md` — Security model and contribution guide.
- `examples/config.example` — Example user config (INI).
- Completions: `completions/{bash,zsh}.sh`.

## Build / Test / Lint Commands

```bash
# Core operations
./install.sh                                  # install bin/ on PATH + config
bin/pi-dockerized build                       # Build Docker image (bakes extensions)
bin/pi-dockerized run [DIR]                   # Run Pi (default: current dir)
bin/pi-dockerized auth                        # Check provider credentials
bin/pi-dockerized upgrade --check             # Check for updates from GitHub
bin/pi-dockerized update [--check|--yes|--no-build]
pi-dockerized models                          # List models (pi --list-models)
pi-dockerized exec MSG                        # Non-interactive prompt (pi --print)
pi-dockerized mcp [ARGS]                      # MCP servers (default: list)
pi-dockerized extensions                      # List installed extensions (pi list)
pi-dockerized stats                           # Session usage statistics
pi-dockerized doctor                          # Diagnose guard, config, forwarding
pi-dockerized version                         # Wrapper + guard + Pi versions
pi-dockerized config show|edit|path|sync      # Wrapper INI config
pi-dockerized config pi [path|edit]           # mcp.json
pi-dockerized clean                           # Remove Docker image
DRY_RUN=true pi-dockerized run                # Print the docker command

# Validation
bash -n bin/pi-dockerized install.sh entrypoint.sh
bash -n lib/*.sh completions/*.sh
shellcheck -x -S warning bin/* lib/*.sh install.sh completions/*.sh
cat Dockerfile | docker run --rm -i hadolint/hadolint:latest hadolint -
node --check extensions/pi-security-guard/policy.mjs
node tests/security-guard.test.mjs
bash tests/wrapper-args.test.sh

# Docker operations
docker build -t pi-dockerized:latest .
docker run --rm pi-dockerized:latest pi --version
```

CI (`.github/workflows/ci.yml`) runs `bash -n`, `shellcheck`, `hadolint`, the
policy test and the wrapper contract test. `shellcheck`/`hadolint` are not
installed in this container — run them via their official images.

## Code Style Guidelines

### File Header

Every executable shell script starts with:
```bash
#!/bin/bash
set -e  # Exit on first error
```

**Exception:** `lib/config-lib.sh` and `lib/install-lib.sh` are libraries sourced
by callers — they must **not** use `set -e`.

### Script Initialization

```bash
BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$BIN_DIR/.." && pwd)"
source "$REPO_ROOT/lib/config-lib.sh"
```

### Naming Conventions

| Type              | Convention         | Examples                                      |
|-------------------|--------------------|-----------------------------------------------|
| Shell scripts     | kebab-case / no ext in bin/ | `bin/pi-dockerized`, `run-simple.sh` |
| Functions         | snake_case         | `check_docker()`, `build_image()`             |
| Constants         | UPPER_SNAKE        | `IMAGE_NAME`, `REPO_ROOT`, `CONFIG_DIR`       |
| Local variables   | lower_snake        | `project_dir`, `container_name`               |
| Global arrays     | UPPER_SNAKE        | `CUSTOM_MOUNTS=()`, `DOCKER_MOUNT_ARGS=()`    |
| Booleans          | UPPER_SNAKE=false  | `SSH_AGENT_SUPPORT=false`                     |
| Docker images     | kebab-case:tag     | `pi-dockerized:latest`                        |
| Container names   | kebab-case-suffix  | `pi-myproject-abc123`                         |

### Variable Handling

- **Always quote variables:** `"$variable"` not `$variable`
- **Command substitution:** `$()` not backticks
- **Declare and assign separately:** `local dir_name; dir_name=$(...)` (SC2155)
- **Defaults with `:=`:** `CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/pi-dockerized}"`
- **Use arrays for Docker args:** never build docker args as strings.

### Color Output / Logging

```bash
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
```

In `lib/config-lib.sh`, use fallback wrappers that delegate to the caller's
functions if defined (`config_info` → `print_info`).

### Error Handling

- Check prerequisites before operations (`check_docker`, `check_image`).
- Validate project directories before `cd`; `validate_project_dir` refuses `/`,
  `$HOME` and its ancestors.
- Print an explicit error with `print_error()` then `exit 1`.
- Suppress expected failures: `2>/dev/null || true`.
- Always use `read -r`.
- Validate env var names: `[[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]`.

### Shared Logic (lib/config-lib.sh)

- `PI_HOME` (`~/.config/pi-dockerized/home`) — self-contained host state root
  mirroring the container home; all mounts source from here.
- `ensure_pi_dirs` / `ensure_pi_state` — create the host agent tree and seed
  `mcp.json`, `skills/`, `sessions/` and the runtime state files.
- `build_standard_volume_args "$project_dir" [docker_socket]` — populates
  `VOLUME_ARGS` (project rw; `mcp.json` ro; `skills/`, `sessions/`,
  `auth.json`, `mcp-auth.json`, `trust.json`, `mcp.log`, `.npm` rw; `~/.claude`
  and `~/.agents` ro; optional docker socket).
- `build_common_docker_args` — populates `DOCKER_COMMON_ARGS` (`--rm`,
  `--network`, `--user`, `--group-add coder`, `--cap-drop=ALL`,
  `no-new-privileges`, `PI_CODING_AGENT_DIR`, `PI_SKIP_VERSION_CHECK=1`,
  `PI_TELEMETRY`, `PI_DOCKERIZED_POLICY`).
- `check_pi_state` / `sync_pi_state` — validate/repair host state (`config sync`).
- GPG/SSH forwarding helpers: `ensure_gpg_mirror`,
  `resolve_gpg_agent_socket`/`_extra_socket`, `start_gpg_relay`/`stop_gpg_relay`.

### Config File Format

INI-style (`key.name=value`), parsed with `while IFS='=' read -r key value`:
```ini
setting.ssh_agent_support=true
setting.gpg_agent_support=false
setting.docker_socket=false
setting.network=host
setting.security_policy=balanced
setting.memory=4g
setting.cpus=2
setting.env_file=~/.config/pi-dockerized/env
setting.theme=system
setting.model=sonnet
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
```

Secrets only travel via `setting.env_file` (dotenv under the config dir,
`docker --env-file`, never mounted).

### Dockerfile Conventions

- Base image `debian:trixie-slim` (pinned); `SHELL ["/bin/bash", "-o", "pipefail", "-c"]`.
- Parameterize versions via `ARG`: `NVM_VERSION`, `PNPM_VERSION`, `PI_VERSION`.
- Install global packages with `pnpm add -g` (pass `--allow-build` when a package
  needs lifecycle scripts); keep `npx` available for `npx`-based MCP servers.
- Clean apt caches in the same `RUN` layer; Docker CLI only (never the daemon).
- No privilege escalation: no `sudo` binary/sudoers; run as non-root `coder`.
- Baked resources are locked with `chmod -R a-w` (agent dir + Pi package dir).
- Cache-busting `ARG PI_BUILD_TIME` only used by `update`, not regular `build`.

### Security Rules

- The agent dir is baked and immutable; only `skills/`, `sessions/` and the
  runtime state files are bind-mounted read-write; `mcp.json` is mounted
  read-only. `$CONFIG_DIR` is never mounted.
- **Never commit:** `.env`, `auth.json`, `*.pem`, `*.key`, credentials.
- Docker socket, SSH and GnuPG forwarding are all opt-in and off by default.
- `setting.security_policy` (`strict|balanced|off`) is passed to the guard as
  `PI_DOCKERIZED_POLICY`.
- `extensions/pi-security-guard/index.ts` + `policy.mjs` are the guard source of
  truth; bump `PI_DOCKERIZED_GUARD_VERSION` when behavior changes.
- Writes are allowed only inside the project directory and `/tmp/pi`.
- Prefer `policies/allow-patterns.json` or a policy mode over editing the
  vendored `policies/*.json`.

## Volume Mounts Reference

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `$PROJECT_DIR` | `$PROJECT_DIR` (`$HOME` stripped) | rw | Project files |
| `home/.pi/agent/mcp.json` | `/home/coder/.pi/agent/mcp.json` | **ro** | MCP servers (host-edited) |
| `home/.pi/agent/skills/` | `/home/coder/.pi/agent/skills/` | **rw** | Skills |
| `home/.pi/agent/sessions/` | `/home/coder/.pi/agent/sessions/` | rw | Sessions |
| `home/.pi/agent/{auth,mcp-auth,trust}.json`, `mcp.log` | idem | rw | Runtime state |
| `home/.npm/` | `/home/coder/.npm/` | rw | npm cache |
| `~/.claude/`, `~/.agents/` | idem | ro | Compat skills |
| `~/.composio/` | idem | rw | Composio CLI (custom mount) |
| `/var/run/docker.sock` | idem | rw (opt-in) | Docker socket |
| `home/.gnupg/` | `/home/coder/.gnupg/` | rw (opt-in) | Mirrored public GnuPG material |

Not mounted (baked read-only): `settings.json`, `AGENTS.md`, `extensions/`,
`prompts/`, `themes/`, `models.json`. The wrapper's own `~/.config/pi-dockerized/`
is never mounted.
