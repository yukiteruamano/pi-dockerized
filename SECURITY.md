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
| Immutable guard and extensions | The guard is baked into the image and locked read-only together with `AGENTS.md`. Pi Packages are installed on the host with the official `pi install` (`pi-dockerized extensions`) and mounted read-only (`settings.json`, `npm/`, `git/`), so the agent cannot add, remove or update them; `mcp.json`, `models.json`, `skills/` and the host `settings.json` are likewise mounted read-only from the host. The host `settings.json` is validated at every start: its security keys must match the baked ones and it may hold only preference keys (no packages, extensions, skills, prompts, themes, command, proxy or telemetry settings). `prompts/` and `themes/` are mounted **read-write** as data: a session can change prompt templates that later sessions load, so review them on the host The writable state (`sessions/`, `auth.json`, `mcp-auth.json`, `trust.json`, `mcp.log`) is bind-mounted read-write from the host. `pi update`/`pi install`/`pi mcp add/remove` are additionally blocked by the guard |
| Read-only MCP config | `mcp.json` is mounted **read-only** from the host; only OAuth tokens (`mcp-auth.json`) and `trust.json` are writable |
| Project-only writes | Only the project directory and `/tmp/pi` are writable (enforced by the guard, resolving symlinks via `realpath` so a link inside the project cannot escape) |
| Secret reads | The guard refuses reads of `.env` (except `.env.example`), `*.pem`, `*.key`, key-like names, `auth.json`, `mcp-auth.json`, `trust.json`, `credentials*`, `~/.npmrc`, `~/.mcp-auth/`, `~/.ssh/`, `~/.aws/`, `~/.kube/`, `~/.docker/config.json`, `~/.netrc`, `~/.git-credentials`, SSH keys and `private-keys-v1.d/` — via both the file tools and shell commands. Each input value is tested on its own, so a trailing parameter cannot hide a target |
| Quoting tricks | Shell commands are also tested de-obfuscated: `''`/`""` pairs, backslash escapes, `${IFS}` and `$'\x2e'`/octal ANSI-C strings are resolved before the patterns run (`cat .e''nv`, `c''at .env`, `ca\t .env`) |
| Dangerous commands | Guard backstops for `sudo`, `rm -rf /`, `mkfs`, `dd of=/dev/…`, `shutdown`/`reboot`, root mounts and metadata-IP reads |
| Git host-execution vectors | The project directory is shared with the host, so planting a Git hook is a sandbox escape. `write`/`edit` cannot touch `.git/hooks/**`, `.git/config`, `.git/info/attributes` or `.gitmodules` (symlinks resolved), and shell commands that redirect/copy into them, or set `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.editor`, `core.pager`, `core.askpass`, `credential.helper` or `gpg.program`, are blocked |
| Bounded evaluation | A single input value over 32 KiB is refused (fail closed). Several patterns are quadratic on long lines (100 KiB took ~50 s), which would stall the guard; at the cap the worst case is a few seconds |
| Unknown tools | `strict` refuses tools the policy does not model (MCP, other extensions) unless listed in `setting.allowed_tools`; `balanced` scans their values with the vendored patterns |
| Fail closed | `entrypoint.sh` runs the guard's self-test (pattern files present and non-empty, canary calls judged correctly) before every container command and refuses to start otherwise; a policy exception while evaluating a call blocks it |
| Mount policy | Custom mounts are validated on the literal and the symlink-resolved path: never `$HOME` or a parent, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/.config/{gcloud,gh}`, `~/.netrc`, `~/.git-credentials`, the wrapper's config root (secrets file, every profile) or the Docker socket; targets must be absolute, must not hide system paths and must not sit inside the baked agent directory. The project mount gets the same container-path check (`~/etc` would otherwise land on `/etc`). Sources are bound with `--mount`, so a missing path fails or is skipped rather than being created as a root-owned directory |
| Audit | Every blocked call is appended (tool, rule, truncated and credential-redacted target) to `audit.log`; `pi-dockerized audit` reviews it |
| Host allow rules | `allow.json` is mounted read-only and only relaxes the vendored patterns, never the backstops; it is not mounted for `--untrusted` sessions |
| Image integrity | The base image is pinned by digest, the nvm/uv/pnpm installers by SHA-256, Node by major and qmd by version. New images are smoke-tested before they replace the current one (which is kept for `rollback`). Prebuilt images are published from CI with provenance and an SBOM, signed keyless with cosign; `pull` verifies the signature of the digest it actually pulled |
| Update verification | `update` lists the incoming commits first; `--verify` / `setting.verify_updates=true` requires a valid signature on the upstream head (`git verify-commit`) |
| Output hygiene | Control characters are stripped from everything the wrapper prints (a directory or config value cannot inject terminal escapes); errors and warnings go to stderr |
| Private state | The state tree is `0700` and its token files `0600` |
| Policy patterns | The vendored policy pattern sets (upstream `opencode-policy`), evaluated by `extensions/pi-security-guard/policy.mjs` (see `policies/README.md`) |
| SSH agent forwarding (opt-in) | `setting.ssh_agent_support=true` forwards only `SSH_AUTH_SOCK` and mounts `~/.ssh/config`/`known_hosts` read-only; private keys (`id_*`, `*.pem`, `*.key`) are never mounted, and a custom mount of `~/.ssh` is refused |
| GnuPG agent forwarding (opt-in) | `setting.gpg_agent_support=true` mirrors only the public keyring (`pubring.kbx` / `public-keys.d`) and forwards the host `gpg-agent` socket (preferring the restricted `S.gpg-agent.extra`); `private-keys-v1.d/` is never copied or mounted, and a custom mount of `~/.gnupg` is refused |
| No self-update | `PI_SKIP_VERSION_CHECK=1` and the guard block `pi update` |

## Known limitations

- **Docker socket is opt-in but root-equivalent.** With
  `setting.docker_socket=true` the container gets the host Docker socket, which
  allows mounting `/` and escaping to host root. It is **off by default**, and
  the image only contains the Docker CLI when built with it on. A custom mount
  of the socket is refused.
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
- **The guard is baked; extensions are not.** Editing the guard has no effect
  until `pi-dockerized build` (or `update`). Extensions live on the host and
  apply to the next session, no rebuild.
- **Pi Packages are trusted code.** They run inside Pi with the session's full
  permissions, including the provider keys in its environment, and can register
  handlers alongside the guard's; a malicious or compromised one can defeat the
  guard. They are mounted read-only, so a *session* cannot add or alter them,
  but nothing vets what you install: pin versions, review sources, prefer few.
  `extensions install` runs the official `pi install` in a throwaway container
  with no secrets, project or session state, on the bridge network, and npm
  install scripts are off by default (`--allow-scripts` opts in). `--untrusted`
  sessions load none.
- **The packages' `settings.json` is Pi-written and host-editable.** Sessions
  mount it in place of the baked one, so its security keys
  (`defaultProjectTrust`, `sessionDir`, `defaultTools`, `enableInstallTelemetry`)
  are seeded from the image, reapplied after every Pi command and checked by
  `entrypoint.sh` before every session (fail closed). Everything else in it
  (packages, theme, model, ...) is yours.
- **Skills are read-only.** `skills/` is mounted read-only from the host, so a
  session cannot add or change skills (which instruct the model). Edit them on
  the host and review what you install.
- **Project trust asks, it does not trust.** The baked `settings.json` sets
  `defaultProjectTrust: "ask"`. Interactive sessions prompt before loading
  project `.pi/` extensions, MCP servers, skills and prompts; `exec`/print
  sessions skip them. A project extension is code that runs inside the Pi
  process, so accepting the prompt for an untrusted repository means running
  that code (the container limits its reach, but the guard may not see it).
  Trust only repositories you wrote or reviewed.
- **MCP OAuth tokens and trust decisions are read-write.** `mcp-auth.json` and
  `trust.json` (which stores `/trust` decisions) are mounted read-write so
  sign-in and trust persist; the agent could read or alter them. The guard
  blocks reads of `trust.json` and writes outside the project and `/tmp/pi`.
- **Environment variables in the container are visible to the agent.** Provider
  keys from the secrets file end up in the container environment and in
  `docker inspect` on the host. Keep unrelated host secrets out of the env file.
- **Inline secrets in `mcp.json` abort the run.** MCP credentials must use
  `${VAR}` references; literal `apiKey`/`token`/`secret`/`password` values are
  rejected by the wrapper and reported by `doctor`.
- **Secret reads are heuristic.** Quoting and escaping tricks are resolved, but
  values assembled at run time (`a=.e; b=nv; cat $a$b`), command substitution
  and `base64 | sh` stagers are out of reach of a regex over the command text;
  the container boundary has to hold there. The bare `*key` heuristic also
  blocks unrelated names ending in "key" (e.g. `monkey`).
- **The audit log is writable by the session.** It is a review aid, not
  tamper-proof evidence. The same holds for `sessions/`.
- **Test hooks.** `GPG_AGENT_PROBE_CMD`, `GPG_AGENT_LAUNCH_CMD` and
  `GPG_RELAY_CMD` run arbitrary commands and are honored only with
  `PI_DOCKERIZED_TEST=1`.
- **`--untrusted` is a profile, not a proof.** It tightens policy, network and
  host access, but the project directory is still mounted read-write and the
  secrets file (provider keys) still reaches the container environment.
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
- **Write confinement depends on the guard.** The guard is baked read-only, so a
  session cannot relax it, and the boot self-test stops the container when it is
  damaged. Shell commands that write outside the project (`> /etc/x`) are not
  confined by the guard; the image filesystem permissions are what stop them.
- **Prompt injection is only partly mitigated.** Rules and hooks reduce impact;
  they do not make the agent trustworthy. Review its actions.

## Reporting a vulnerability

Open a private security advisory on the repository, or email the maintainers.
Please include a reproduction (command, `DRY_RUN=true` output, and container
configuration) and the expected vs. observed behavior. Do not open a public
issue for exploitable findings before a fix is available.
