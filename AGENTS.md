# Agent Guidelines for Pi Dockerized

## Project Overview

Shell script-based Docker wrapper for running [Pi](https://github.com/earendil-works/pi)
(`@earendil-works/pi-coding-agent`) in secure, isolated containers. Sandboxes Pi
so its blast radius is limited to the mounted project directory. Source is Bash
scripts, a Dockerfile, one TypeScript security extension
(`extensions/pi-security-guard/`) with dependency-free policy logic
(`policy.mjs`, `backstops.mjs`, `shell.mjs`) and vendored JSON policy data
(`policies/`), plus Node/Bash tests.
No package manager files and no build step for the wrapper itself.

**Key files:**
- `bin/pi-dockerized` — Main wrapper, no extension: parses `--profile`, sources
  the libraries and dispatches (run, exec, shell, auth, models, mcp, extensions,
  stats, doctor, audit, ps, stop, install, uninstall, upgrade, update, build,
  pull, rollback, version, config, profile, clean). Reached via `<install>/bin` on PATH;
  `bin/` holds only this binary.
- `install.sh` — Curl-able bootstrap: runs the local `bin/pi-dockerized install`
  when present, else clones to `~/.local/share/pi-dockerized` and runs it there.
- `lib/config-lib.sh` — Loader for the shared library sourced by other scripts.
  The code lives in `lib/config/`, one responsibility per module: `core.sh`
  (constants, profiles, logging `print_*`, path helpers), `mount-policy.sh`
  (what may be mounted and where), `state.sh` (host-state seeding/sync/perms),
  `gpg-ssh.sh` (agent forwarding), `docker-args.sh` (docker run args, incl.
  `build_pi_args`), `settings.sh` (config file I/O, `config get/set`),
  `layout.sh` (root routing config and the migration from the old layout),
  `parse.sh` (mounts/env args), `overrides.sh` (`--untrusted`/`--policy`/
  `--network` session flags) and `prompts.sh` (interactive setup, output).
  **Not executable directly.** Keep each module under ~500 lines.
- `lib/cmd/` — Command modules sourced by the wrapper: `session.sh` (run/exec/
  shell/auth/doctor/…: `prepare_session` → `build_session_cmd` →
  `launch_session`), `image.sh` (build/pull/rollback/clean/version), `update.sh`,
  `config.sh` (config + audit), `profile.sh` (every named-profile operation:
  list/create/remove/show/path/check/fix/run) and `help.sh`. **Not executable
  directly.**
- `lib/install-lib.sh` + `lib/install/` — Install/uninstall wizard sourced by the
  wrapper (`rc.sh`, `sections.sh`, `uninstall.sh`). **Not executable directly.**
- `pi-dockerized.sh`, `setup.sh`, `run-simple.sh` (root) — removed (were deprecated compat shims).
- `Dockerfile` — Container image (digest-pinned Debian trixie-slim + Node.js/NVM +
  pnpm + uv + Pi + qmd; bakes `container/` and the guard from `extensions/`;
  no extensions are installed at build time).
- `entrypoint.sh` — Container entrypoint (unprivileged; resolves workdir, runs the
  guard self-test, sets `PI_CODING_AGENT_DIR`, execs the command).
- `container/settings.base.json`, `container/AGENTS.md` — Baked Pi config/agents
  rules (copied into the image's agent dir; `settings.base.json` is also baked as
  a reference copy in `/usr/local/lib/pi-dockerized/`). `container/doctor.sh`,
  `container/auth-check.sh` — in-container diagnostics; `container/ext-install.sh`
  — runs the official Pi package commands for `extensions`;
  `container/ext-agent.mjs` — seeds/enforces/checks the settings' security keys;
  `container/lock-check.sh` — asserts the guard is root-owned and out of the
  session's reach (all baked root-owned).
- `extensions/pi-security-guard/` — Security extension (`index.ts`,
  `policy.mjs`, `backstops.mjs`, `shell.mjs`, `selftest.mjs`,
  `balanced-excluded.json`, `policies/`).
- `policies/` — vendored policy pattern sets (upstream `opencode-policy` source for the guard);
  `scripts/refresh-policies.sh` refreshes them.
- `tests/` — `security-guard.test.mjs`, `guard-extension.test.mjs`,
  `ext-agent.test.mjs`, `wrapper-args.test.sh`, `wrapper-commands.test.sh`.
- `CHANGELOG.md` — Release notes; `renovate.json` — dependency updates.
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
bin/pi-dockerized update [--check|--yes|--no-build|--verify|--pi-version X]
pi-dockerized models                          # List models (pi --list-models)
pi-dockerized exec [FLAGS] MSG|-              # Non-interactive prompt (pi --print)
pi-dockerized shell [FLAGS] [DIR]             # Shell inside the sandbox
pi-dockerized mcp [ARGS]                      # MCP servers (default: list)
pi-dockerized extensions list|install|remove|update|path|edit   # Pi Packages (official Pi install)
pi-dockerized stats                           # Session usage statistics
pi-dockerized doctor                          # Diagnose guard, config, forwarding
pi-dockerized audit [-n N|--summary|--clear]  # Calls the guard blocked
pi-dockerized ps | stop NAME|--all            # Running sessions
pi-dockerized pull [TAG] [--no-verify|--allow-downgrade]  # Prebuilt signed image
pi-dockerized rollback                        # Previous image back to latest
pi-dockerized version                         # Wrapper, image, guard, policies, Pi
pi-dockerized config show|edit|get|set|path|sync            # Wrapper INI config
pi-dockerized profile [list|create NAME|remove NAME [--yes]]  # Named profiles
pi-dockerized profile show|path|check|fix [NAME]  # Inspect, audit, repair one
pi-dockerized profile run NAME [RUN ARGS]         # = --profile NAME run
pi-dockerized config pi|allow [path|edit]     # mcp.json / guard allow.json
pi-dockerized uninstall [--image] [--purge-config [--all-profiles]]
pi-dockerized clean                           # Remove Docker image (all tags)
pi-dockerized --profile NAME <command>        # Separate config/keys/state
DRY_RUN=true pi-dockerized run                # Print the docker command

# Validation
bash -n bin/pi-dockerized install.sh entrypoint.sh
for f in lib/*.sh lib/*/*.sh completions/*.sh scripts/*.sh container/*.sh tests/*.sh; do bash -n "$f"; done
shellcheck -x -S warning bin/* lib/*.sh lib/*/*.sh install.sh entrypoint.sh scripts/*.sh container/*.sh completions/*.sh tests/*.sh
cat Dockerfile | docker run --rm -i hadolint/hadolint:v2.12.0 hadolint -
for f in extensions/pi-security-guard/*.mjs container/*.mjs; do node --check "$f"; done
node tests/security-guard.test.mjs
node tests/guard-extension.test.mjs
node tests/ext-agent.test.mjs
bash tests/wrapper-args.test.sh
bash tests/wrapper-commands.test.sh

# Docker operations
docker build -t pi-dockerized:latest .
docker run --rm pi-dockerized:latest pi --version
```

CI (`.github/workflows/ci.yml`) runs `bash -n`, `shellcheck`, `hadolint`, the
guard tests (Node 22 and 24), both wrapper contract tests and, on pull requests
and pushes to master, the GUARD_VERSION-increase check. `image.yml` smoke-tests
(amd64 + arm64), signs and then tags the multi-arch
image on version tags; `security.yml` runs gitleaks and Trivy. Actions are
pinned by commit SHA. `shellcheck`/`hadolint` are not installed in this
container — run them via their official images. Docker is not reachable from
the agent sandbox, so image changes cannot be built or smoke-tested here.

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
| Shell scripts     | kebab-case / no ext in bin/ | `bin/pi-dockerized`, `install.sh` |
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

`print_info`, `print_success`, `print_warning` and `print_error` live in
`lib/config/core.sh` (`config_*` are aliases). They use `printf` (never
`echo -e`: a path or config value may contain backslashes or escape bytes),
strip control characters from the text, and send warnings and errors to
stderr so command output stays pipeable. Color codes are plain variables
(`RED`, `NC`, …) honoring `NO_COLOR`.

### Error Handling

- Check prerequisites before operations (`check_docker`, `check_image`).
- Validate project directories before `cd`; `validate_project_dir` refuses `/`,
  `$HOME` and its ancestors.
- Print an explicit error with `print_error()` then `exit 1`.
- Suppress expected failures: `2>/dev/null || true`.
- Always use `read -r`.
- Validate env var names: `[[ "$var_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]`.

### Shared Logic (lib/config/)

- `PI_HOME` (`~/.config/pi-dockerized/profiles/<name>/home`) — self-contained host state root
  mirroring the container home; all mounts source from here.
- `PI_CONFIG_ROOT` / `PI_PROFILE` / `CONFIG_DIR` — the root of all wrapper
  configs, the active profile (`--profile`) and its directory.
- `ensure_pi_dirs` / `ensure_pi_state` — create the host agent tree and seed
  `mcp.json`, `skills/`, `sessions/`, `audit.log` and the runtime state files;
  `harden_state_permissions` keeps the tree `0700`/`0600`.
- `build_standard_volume_args "$project_dir" [docker_socket]` — populates
  `VOLUME_ARGS` (project rw; `mcp.json`, `skills/` and `allow.json` ro;
  `sessions/`, `auth.json`, `mcp-auth.json`, `trust.json`, `mcp.log`,
  `audit.log`, `.npm`, `.cache/qmd` rw; `~/.claude` and `~/.agents` ro; optional
  docker socket). Returns 1 when the project would shadow a system path. The
  state shared between sessions (MCP state, caches, compat skills) is added by
  `build_shared_state_args`, which `--untrusted` skips.
- `build_common_docker_args` — populates `DOCKER_COMMON_ARGS` (`--rm`,
  `--network`, `--user`, `--group-add coder`, `--cap-drop=ALL`,
  `no-new-privileges`, `--label pi-dockerized=1`, `PI_CODING_AGENT_DIR`,
  `PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY`, `PI_DOCKERIZED_POLICY`,
  `PI_DOCKERIZED_ALLOWED_TOOLS`, `PI_DOCKERIZED_ALLOW_FILE`,
  `PI_DOCKERIZED_AUDIT_FILE`).
- `validate_mount_source` / `validate_container_path` (`mount-policy.sh`) — the
  only gate for custom mounts, the project mount (`resolve_project_dir`) and the
  git-worktree mount; extend their lists rather than special-casing in callers.
  Sources are refused when they are, contain or sit inside a protected path
  (credential stores, config/state roots, socket dirs, `/proc|/sys|/dev`);
  targets when they contain or sit inside a system path or the agent dir.
- `_setting_spec` (`settings.sh`) — the single definition of every setting; the
  loader, `config set` and `save_config` all use it. Add new settings there and
  to `SETTING_KEYS`.
- `parse_session_flags` / `apply_session_overrides` — per-invocation flags.
- `prepare_session` → `build_session_cmd` → `launch_session` (`lib/cmd/session.sh`)
  — every container command goes through these three.
- `EXT_AGENT_DIR` / `run_ext_install` (`lib/cmd/extensions.sh`) — Pi Packages:
  only the official Pi package commands (never a custom installer, never local
  paths: `validate_ext_source`). They run in a throwaway rw container (bridge
  network, no env file, no project) with the agent dir set to `EXT_AGENT_DIR`;
  `build_standard_volume_args` mounts that directory's `settings.json`, `npm/` and
  `git/` ro over the agent's own once something is installed (never for
  `--untrusted`); `entrypoint.sh` checks the settings' security keys.
- `test_seam VAR` — variables that execute commands or pick paths the wrapper
  deletes/forwards (`GPG_RELAY_DIR`, `GPG_AGENT_SOCKET`, …) are honored only
  with `PI_DOCKERIZED_TEST=1`.
- `env_key_forbidden` (`parse.sh`) — secrets-file keys that are refused
  (`LD_*`, `NODE_OPTIONS`, `PI_DOCKERIZED_*`, …).
- `check_pi_state` / `sync_pi_state` — validate/repair host state (`config sync`).
- GPG/SSH forwarding helpers: `ensure_gpg_mirror`,
  `resolve_gpg_agent_socket`/`_extra_socket`, `start_gpg_relay`/`stop_gpg_relay`.
  Sessions run concurrently: anything a container writes to (the GnuPG mirror,
  `GPG_MIRROR_DIR`) or the wrapper starts (the relay) is per session, named
  after the wrapper's PID, removed by `_session_cleanup`, and treated as stale
  only when that PID is gone (`session_entry_alive`). Never reintroduce shared
  writable agent state.

### Config File Format

INI-style (`key.name=value`), parsed with `while IFS='=' read -r key value`:
```ini
setting.ssh_agent_support=true
setting.gpg_agent_support=false
setting.docker_socket=false
setting.network=host
setting.security_policy=balanced
setting.allowed_tools=
setting.verify_updates=false
setting.memory=4g
setting.cpus=2
setting.pids_limit=4096
setting.env_file=~/.config/pi-dockerized/profiles/default/env
setting.theme=system
setting.model=sonnet
setting.default_profile=
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
profile.map.work=~/work:acme
```

Profiles are created explicitly (`profile create NAME` or
`--profile NAME install`, both through `claim_profile_dir`: atomic `mkdir`,
case and `-`/`_` look-alikes refused); any other command naming an unknown
profile exits 3 (`profile` itself is exempt so a dangling default can be
repaired). A profile inherits nothing from the root config, and its
`env_file` must resolve inside its own directory (`env_file_in_profile`;
profiles are siblings, so none can reach another's). `profile check|fix` audit
and repair one profile; they reuse `check_agent_state`/`repair_agent_state`
(`state.sh`), the per-profile halves of `config sync`.
`setting.default_profile` and `profile.map.*` are read from the ROOT config
only (bin/pi-dockerized resolves them before the library loads; `profile_for_dir`
in `core.sh` does the longest-prefix mapping, `maybe_switch_mapped_profile` in
`lib/cmd/session.sh` re-execs with `--profile`). `--profile default` names the
default profile (`profiles/default`, like any other). The root config
(`ROOT_CONFIG_FILE`) holds only routing: `config set default_profile` writes it
from any profile and `profile root edit` opens it. `layout.sh` owns it and
`migrate_legacy_layout`, run by `main` before any command: up to 0.16 the
default profile lived in the root itself, and the first run moves it into
`profiles/default` (staged in `profiles/.default.migrating`, renamed when
complete; resumable; `env_file` rewritten; routing kept in the root).
`update`/`upgrade` sync with the freshly pulled binary so it migrates at once.
Sessions carry a `pi-dockerized.profile` label.

Secrets only travel via `setting.env_file` (dotenv under the profile dir,
`docker --env-file`, never mounted). The loader reads the file in one pass and
reports unknown settings, invalid values and stray lines with their line number.
`config set` / `save_config` edit in place: comments and unknown entries survive.

### Dockerfile Conventions

- Base image `debian:trixie-slim` pinned by digest (Renovate bumps tag+digest);
  `SHELL ["/bin/bash", "-o", "pipefail", "-c"]`; `# syntax=docker/dockerfile:1`.
- Parameterize versions via `ARG`: `NVM_VERSION`, `PNPM_VERSION`, `UV_VERSION`,
  `NODE_VERSION` (major), `PI_VERSION`, `QMD_VERSION`. The nvm/uv/pnpm installer
  scripts are verified against `*_INSTALL_SHA256` before they run (bump nvm/uv
  version and checksum together; the pnpm installer is unversioned upstream).
  `update --pi-version X` overrides the pinned `PI_VERSION`; without it the pin
  stays. Never set `PI_PACKAGE_DIR`: Pi reads its own `package.json` from it and
  would report `0.0.0`; the build fails if `pi --version` is `0.0.0`.
- Install global packages with `pnpm add -g` (pass `--allow-build` when a package
  needs lifecycle scripts); keep `npx` available for `npx`-based MCP servers.
  The pnpm store is a BuildKit cache mount whose mount point is created as
  `coder` beforehand (a root-owned one would break `pnpm add` at runtime).
- `INSTALL_DOCKER_CLI` (set by `build` from `setting.docker_socket`) controls the
  Docker CLI layer; the `pi-dockerized.docker-cli` and OCI version/revision
  labels are what the wrapper's drift check reads. Declare volatile ARGs
  (`WRAPPER_VERSION`, `VCS_REF`) last so they do not invalidate earlier layers.
- Clean apt caches in the same `RUN` layer; Docker CLI only (never the daemon).
- No privilege escalation: no `sudo` binary/sudoers; run as non-root `coder`.
- Baked resources (the guard, settings, AGENTS.md, mcp.json, skills/, prompts/,
  themes/) are **root-owned** (`COPY --chown=root:root`) and `chmod a-w`; never
  `chown` them to `coder` (the session uid is often 1000 and an owner can
  chmod back). `/home/coder`, `~/.pi` and `~/.pi/agent` are `root:coder 1775`;
  only runtime state is coder-owned. `container/lock-check.sh` asserts this at
  build, in `entrypoint.sh` (fail closed) and in `doctor`. `prompts/` and
  `themes/` are host-mounted read-write data over their baked (empty)
  directories (read-only for `--untrusted`). Do not install Pi Packages at build time: they
  are host-managed (`EXT_AGENT_DIR`, installed with the official `pi install`,
  mounted ro).
- Cache-busting `ARG PI_BUILD_TIME` only used by `update`, not regular `build`.
- Images are tagged by `build`/`pull` through `promote_image` (candidate →
  smoke test → `latest`, old one kept as `:previous` unless it is the same
  image); never `docker tag latest` from elsewhere. `pull` refuses older images
  (`check_not_downgrade`) unless `--allow-downgrade`.
- `PNPM_CONFIG_MINIMUM_RELEASE_AGE` (minutes) gates every npm release resolved
  at build time; `YT_DLP_VERSION` and `DOCKER_GPG_FINGERPRINT` are pinned ARGs.

### Security Rules

- The agent dir is baked and immutable; only `sessions/` and the runtime
  state files (and the audit log) are bind-mounted read-write; `mcp.json`,
  `skills/` and `allow.json` are mounted read-only. `$CONFIG_DIR` is never
  mounted, and `validate_mount_source` refuses any custom mount or project
  directory that would expose it, `$HOME`, credential stores or a socket
  directory.
- **Never commit:** `.env`, `auth.json`, `*.pem`, `*.key`, credentials.
- Docker socket, SSH and GnuPG forwarding are all opt-in and off by default.
- `setting.security_policy` (`strict|balanced|off`) is passed to the guard as
  `PI_DOCKERIZED_POLICY`; `--policy`/`--untrusted` override it per session.
- `extensions/pi-security-guard/` is the guard source of truth (`policy.mjs`
  evaluates, `backstops.mjs` holds the deny-lists, `shell.mjs` de-obfuscates,
  `selftest.mjs` is the fail-closed boot check run by `entrypoint.sh`); bump
  `GUARD_VERSION` in `policy.mjs` when behavior changes (CI enforces it).
- Writes are allowed only inside the project directory and `/tmp/pi`, and never
  to anything under a `.git` path component or `.gitmodules` (Git on the host
  executes `.git/config`, hooks, `commondir`, submodule configs, …); `git
  config` writes are limited to a harmless allow-list (`backstops.mjs`).
- Prefer a policy mode, `config allow edit` (host `allow.json`) or
  `policies/allow-patterns.json` over editing the vendored `policies/*.json`;
  refresh the vendored files with `scripts/refresh-policies.sh`.

## Volume Mounts Reference

Host paths are relative to the profile directory (`profiles/<name>/`).

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `$PROJECT_DIR` | `$PROJECT_DIR` (`$HOME` stripped) | rw | Project files |
| `home/.pi/agent/mcp.json` | `/home/coder/.pi/agent/mcp.json` | **ro** | MCP servers (host-edited) |
| `home/.pi/agent/skills/` | `/home/coder/.pi/agent/skills/` | **ro** | Skills (host-edited) |
| `home/.pi/agent/settings.json` | `/home/coder/.pi/agent/settings.json` | **ro** | Host preferences (seeded from defaults; replaced by the packages file while Pi Packages are installed) |
| `home/.pi/ext-agent/{settings.json,npm,git}` | `/home/coder/.pi/agent/{settings.json,npm,git}` | **ro** | Pi Packages (only after the first install; absent with `--untrusted`) |
| `home/.pi/agent/sessions/` | `/home/coder/.pi/agent/sessions/` | rw | Sessions |
| `home/.pi/agent/{auth,mcp-auth,trust}.json`, `mcp.log` | idem | rw | Runtime state |
| `home/.pi/agent/audit.log` | idem | rw | Guard audit log (blocked calls) |
| `home/.pi/agent/allow.json` | idem | **ro** | Optional host allow rules (absent with `--untrusted`) |
| `home/.pi/agent/models.json` | idem | **ro** | Provider definitions (absent or `--untrusted`: not mounted) |
| `home/.pi/agent/prompts/`, `themes/` | idem | rw | Prompt templates and themes (data) |
| `home/.npm/` | `/home/coder/.npm/` | rw | npm cache |
| `home/.cache/qmd/` | `/home/coder/.cache/qmd/` | rw | qmd index and models |
| `home/.pi-lens/` | `/home/coder/.pi-lens/` | rw | pi-lens state |
| `~/.claude/`, `~/.agents/` | idem | ro | Compat skills |
| `~/.composio/` | idem | rw | Composio CLI (custom mount) |
| `/var/run/docker.sock` | idem | rw (opt-in) | Docker socket |
| `home/.gnupg-sessions/<pid>/` | `/home/coder/.gnupg/` | rw (opt-in) | This session's mirrored public GnuPG material (removed when it ends) |

`--untrusted` mounts only the project, `skills/` and `settings.json` (ro),
`prompts/`/`themes/` (**ro**), `home/.pi/agent/sessions-untrusted/` (as
`sessions/`, rw), `auth.json` and `audit.log` (rw).

Not mounted (baked read-only): `AGENTS.md`, `extensions/`.
The wrapper's own `~/.config/pi-dockerized/` is never mounted.
