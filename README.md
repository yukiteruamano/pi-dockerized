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
- **Extensions/plugins are installed at image build time** from
  `install-extensions`, then locked read-only. The agent cannot add, remove or
  update extensions.
- **Everything is read-only except skills.** Settings, extensions, prompts,
  themes, AGENTS.md and models are baked RO; `mcp.json` is mounted RO from the
  host; only `skills/` (plus the runtime state Pi must write) is writable.
- **Auth uses provider API keys** from `setting.env_file`. Pi has no
  `auth login` subcommand; interactive login happens through the TUI `/login`,
  which this wrapper does not use.
- **MCP** is configured on the host (`mcp.json`, mounted RO); `pi mcp login`
  still works for OAuth (writes `mcp-auth.json`, mounted RW).

## Security Features

- **Isolated environment** — Pi only sees the mounted project directory.
- **Baked, immutable extensions** — installed at build time, `chmod a-w` in the
  image; the agent cannot modify its own capabilities.
- **Read-only config** — `settings.json`, `AGENTS.md`, `extensions/`, prompts,
  themes and models come from the image; `mcp.json` is mounted read-only from
  the host.
- **Security extension** — the ported `opencode-policy` unsafe/injection pattern
  sets plus built-in backstops (secrets, destructive commands, write
  confinement) enforced in `strict`, `balanced` (default) or `off` modes.
- **Non-root** — runs as your host UID/GID with `--cap-drop=ALL` and
  `no-new-privileges`; no sudo binary exists.
- **Opt-in host access** — Docker socket, SSH and GnuPG agent forwarding are all
  disabled by default.
- **Self-update disabled** — `PI_SKIP_VERSION_CHECK=1`; `pi update` is blocked.

## Prerequisites

1. **Docker** installed and running.
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

# Build the image (installs Pi + the extensions in install-extensions)
pi-dockerized build

# Add provider keys to the secrets file:
install -m 600 /dev/null ~/.config/pi-dockerized/env
printf 'ANTHROPIC_API_KEY=%s\n' 'sk-ant-...' >> ~/.config/pi-dockerized/env
# then point the wrapper at it:
pi-dockerized config edit   # set: setting.env_file=~/.config/pi-dockerized/env

# Check credentials and run
pi-dockerized auth
pi-dockerized run /path/to/project
```

## Commands

```bash
pi-dockerized run [DIR]        # Run Pi (TUI) in a project
pi-dockerized auth             # Check provider credentials from setting.env_file
pi-dockerized models           # List available models (pi --list-models)
pi-dockerized exec "..."       # Non-interactive prompt (pi --print)
pi-dockerized mcp [list|login|logout]   # MCP servers (add/remove are host-only)
pi-dockerized extensions       # List installed extensions (pi list)
pi-dockerized stats            # Session usage statistics (best-effort)
pi-dockerized doctor           # Diagnose guard, config, credentials, SSH/GPG
pi-dockerized build            # Build the Docker image
pi-dockerized install [OPTS]   # Install/repair PATH, config, completions, aliases
pi-dockerized update [--check|--yes|--no-build]  # git pull + sync + rebuild
pi-dockerized upgrade          # Same as update (with prompt)
pi-dockerized version          # Wrapper + guard + Pi versions
pi-dockerized config show|edit|path|sync         # Wrapper INI config
pi-dockerized config pi [path|edit]              # mcp.json (MCP servers)
pi-dockerized clean            # Remove the Docker image
pi-dockerized help
DRY_RUN=true pi-dockerized run # Print the docker command without running
```

## Extensions (build time)

Extensions and Pi packages are declared in **`install-extensions`** (repo root),
one `pi install` source per line:

```
# npm:@scope/package@1.2.3
# git:github.com/owner/repo@v1.2.3
```

At build the Dockerfile runs `pi install` for every active line, then locks the
agent directory read-only. To change extensions, edit `install-extensions` and
rebuild (`pi-dockerized update` or `pi-dockerized build`).

The security guard is not listed there: it ships with this project and is
copied into the image from `extensions/pi-security-guard/`.

## MCP support

MCP servers live in **`mcp.json`** on the host
(`~/.config/pi-dockerized/home/.pi/agent/mcp.json`) and are mounted read-only.
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

## Skills (the one writable resource)

Skills live under
`~/.config/pi-dockerized/home/.pi/agent/skills/<name>/SKILL.md` and are mounted
read-write. Create and edit them freely; Pi picks them up on next start
(`/reload` inside a session). Project skills (`.pi/skills/`) are disabled by the
baked `defaultProjectTrust: "never"`.

## Configuration

Wrapper config: `~/.config/pi-dockerized/config` (INI). Secrets: the dotenv file
referenced by `setting.env_file` (mode 600, under the config dir, never mounted).

```ini
setting.ssh_agent_support=false
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

