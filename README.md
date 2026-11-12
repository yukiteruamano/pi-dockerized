# Pi Dockerized — Secure Sandbox for the Pi coding agent

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Fork of [glennvdv/opencode-dockerized](https://github.com/glennvdv/opencode-dockerized),
> migrated to [Pi](https://github.com/earendil-works/pi)** (`@earendil-works/pi-coding-agent`).
> Same hardened sandbox model, now built around Pi's extension/skills/MCP system.

Run [Pi](https://pi.dev) in a secure, isolated Docker container with controlled
access to your projects. Pi gets just enough access to be useful while the
host stays protected.

## What changed vs OpenCode

- **Pi, not OpenCode.** The CLI is `pi`; config lives in `~/.pi/agent/`.
- **No native permission system in Pi.** All enforcement lives in a **security
  extension** (`extensions/pi-security-guard/`) baked read-only into the image.
- **Extensions are Pi Packages installed with the official `pi install`**
  (`pi-dockerized extensions ...`) and kept on the host, so they survive image
  rebuilds; sessions mount them read-only: the agent cannot add, remove or
  change them. Only the security guard stays baked into the image.
- **Everything is read-only except runtime state and data.** The guard and
  AGENTS.md are baked RO; `settings.json` (preferences only), `mcp.json`,
  `models.json`, `skills/` and installed Pi Packages are mounted RO from the
  host; `prompts/` and `themes/` are read-write data; `sessions/` and the
  runtime state Pi must write are writable.
- **Auth uses provider API keys** from `setting.env_file`. Pi has no
  `auth login` subcommand; interactive login happens through the TUI `/login`,
  which this wrapper does not use.
- **MCP** is configured on the host (`mcp.json`, mounted RO); `pi mcp login`
  still works for OAuth (writes `mcp-auth.json`, mounted RW).

## Security Features

- **Isolated environment** — Pi only sees the mounted project directory.
- **Baked, immutable guard** — the security extension, `AGENTS.md` and the
  baked settings are root-owned and read-only inside root-owned sticky
  directories, so the agent cannot edit, rename or replace them (the container
  refuses to start otherwise). Pi Packages are host-managed and mounted
  read-only (see below).
- **Read-only config** — `AGENTS.md` and `extensions/` come from the image;
  `settings.json`, `mcp.json` and `models.json` are mounted read-only from the
  host. The host `settings.json` may only hold preferences: the sandbox's
  security keys are pinned and any other key (packages, extensions, command
  settings) stops the session from starting.
- **Security extension** — the ported upstream (`opencode-policy`) unsafe/injection pattern
  sets plus built-in backstops (secrets and credential stores, destructive
  commands, anything under `.git`, `git config` writes, write confinement)
  enforced in `strict`,
  `balanced` (default) or `off` modes. Quoting tricks (`cat .e''nv`) are
  de-obfuscated before matching, oversized inputs are refused, and every
  blocked call lands in an audit log (`pi-dockerized audit`).
- **Fail closed** — the container refuses to start if the guard fails its boot
  self-test; a broken image never runs Pi without enforcement.
- **Mount policy** — neither the project directory nor custom mounts can expose
  your home, credential stores, the wrapper's own config/secrets, socket
  directories (`/run`, `/var/run`, the Docker socket), `/proc`/`/sys`/`/dev`,
  or land on system paths or the baked agent tooling (symlinks are resolved
  first).
- **Non-root** — runs as your host UID/GID with `--cap-drop=ALL` and
  `no-new-privileges`; no sudo binary exists.
- **Opt-in host access** — Docker socket, SSH and GnuPG agent forwarding are all
  disabled by default.
- **Untrusted mode** — `pi-dockerized run --untrusted DIR` applies the strictest
  setup for code you do not trust.
- **Self-update disabled** — `PI_SKIP_VERSION_CHECK=1`; `pi update` is blocked.
- **Safe image lifecycle** — builds are smoke-tested before they replace the
  current image, the previous one is kept for `rollback`, and prebuilt images
  are signed by the release workflow (`pull` verifies the signature and refuses
  to downgrade).

## Prerequisites

1. **Docker** 23 or newer (BuildKit), installed and running.
2. Network access at build time (to install Pi and any extensions).

**No local Pi installation required.**

## Quick Start

```bash
# One-liner (clones to ~/.local/share/pi-dockerized)
curl -fsSL https://raw.githubusercontent.com/yukiteruamano/pi-dockerized/master/install.sh | bash

# Or from a local clone
./install.sh
./install.sh --yes                      # non-interactive
./install.sh --only config,aliases      # only some sections

# Build the image (installs Pi; extensions are managed separately, see below)...
pi-dockerized build
# ...or fetch the prebuilt, signed one (needs cosign; --no-verify skips the check)
pi-dockerized pull

# Add provider keys to the secrets file:
install -m 600 /dev/null ~/.config/pi-dockerized/profiles/default/env
printf 'ANTHROPIC_API_KEY=%s\n' 'sk-ant-...' >> ~/.config/pi-dockerized/profiles/default/env
# then point the wrapper at it:
pi-dockerized config edit   # set: setting.env_file=~/.config/pi-dockerized/profiles/default/env

# Check credentials and run
pi-dockerized auth
pi-dockerized run /path/to/project
```

## Commands

```bash
pi-dockerized run [FLAGS] [DIR]   # Run Pi (TUI) in a project
pi-dockerized exec [FLAGS] "..."  # Non-interactive prompt (pi --print); "-" or a pipe reads stdin
pi-dockerized shell [FLAGS] [DIR] # Shell inside the sandbox (same mounts and limits)
pi-dockerized auth             # Check provider credentials from setting.env_file
pi-dockerized models           # List available models (pi --list-models)
pi-dockerized mcp [list|login|logout]   # MCP servers (add/remove are host-only)
pi-dockerized extensions list|install|remove|update|path|edit   # Pi Packages via the official pi install
pi-dockerized stats            # Session usage statistics (best-effort)
pi-dockerized doctor           # Diagnose guard (incl. self-test), config, credentials, SSH/GPG
pi-dockerized audit [-n N|--summary|--clear]   # Tool calls the guard blocked
pi-dockerized ps | stop NAME|--all             # Running sessions
pi-dockerized build            # Build, smoke-test and promote the image (previous kept)
pi-dockerized pull [TAG] [--no-verify|--allow-downgrade]  # Fetch the prebuilt signed image from GHCR
pi-dockerized rollback         # Go back to the image the last build/pull replaced
pi-dockerized install [OPTS]   # Install/repair PATH, config, completions, aliases
pi-dockerized uninstall [--image] [--purge-config [--all-profiles]]  # Remove the shell integration
pi-dockerized update [--check|--yes|--no-build|--[no-]verify|--pi-version X]  # git pull + sync + rebuild
pi-dockerized upgrade          # Same as update (with prompt)
pi-dockerized version          # Wrapper, image, guard, policy-set and Pi versions
pi-dockerized config show|edit|get|set|path|sync|profiles   # Wrapper INI config
pi-dockerized config pi [path|edit]      # mcp.json (MCP servers)
pi-dockerized config allow [path|edit]   # Host allow rules for the guard
pi-dockerized clean            # Remove the Docker image (all tags)
pi-dockerized help
DRY_RUN=true pi-dockerized run # Print the docker command without running
```

### Session flags (`run`, `shell`, `exec`)

| Flag | Effect |
|------|--------|
| `--untrusted` | Strictest setup for code you do not trust: `strict` policy, no `allowed_tools`, `bridge` network, no SSH/GPG forwarding, no Docker socket, no custom mounts, no host allow rules, no Pi Packages, no shared caches or MCP state (`.npm`, `.cache/qmd`, `mcp.json`, `mcp-auth.json`, `trust.json`, …); `prompts/`/`themes/` read-only and transcripts in a separate `sessions-untrusted/` |
| `--policy P` | `strict` \| `balanced` \| `off` for this session only |
| `--network N` | `host` \| `bridge` for this session only |
| `--dir DIR` | Project directory (`exec`, `shell`) |

`--untrusted` only accepts `--policy strict` and cannot be combined with
`--network host`. Every
project session prints an `Exposure:` line summarizing what it can reach.

### Profiles

`pi-dockerized --profile work run` (or `PI_DOCKERIZED_PROFILE=work`) uses
`~/.config/pi-dockerized/profiles/work/` for its own config, secrets file, MCP
servers, sessions and audit log, so keys and policies never mix between
contexts (one profile per provider account). Nothing is inherited from the
root config: each profile's config fully replaces it, and its secrets file
must live inside the profile's own directory. Everything profile-related goes
through the `profile` command:

| Command | What it does |
|---------|--------------|
| `profile list` | Names, the active one marked; look-alikes and stray entries reported |
| `profile create work` | New profile with its own config and state tree (or `--profile work install`) |
| `profile remove work [--yes]` | Delete it, state included (refused while it has running sessions) |
| `profile show [work] [--sources]` / `profile path [work]` | Its settings / its directory |
| `profile check [work]` | Read-only audit of the whole profile (see below) |
| `profile fix [work]` | Repair what `check` reports, then check again |
| `profile run work [RUN ARGS]` | Same as `--profile work run [RUN ARGS]` |

Any other command naming an unknown profile fails, so a typo can never start a
session on a fresh empty profile. Names are unique: `work_a` is refused when
`work-a` exists (case and `-`/`_` variants read as the same name), and a
profile directory symlinked to another is reported as a duplicate. `check`
covers the directory (real, owned, `0700`, no alias), the config file (present,
`0600`, valid entries, no root-only `default_profile`/`profile.map` lines), the
secrets file (inside the profile, no sandbox-controlling keys), the state tree
and, for `default`, routing to missing profiles. `fix` only repairs structure
and permissions — it comments out root-only lines (after a backup), points
`env_file` at the profile's own `env` when it borrowed another profile's, and
reseeds missing state; it never reads or copies secrets. `ps` shows each
session's profile.

Two root-config (never per-profile) entries route sessions automatically;
edit them with `profile root edit` (`config set default_profile NAME` also
writes the root config, from any profile):
`setting.default_profile=work` makes `work` the profile when `--profile` is not
given (`--profile default` escapes back to the default profile), and
`profile.map.<key>=<path>:<profile>` picks a profile by project directory
(longest matching path wins; an explicit `--profile` always takes precedence):

```ini
setting.default_profile=personal
profile.map.job=~/work:acme
profile.map.oss=~/src/oss:default
```

### Updating and rolling back

`build` and `update` build under a candidate tag, smoke-test it (Pi reports a
real version, the guard passes its self-test) and only then make it `latest`;
the image it replaces stays as `pi-dockerized:previous` and every build also
gets a `<wrapper>-guard<N>` tag. A failed build or test leaves the current image
untouched, and `rollback` undoes a bad update. `update` pins Pi to the release in
the Dockerfile unless you pass `--pi-version latest|x.y.z`. Before pulling,
`update` lists the incoming commits, and the upstream head must carry a valid
signature from a key listed in `.github/release-signers` (on by default:
`setting.verify_updates`; `--no-verify` skips it once). Import the
maintainer's key first (`gpg --recv-keys <fingerprint>`).
Exactly the commit that was shown (and verified) is merged, and the image is
built by the updated wrapper. `pull` refuses an image older than the current
one or than this checkout (wrapper or guard version) unless you pass
`--allow-downgrade`. pnpm refuses npm releases younger than 24 h during the
build, so a Pi release from the last day cannot be built yet.

The wrapper compares the image's version label with its own and warns when the
image is stale, or lacks the Docker CLI while `setting.docker_socket` is on.

## Extensions (Pi Packages, host-managed)

Extensions are **Pi Packages installed with the official `pi install`**, nothing
else: no custom or hand-written extensions are supported. They are kept on the
host, so an image rebuild never re-fetches them:

```bash
pi-dockerized extensions list                            # pi list
pi-dockerized extensions install npm:@scope/pkg@1.2.3    # pi install (pin a version)
pi-dockerized extensions install git:github.com/owner/repo@v1.2.3
pi-dockerized extensions install npm:pkg --allow-scripts # let npm install scripts run
pi-dockerized extensions update [SRC]                    # pi update --extensions | pi update SRC
pi-dockerized extensions remove SRC                      # pi remove
pi-dockerized extensions edit                            # edit Pi's settings.json by hand
```

Sources are exactly what `pi install` takes: `npm:`, `git:` and `https://` git
URLs. Local paths are refused (the installer cannot see your disk).

How it works: the commands above run the real `pi` in a throwaway container whose
agent directory is a host directory, `~/.config/pi-dockerized/profiles/default/home/.pi/ext-agent/`
(`pi-dockerized extensions path`), mounted read-write. Pi writes its
`settings.json` there and installs into `npm/` and `git/`, visible from the host.
Sessions mount those three **read-only** over the agent's own, so the agent can
never add, remove or change a package; changes apply to the next session. Nothing
is mounted until the first install, and `--untrusted` sessions load none.

The installer container has network on the `bridge` and **no** secrets file,
project, session state or custom mounts; npm install scripts are skipped unless
`--allow-scripts`. Because Pi writes the `settings.json` that sessions then use,
the security keys (`defaultProjectTrust`, `sessionDir`, `defaultTools`,
`enableInstallTelemetry`) are seeded from the image's defaults, reapplied after
every Pi command, and checked again at every session start: if the file loosens
them the container refuses to start.

A package runs inside Pi with the session's full permissions, **including the
provider keys in its environment**, and can register handlers next to the guard.
Install only Pi Packages you would run with your own keys, and pin versions. In
`strict` policy the tools a package registers must be listed in
`setting.allowed_tools`.

The security guard is not a package: it ships with the project and stays baked
into the image (`extensions/pi-security-guard/`), where a session cannot touch it.

**Migrating from `install-extensions`** (removed): run
`pi-dockerized extensions install <source>` for each line you had in it.

## MCP support

MCP servers live in **`mcp.json`** on the host
(`~/.config/pi-dockerized/profiles/default/home/.pi/agent/mcp.json`) and are mounted read-only.
Edit them with:

```bash
pi-dockerized config pi edit
```

Example:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]
    },
    "docs": { "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer ${DOCS_TOKEN}" } }
  }
}
```

Use `${VAR}` references (never literal secrets) — the wrapper refuses inline
secrets. For OAuth servers, `pi-dockerized mcp login <server>` writes tokens to
`mcp-auth.json` (mounted read-write, persisted on the host).

## Skills (host-managed, read-only)

Skills live under
`~/.config/pi-dockerized/profiles/default/home/.pi/agent/skills/<name>/SKILL.md` and are mounted
**read-only**: create and edit them on the host, never from a session. Pi picks
them up on next start (`/reload` inside a session). Project resources
(`.pi/` extensions, skills, prompts, MCP servers) load only after you trust the
project: the baked `defaultProjectTrust: "ask"` prompts in interactive sessions
and skips them in `exec`/print mode. `trust.json` (saved decisions) is mounted
read-only, so a session cannot pre-approve what it plants in the project: a
`/trust` inside a session does not persist. Save decisions on the host with
`pi-dockerized config trust edit`.

## Configuration

Wrapper config: `~/.config/pi-dockerized/profiles/<name>/config` (INI; `default`
unless another profile is selected). Secrets: the dotenv file referenced by
`setting.env_file` (mode 600, inside the profile's directory, never mounted).
The root `~/.config/pi-dockerized/config` only routes commands to a profile.

```ini
setting.ssh_agent_support=false
setting.gpg_agent_support=false
setting.docker_socket=false
setting.git_readonly=true
setting.network=host
setting.security_policy=balanced
setting.allowed_tools=
setting.verify_updates=true
setting.memory=4g
setting.cpus=2
setting.pids_limit=4096
setting.env_file=~/.config/pi-dockerized/profiles/default/env
setting.theme=system
setting.model=sonnet
setting.default_profile=
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig
```

See `examples/config.example` for the full reference and `docs/config-reference.md`
for the setting table. Edit one setting without
opening the file: `pi-dockerized config set network bridge` (validated like the
loader), `config get network` to read it. Unknown settings and malformed lines
are reported with their line number instead of being ignored.

Custom mounts are refused when they would expose your home directory (or a
parent), `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`,
`~/.config/gcloud`, `~/.config/gh`, `~/.netrc`, `~/.git-credentials`, the
wrapper's own config directory or the Docker socket; or when the container path
would hide system paths or sit inside the baked agent directory. A source that
does not exist is skipped with a warning.

## Volume Mounts

Host paths are relative to the profile's directory
(`~/.config/pi-dockerized/profiles/<name>/`).

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `$PROJECT_DIR` | path with `$HOME` stripped | rw | Project files |
| `$PROJECT_DIR/.git`, `.gitmodules` | idem | **ro** | Git metadata (`setting.git_readonly`, default on): commit, stash and fetch from the host |
| `home/.pi/agent/mcp.json` | `/home/coder/.pi/agent/mcp.json` | **ro** | MCP servers (host-edited) |
| `home/.pi/agent/skills/` | `/home/coder/.pi/agent/skills/` | **ro** | Skills (host-edited) |
| `home/.pi/agent/models.json` | `/home/coder/.pi/agent/models.json` | **ro** | Provider definitions (host-edited; absent or `--untrusted`: not mounted) |
| `home/.pi/agent/prompts/` | `/home/coder/.pi/agent/prompts/` | rw | Prompt templates (the session can also write them) |
| `home/.pi/agent/themes/` | `/home/coder/.pi/agent/themes/` | rw | Themes (the session can also write them) |
| `home/.pi-lens/` | `/home/coder/.pi-lens/` | rw | pi-lens state, kept across restarts |
| `home/.pi/agent/settings.json` | `/home/coder/.pi/agent/settings.json` | **ro** | Host preferences, seeded from the defaults (replaced by the packages file while Pi Packages are installed) |
| `home/.pi/ext-agent/{settings.json,npm,git}` | `/home/coder/.pi/agent/{settings.json,npm,git}` | **ro** | Pi Packages installed with `pi install` (only once something is installed; absent with `--untrusted`) |
| `home/.pi/agent/sessions/` | `/home/coder/.pi/agent/sessions/` | rw | Sessions (`sessionDir`) |
| `home/.pi/agent/{auth,mcp-auth}.json`, `mcp.log` | idem | rw | Runtime state |
| `home/.pi/agent/trust.json` | idem | **ro** | Saved project-trust decisions (`config trust edit`) |
| `home/.pi/agent/audit.log` | idem | rw | Guard audit log (blocked calls) |
| `home/.pi/agent/allow.json` | idem | **ro** | Optional host allow rules for the guard (not mounted with `--untrusted`) |
| `home/.npm/` | `/home/coder/.npm/` | rw | npm cache (npx MCP servers) |
| `home/.cache/qmd/` | `/home/coder/.cache/qmd/` | rw | qmd index and downloaded models |
| `~/.claude/skills/`, `~/.agents/skills/` | idem | ro | Compat skills (only `skills/`, never the whole directories) |
| `~/.composio/` | idem | rw | Composio CLI (optional custom mount) |
| `/var/run/docker.sock` | idem | rw | Docker socket (opt-in, root-equivalent) |

With `--untrusted` only the project, `skills/` and `settings.json` (ro),
`prompts/` and `themes/` (**ro**), `home/.pi/agent/sessions-untrusted/` (rw,
mounted as `sessions/`), `auth.json` and `audit.log` (rw) are mounted; nothing
else from the table is shared with the session.

Not mounted (baked read-only in the image): `AGENTS.md`, `extensions/`.

The whole host state tree lives under `~/.config/pi-dockerized/profiles/default/home/` (override
with `PI_HOME`) and survives rebuilds.

## Security policy

`setting.security_policy` selects how the baked guard evaluates the vendored
patterns:

- `strict` — every pattern enforced.
- `balanced` (default) — drops cloud/multi-tenant rules and common dev false
  positives; keeps the dangerous ones.
- `off` — vendored patterns disabled; built-in backstops (secrets, destructive
  commands, Git hooks/config, write confinement, Pi self-management) stay active.

`strict` also refuses tools the guard does not model (MCP tools, other
extensions) unless they are listed in `setting.allowed_tools`; in `balanced`
their values are scanned with the vendored patterns. The `balanced` exclusions
live in `extensions/pi-security-guard/balanced-excluded.json`, grouped with the
reason for each.

Behavior worth knowing:

- Writing a file never trips the pattern scan: only `path` fields are checked
  for `write`/`edit`, so docs and tests may mention `rm -rf /` or `.env`.
  Anything that can run on the host when Git touches the project (`.git/hooks`,
  `.git/config`, `.gitmodules`, `core.hooksPath`, `core.fsmonitor`, …) cannot be
  written.
- A single value over 32 KiB is refused: several patterns are quadratic on long
  lines. Write large files with the `write` tool, not a shell heredoc.
- The guard's own boot self-test runs before every container command; `doctor`
  runs it too and reports what failed.

### Host allow rules and audit

A false positive can be allowed without rebuilding: put rules in
`pi-dockerized config allow edit` (`allow.json`, a JSON array of
`{"id","pattern","reason"}`). It is mounted read-only, so a session can never
widen its own allowlist, and it only affects the vendored patterns, never the
built-in backstops. `pi-dockerized audit` shows what the guard blocked
(`--summary` counts by rule). The session can write the log, so treat it as a
review aid rather than tamper-proof evidence.

## Host agent forwarding

- **SSH** (`setting.ssh_agent_support=true`): forwards only `SSH_AUTH_SOCK` and
  mounts `~/.ssh/config` + `known_hosts` read-only; private keys never enter the
  container. Mounting `~/.ssh` is refused.
- **GnuPG** (`setting.gpg_agent_support=true`): mirrors only public material,
  prefers the restricted `S.gpg-agent.extra` socket, sets `no-autostart`.
  Private keys are never copied.
- **Docker socket** (`setting.docker_socket=true`): opt-in, root-equivalent.

## File Reference

- `bin/pi-dockerized` — main wrapper (dispatch only).
- `lib/config-lib.sh` — loader for the shared config/mount/env logic; the
  modules live in `lib/config/` (`core`, `mount-policy`, `state`, `gpg-ssh`,
  `docker-args`, `settings`, `parse`, `overrides`, `prompts`).
- `lib/cmd/` — one module per group of commands (`session`, `extensions`,
  `image`, `update`, `config`, `help`).
- `lib/install-lib.sh` + `lib/install/` — install/uninstall wizard (sourced).
- `Dockerfile` — image: Debian (digest-pinned) + Node/NVM + pnpm + uv + Pi + qmd;
  bakes `container/` and the guard from `extensions/`.
- `entrypoint.sh` — container entrypoint (runs the guard self-test first).
- `container/` — baked Pi config (`settings.base.json`, `AGENTS.md`), the
  in-container diagnostics (`doctor.sh`, `auth-check.sh`) and the Pi Packages
  helpers (`ext-install.sh` runs the official `pi`, `ext-agent.mjs` guards the
  settings' security keys).
- `extensions/pi-security-guard/` — security extension (`index.ts`, `policy.mjs`,
  `backstops.mjs`, `shell.mjs`, `selftest.mjs`, `balanced-excluded.json`,
  `policies/`).
- `policies/` — vendored policy pattern sets (upstream `opencode-policy` source for the guard).
- `scripts/refresh-policies.sh` — diff/refresh the vendored pattern sets.
- `tests/` — `security-guard.test.mjs`, `guard-extension.test.mjs`,
  `ext-agent.test.mjs`, `wrapper-args.test.sh`, `wrapper-commands.test.sh`.
- `CHANGELOG.md` — release notes.
- `docs/` — `config-reference.md` (every setting), `troubleshooting.md`
  (every `doctor` failure and its fix).
- `examples/` — `config.example`, `mcp.json.example`, `allow.json.example`,
  `settings.json.example` (all validated by `tests/ext-agent.test.mjs`).

## License

MIT. Third-party: [Pi](https://github.com/earendil-works/pi) (MIT),
[opencode-policy](https://github.com/tjvjk/opencode-policy) (MIT, pattern sets),
Docker CLI and Node.js.
