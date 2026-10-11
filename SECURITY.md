# Security Model

`pi-dockerized` sandboxes an autonomous coding agent (Pi). It reduces blast
radius; it is **not** a hard security boundary against a determined attacker.
This document states what it does and does not protect against.

## Threat model

The agent is untrusted code execution: it may run arbitrary shell commands,
edit files, and fetch URLs, and it may be steered by untrusted content (prompt
injection). The wrapper's job is to keep that activity inside a container with
the least access it needs to be useful.

Pi itself ships **no permission system**; enforcement is provided entirely by the
baked security extension (`extensions/pi-security-guard/`).

## What is enforced

| Control | How |
|---------|-----|
| Non-root execution | Image has no `sudo` (no binary, no sudoers); the wrapper starts the container with `--user <host uid>:<host gid>`, `--cap-drop=ALL` and `--security-opt no-new-privileges:true`. `entrypoint.sh` performs no privilege changes |
| Immutable extensions | Extensions/packages are installed at image build time (`install-extensions`) and locked with `chmod -R a-w` together with `settings.json`, `AGENTS.md`, prompts, themes and models; the agent cannot add, remove or update them. `pi update`/`pi install`/`pi mcp add/remove` are additionally blocked by the guard |
| Read-only MCP config | `mcp.json` is mounted **read-only** from the host; only OAuth tokens (`mcp-auth.json`) and `trust.json` are writable |
| Project-only writes | Only the project directory and `/tmp/pi` are writable (enforced by the guard, resolving symlinks via `realpath` so a link inside the project cannot escape) |
| Secret reads | The guard refuses reads of `.env` (except `.env.example`), `*.pem`, `*.key`, key-like names, `auth.json`, `mcp-auth.json`, `trust.json`, `credentials*`, `~/.npmrc`, `~/.mcp-auth/`, `~/.ssh/`, SSH keys and `private-keys-v1.d/` — via both the file tools and shell commands |
| Dangerous commands | Guard backstops for `sudo`, `rm -rf /`, `mkfs`, `dd of=/dev/…`, `shutdown`/`reboot`, root mounts and metadata-IP reads |
| Policy patterns | The vendored `opencode-policy` pattern sets, evaluated by `extensions/pi-security-guard/policy.mjs` (see `policies/README.md`) |
| SSH agent forwarding (opt-in) | `setting.ssh_agent_support=true` forwards only `SSH_AUTH_SOCK` and mounts `~/.ssh/config`/`known_hosts` read-only; private keys (`id_*`, `*.pem`, `*.key`) are never mounted, and a custom mount of `~/.ssh` is refused |
| GnuPG agent forwarding (opt-in) | `setting.gpg_agent_support=true` mirrors only the public keyring (`pubring.kbx` / `public-keys.d`) and forwards the host `gpg-agent` socket (preferring the restricted `S.gpg-agent.extra`); `private-keys-v1.d/` is never copied or mounted, and a custom mount of `~/.gnupg` is refused |
| No self-update | `PI_SKIP_VERSION_CHECK=1` and the guard block `pi update` |

## Known limitations

- **Docker socket is opt-in but root-equivalent.** With
  `setting.docker_socket=true` the container gets the host Docker socket, which
  allows mounting `/` and escaping to host root. It is **off by default**.
- **`--network host`.** The container shares the host network namespace, so it
  can reach host services and the internet without restrictions.
- **No read-only root filesystem.** `--cap-drop=ALL` and `no-new-privileges` are
  set, but the rootfs stays writable; adding `--read-only` with tmpfs mounts is
  future hardening work.
- **SSH/GPG agent forwarding are signing oracles.** While enabled, the container
  can authenticate/sign with the host agents (never reading the private keys).
  Destructive agent operations (`ssh-add -D/-d/-x/-X/-e`) and host-agent control
  (`gpgconf --kill/--reload`) are blocked. **Off by default.**
- **Agent sockets are bind-mounted, not created.** A stale/missing source fails
  instead of Docker creating a directory at the host socket path.
- **GPG needs a mirrored public keyring.** Without `pubring.kbx` /
  `public-keys.d/pubring.db`, signed commits fail; the wrapper warns and
  `pi-dockerized doctor` reports it.
- **GPG socket relay.** Setups that cannot bind a socket under `/run/user/<uid>/
  gnupg` relay the restricted `S.gpg-agent.extra` through a socket on a normal
  filesystem (`socat`, under the wrapper config dir) for the session.
- **Baked extensions require a rebuild to change.** Editing `install-extensions`
  or the guard has no effect until `pi-dockerized build` (or `update`).
- **Skills are writable.** `skills/` is the one resource mounted read-write, so
  a session can add or change skills (which instruct the model). Review them.
- **Project trust is disabled.** The baked `settings.json` sets
  `defaultProjectTrust: "never"`, so project `.pi/` extensions, MCP servers,
  skills and prompts are not loaded.
- **MCP OAuth tokens are read-write.** `mcp-auth.json` (and `trust.json`) are
  mounted read-write so sign-in persists; the agent could read or alter them.
- **Environment variables in the container are visible to the agent.** Provider
  keys from the secrets file end up in the container environment and in
  `docker inspect` on the host. Keep unrelated host secrets out of the env file.
- **Inline secrets in `mcp.json` abort the run.** MCP credentials must use
  `${VAR}` references; literal `apiKey`/`token`/`secret`/`password` values are
  rejected by the wrapper and reported by `doctor`.
- **Secret reads are heuristic.** An obfuscated command could still reach data
  that is not mounted at all; the bare `*key` heuristic also blocks unrelated
  names ending in "key" (e.g. `monkey`).
- **Bare environment dumps are denied.** `env`, `printenv`, `set`, `export`,
  `declare`, `typeset` with no arguments (plus `-p`/`-x`/`compgen -e|-v`) are
  blocked in every mode; scoped uses (`printenv PATH`, `env FOO=1 cmd`,
  `set -e`) stay allowed. Targeted reads of secret-like names are denied.
- **Bulk interpreter dumps are denied, member access stays allowed.**
  `console.log(process.env)`, `print(os.environ)`, `puts ENV`, `print %ENV`,
  `print_r($_ENV)` and `Deno.env.toObject()` are blocked; single-variable reads
  (`process.env.PATH`, `os.environ.get("X")`) stay allowed. Staged copies remain
  a documented residual.
- **Destructive root targets and proc/metadata/docker-escape backstops are
  mode-independent.** `rm -rf /|/*`, `/..` traversals, `chmod 777 /`, `chown /`,
  `mkfs`, `dd of=/dev/…`, `/proc/*/environ`, the cloud metadata IP and
  `docker -v /:/`, `--volume /:/`, `--mount …,source=/,…`, `--privileged` are
  blocked even with `setting.security_policy=off`.
- **Git exfiltration over key material is denied.** `show`/`cat-file` of key
  paths, `log -p`, non-`--stat` `diff`, `grep` and `archive` over
  `*.key`/`*.pem`/key-like names are blocked; ordinary git metadata is allowed.
- **Write confinement depends on the guard.** If the guard fails to load, writes
  fall back to Pi's runtime defaults. The guard is baked read-only, so a session
  cannot relax it, but it is the enforcement layer.
- **Prompt injection is only partly mitigated.** Rules and hooks reduce impact;
  they do not make the agent trustworthy. Review its actions.

## Reporting a vulnerability

Open a private security advisory on the repository, or email the maintainers.
Please include a reproduction (command, `DRY_RUN=true` output, and container
configuration) and the expected vs. observed behavior. Do not open a public
issue for exploitable findings before a fix is available.