See `examples/config.example` for the full reference.

## Volume Mounts

| Host Path | Container Path | Mode | Purpose |
|-----------|---------------|------|---------|
| `$PROJECT_DIR` | path with `$HOME` stripped | rw | Project files |
| `home/.pi/agent/mcp.json` | `/home/coder/.pi/agent/mcp.json` | **ro** | MCP servers (host-edited) |
| `home/.pi/agent/skills/` | `/home/coder/.pi/agent/skills/` | **rw** | Skills (the writable resource) |
| `home/.pi/agent/sessions/` | `/home/coder/.pi/agent/sessions/` | rw | Sessions (`sessionDir`) |
| `home/.pi/agent/{auth,mcp-auth,trust}.json`, `mcp.log` | idem | rw | Runtime state |
| `home/.npm/` | `/home/coder/.npm/` | rw | npm cache (npx MCP servers) |
| `~/.claude/`, `~/.agents/` | idem | ro | Compat skills |
| `~/.composio/` | idem | rw | Composio CLI (optional custom mount) |
| `/var/run/docker.sock` | idem | rw | Docker socket (opt-in, root-equivalent) |

Not mounted (baked read-only in the image): `settings.json`, `AGENTS.md`,
`extensions/`, `prompts/`, `themes/`, `models.json`.

The whole host state tree lives under `~/.config/pi-dockerized/home/` (override
with `PI_HOME`) and survives rebuilds.

## Security policy

`setting.security_policy` selects how the baked guard evaluates the vendored
patterns:

- `strict` — every pattern enforced.
- `balanced` (default) — drops cloud/multi-tenant rules and common dev false
  positives; keeps the dangerous ones.
- `off` — vendored patterns disabled; built-in backstops (secrets, destructive
  commands, write confinement, Pi self-management) stay active.

## Host agent forwarding

- **SSH** (`setting.ssh_agent_support=true`): forwards only `SSH_AUTH_SOCK` and
  mounts `~/.ssh/config` + `known_hosts` read-only; private keys never enter the
  container. Mounting `~/.ssh` is refused.
- **GnuPG** (`setting.gpg_agent_support=true`): mirrors only public material,
  prefers the restricted `S.gpg-agent.extra` socket, sets `no-autostart`.
  Private keys are never copied.
- **Docker socket** (`setting.docker_socket=true`): opt-in, root-equivalent.

## File Reference

- `bin/pi-dockerized` — main wrapper.
- `lib/config-lib.sh` — shared config/mount/env logic (sourced).
- `lib/install-lib.sh` — install wizard (sourced).
- `Dockerfile` — image: Debian + Node/NVM + pnpm + uv + Pi; bakes `container/`,
  `extensions/` and the packages from `install-extensions`.
- `entrypoint.sh` — container entrypoint.
- `container/settings.base.json`, `container/AGENTS.md` — baked Pi config.
- `install-extensions` — build-time extension manifest.
- `extensions/pi-security-guard/` — security extension (`index.ts` + `policy.mjs`
  + `policies/`).
- `policies/` — vendored `opencode-policy` pattern sets (source for the guard).
- `tests/` — `security-guard.test.mjs`, `wrapper-args.test.sh`.

## License

MIT. Third-party: [Pi](https://github.com/earendil-works/pi) (MIT),
[opencode-policy](https://github.com/tjvjk/opencode-policy) (MIT, pattern sets),
Docker CLI and Node.js.
