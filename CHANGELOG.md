# Changelog

Notable changes per release. The wrapper version is `WRAPPER_VERSION` in
`bin/pi-dockerized`; the guard version is `GUARD_VERSION` in
`extensions/pi-security-guard/policy.mjs` (shown by `pi-dockerized version`).
Maintainers tag releases (`vX.Y.Z`); tags trigger the image workflow.

## Unreleased

### Security (guard 8)

- **Credential store:** `pi auth login`/`pi auth logout` (new in Pi 1.5.1) are
  blocked in sessions: `auth.json` is bind-mounted read-write, so a session
  could log the user out or plant foreign credentials. Reading auth status
  stays allowed; the user logs in from the host (`pi-dockerized auth`).
- **Fewer false positives:** common English words ending in "key" (`monkey`,
  `hockey`, `hotkey`, `turnkey`, …) no longer trip the bare-`*key` secret
  backstops: `cat monkey.py` and reading `hotkey` pass, while `apikey`,
  `deploy_key`, `server.key` and `monkey.key` stay blocked. Only the exact
  word is exempt. Regression tests cover both directions.
- **Process cap:** containers now run with `--pids-limit` (default 4096,
  `setting.pids_limit`, `unlimited` to disable). The balanced policy drops the
  fork-bomb patterns on purpose; the kernel now enforces the bound instead.
- **Audit:** `audit`/`audit --summary` end with a hint (stderr) saying which
  rules accept host allow rules (`pi-policy/*`) and which are built-in
  backstops (`backstop/*`).

### Fixed (concurrent sessions with SSH/GnuPG forwarding)

- **GnuPG:** every session now mirrors the public keyring into its own
  directory (`home/.gnupg-sessions/<wrapper PID>/`, removed when it ends)
  instead of one shared `home/.gnupg`. Starting a second session used to
  delete the running session's agent link and keyboxd socket in the shared
  mirror (signing broke there, transiently or for good), and lock files from
  one container could block gpg in another. Mirrors of dead sessions are
  cleaned at the next start. The old `home/.gnupg` is no longer used and can
  be deleted.
- **Relay:** stale-relay cleanup judged an entry by its socat PID, which is
  written after the entry is created, so a session starting at the same time
  could delete another's fresh relay socket. An entry is now live while the
  wrapper that created it or its socat runs; a leftover entry with the same
  PID (reboot) is replaced instead of making socat fail.
- SSH needed no change: the agent socket is shared as-is (ssh-agent serves
  concurrent clients) and `~/.ssh/config`/`known_hosts` are read-only.

### Changed (profile layout — automatic migration)

- **Every profile now lives in `~/.config/pi-dockerized/profiles/<name>/`,
  `default` included.** The default profile used to share the config root
  with `profiles/`; its config, secrets file, state tree, relay dir and
  backups now sit in `profiles/default/` like any other profile, and the root
  `config` keeps only routing (`setting.default_profile`, `profile.map.*`).
- **Migration:** the first run of the new wrapper (any command; `update` and
  `upgrade` trigger it right after pulling) moves the old default profile into
  `profiles/default`, keeps `default_profile`/`profile.map` in the root config
  (commented out in the profile's copy), rewrites `setting.env_file` when it
  pointed at the old location, and keeps your comments, mounts and backups.
  It is resumable (staged in `profiles/.default.migrating`, renamed into place
  only when complete), stays on one filesystem so running sessions keep their
  mounts, and never reads secrets. `profile check default` reports anything
  left behind in the root. Downgrading to 0.16 after the migration would see
  an empty default profile: move `profiles/default/*` back to the root first.
- `config set default_profile NAME` writes the root config from any profile
  and refuses a profile that does not exist; `profile root [path|edit]` opens
  the routing config. `uninstall --purge-config` deletes the active profile
  only; with `--all-profiles` it deletes the whole config root.

### Added (multi-account profiles)

- `profile` command: every profile operation in one place — `list`,
  `create NAME`, `remove NAME [--yes]`, `show [NAME] [--sources]`,
  `path [NAME]`, `check [NAME]`, `fix [NAME]` and `run NAME [RUN ARGS]`
  (= `--profile NAME run`). Profiles are created explicitly, and any other
  command naming an unknown profile fails (exit 3), so a typo in `--profile`
  can never silently run a session on a fresh empty profile with default
  settings. `remove` refuses while the profile has running sessions and asks
  for confirmation (a symlinked alias loses only the link).
- `profile check NAME` audits the whole profile: directory (real, owned,
  private, not an alias of another), config file (present, `0600`, valid
  entries, no root-only routing lines), secrets file (inside the profile, no
  sandbox-controlling keys), state tree, and for `default` the routing to
  missing profiles. `profile fix NAME` repairs structure and permissions,
  comments out root-only lines after a backup, points `env_file` at the
  profile's own `env` when it borrowed another one, then checks again. Secrets
  are never read or copied.
- No duplicate profiles: names that differ only by case or `-`/`_` are
  refused (also for `--profile NAME install`), creation is an atomic `mkdir`,
  and `profile list` flags look-alikes and stray entries.
- Separate secrets per profile: a profile's config template names its own
  `env` file, and every profile (`default` included) refuses an `env_file`
  outside its own directory.
- **Named profiles that already exist keep working as-is** — the existence
  check is on the profile directory, which every earlier flow (`run`,
  `install`, `config set`) created; one without a `config` file still warns
  and runs on defaults, as before (a regression test pins this). Only scripts
  that relied on `--profile NAME run` auto-creating a profile on first use
  must now call `pi-dockerized profile create NAME` (or `--profile NAME
  install`) first.
- `setting.default_profile` (root config only): the profile used when
  `--profile` is not given; `--profile default` names the default profile and
  escapes it.
- `profile.map.<key>=<path>:<profile>` (root config only): sessions started in
  a mapped directory re-exec under that profile (longest path wins, explicit
  `--profile` always takes precedence, `default` maps back to the root
  profile). Host-side only by design: a file inside a repository must never
  choose which account/keys it gets.
- Sessions carry a `pi-dockerized.profile` label; `ps` (and `ps --json`) show
  the profile column.
- Shell completions (bash and zsh) rewritten to cover the whole CLI: every
  command and its flags, `config` subcommands with per-setting values
  (`config set network <TAB>` → `host bridge`, booleans, policies, profile
  names, files for `env_file`), `profile` subcommands with profile names,
  `install --only` comma lists, `--pi-version latest`, and the session flags
  after `profile run NAME`. The command is found even after
  `--profile NAME`. A contract test keeps both files in sync with the help
  text and `SETTING_KEYS`.
- Fixed the zsh completion for `run`/`shell`/`exec`/`models`: a missing line
  continuation made zsh execute `'--timeout[...]'` as a command, breaking
  completion with an error instead of offering the session flags. Reload the
  shell (`exec zsh` / new terminal) after upgrading so the fixed functions
  load.

### Security (guard 7)

Fixes from a full audit; every confirmed bypass has a regression test.

- **Git host execution:** `write`/`edit` refuse anything under a `.git` path
  component (including `commondir`, `modules/*/config`, `config.worktree` and a
  `.git` gitfile) and `.gitmodules`, case-insensitively. The shell backstop
  refuses redirects, file verbs and one-liners into `.git` (tolerating
  `.git//hooks` and `.git/./hooks`), `cd`/`pushd .git` and `git -C .git`.
  `git config` writes are limited to `user.name/email`, `init.defaultBranch`,
  `pull.rebase/ff`, `push.default/autoSetupRemote`, `core.autocrlf/eol` and
  `color.*`; `include.*`, `diff.external`, `filter.*`, `gpg.ssh.program` and
  similar are refused, also through `git -c`.
- **Symlinks:** a symlink as the final component of a write path (dangling
  included) is followed hop by hop and its target checked; loops are refused.
  Write paths starting with `~` are refused.
- **Secrets:** `mcp-auth.json`, `trust.json` and any `*auth.json` are blocked
  from the shell too; the read tool refuses `/proc/*/environ` in every mode.
  `env -0`, `printenv -0`, `$(printenv)`, `/proc/self/task/*/environ` and
  `json.dumps(os.environ)`-style dumps are blocked. Bare `$IFS`, brace lists
  and globs aimed at secret names (`cat .en[v]`, `cat auth.jso?`) are caught.
- **Allow-lists:** neither the built-in allow patterns nor the host
  `allow.json` apply to values containing `$(`, backticks, `${`, `<` or `>`
  (`cat .env.example $(printenv)` used to bypass every vendored rule).
- **Unknown tools:** MCP/package tools go through the shell backstops in every
  mode. `allowed_tools` scopes match URLs by host and path segment and paths by
  prefix, never as a substring of the input (review non-URL scopes).
- **Performance:** worst-case inputs at the 32 KiB cap scan in milliseconds
  (previously up to 5 s, one rule over 100 s).
- **Packages settings:** `shellPath`, `shellCommandPrefix`, `npmCommand`,
  `externalEditor`, `httpProxy` and `extensions` are refused in the Pi Packages
  `settings.json`.

### Security (wrapper and image)

- **Immutable guard:** the guard, `AGENTS.md`, settings, `mcp.json`, `skills/`,
  `prompts/` and `themes/` are now root-owned in the image, and `/home/coder`,
  `~/.pi` and `~/.pi/agent` are `root:coder 1775`. Before, they were owned by
  `coder` (uid 1000, usually the session uid), so a session could `chmod` the
  guard writable or rename it away. `container/lock-check.sh` enforces this at
  build time, in the entrypoint (exit 5) and in `doctor`. Images built before
  this change fail the check: rebuild.
- **Project directory:** it now goes through the same gate as custom mounts.
  `run ~/.ssh`, `run ~/.config/pi-dockerized`, `run /run` and similar are
  refused, and a symlinked `$HOME` is recognized.
- **Mount policy:** sources in, containing or above socket directories (`/run`,
  `/var/run`, `$XDG_RUNTIME_DIR`) or under `/proc`, `/sys`, `/dev` are refused;
  targets may neither contain nor sit inside system paths (`/usr`, `/etc`
  files such as `ld.so.preload`, `/bin/sh`) or the agent dir.
- **`--untrusted`:** only `--policy strict` is accepted, `allowed_tools` is
  cleared, and no shared state is mounted (`mcp.json`, `mcp-auth.json`,
  `trust.json`, `mcp.log`, `.npm`, `.cache/qmd`, `.pi-lens`, `~/.claude`,
  `~/.agents`, worktree git dir). `prompts/`/`themes/` are read-only and
  transcripts go to `sessions-untrusted/`.
- **Git worktrees:** the common dir is mounted only when it points back at the
  project and passes the mount checks; never for `--untrusted`.
- **Secrets file:** loader/runtime keys (`LD_*`, `NODE_OPTIONS`, `PATH`,
  `PI_DOCKERIZED_*`, …) are refused. Edits are staged next to the file instead
  of `/tmp/pi`, which is only used when owned by the user with safe permissions.
- **GnuPG relay:** `GPG_RELAY_DIR`, `GPG_AGENT_SOCKET` and
  `GPG_AGENT_EXTRA_SOCKET` are honored only in tests (an env var could make the
  stale-relay cleanup delete arbitrary directories); cleanup runs only with GPG
  enabled and only removes relay dirs. Mirror writes refuse symlinks.
- **`audit`** strips control characters from the container-written log.
- **Updates:** `update --verify` merges exactly the verified commit (no second
  fetch) and, when `.github/release-signers` exists, requires a listed signer.
  `install.sh` honors `PI_DOCKERIZED_VERIFY=1`. The image is built by the
  updated wrapper, so it carries the new version label.
- **Images:** `pull` verifies the signature against `image.yml` at a `vX.Y.Z`
  tag only and refuses older images unless `--allow-downgrade`. CI pushes by
  digest, smoke-tests amd64 and arm64 as pushed, signs and only then tags;
  non-release runs publish `dev-<sha>`. `rollback` can be repeated, and a
  same-image promotion keeps the real `:previous`.
- **Supply chain:** pnpm refuses npm releases younger than 24 h; yt-dlp is
  pinned; the Docker apt key is checked by fingerprint; the pnpm installer is
  required to verify its tarball signature. `refresh-policies.sh` validates all
  files before copying and pins the upstream integrity.
- **CI:** the `GUARD_VERSION` check also runs on pushes to master and requires
  the number to increase.
- **Install/uninstall:** `uninstall` removes only the lines the installer wrote,
  `--purge-config` keeps other profiles unless `--all-profiles`, and only
  deletes directories named `pi-dockerized` (or a profile in it).
- `exec -` refuses prompts over 120000 bytes (they are passed in argv).

### Build

- Version bump: pnpm 12.16.1, uv 0.13.6, Debian `trixie-slim` base digest
  refreshed (pinned by manifest-list digest, amd64 + arm64). The unversioned
  pnpm installer script changed upstream, so `PNPM_INSTALL_SHA256` is repinned
  to the reviewed script (still only `get.pnpm.io`, `registry.npmjs.org` and
  `github.com/pnpm/pnpm/releases`). Node.js stays on 24: the new active LTS
  (26) can break qmd's native modules (`better-sqlite3`, `node-llama-cpp`) and
  the image has no build toolchain for a node-gyp fallback.
- Fix the image build on the 12.16 line: that release moved the global virtual
  store into the content-addressable store (`$PNPM_HOME/store/v11/links`) and
  installed pnpm itself there too, so the BuildKit cache mount on
  `$PNPM_HOME/store` (qmd and pi layers) hid the target of the
  `$PNPM_HOME/bin/pnpm` shim and the build failed with `exec: ... not found`
  (exit 127). `PNPM_CONFIG_VIRTUAL_STORE_TYPE=project` keeps global installs
  under `$PNPM_HOME/global`, which is part of the image, while the cache mount
  still avoids re-downloading.
- Pi 1.5.2 (from 1.4.0). Pi 1.5.0 added `selfUpdateCommand` and
  `PI_SELF_UPDATE_COMMAND`, a command `pi update` runs; `extensions update`
  runs `pi update`, so the key is refused in the Pi Packages `settings.json`
  (dropped by `enforce`, fails the entrypoint check) and the variable in the
  secrets file. Sessions still block `pi update` through the guard.

### Security (guard 6)

- Evaluation cap raised from 16 KiB to 32 KiB per value (and joined total),
  measured: realistic 32 KiB inputs scan in milliseconds with the current
  pattern sets. The quadratic worst case grows with the cap; MCP/unknown
  tools keep the same cap (no per-tool bypass).

### Security (guard 5)

- Scoped strict allowlist: `setting.allowed_tools` entries can be `name` (as
  before) or `name:scope+scope`, restricting an unknown tool to inputs
  containing a scope (`mcp_fetch:example.com`). Out-of-scope calls are blocked
  as `backstop/unknown-tool-scope`.
- Guard evaluation caps each value at 16 KiB (not just the joined total), so
  one huge field can no longer reach the quadratic matchers; compiled patterns
  are shared across loads.
- Forwarded SSH/GPG sockets must be owned by you, enforced at the mount site.
- `scripts/refresh-policies.sh` verifies the tarball against the registry's
  `dist.integrity` (fail-closed, `--no-verify` to skip) and records the
  upstream version in `policies/.upstream-version`.
- Sessions warn (never block) when the project contains credential-looking
  files (`.env`, `*.pem`, keys), listed by name in the `Exposure:` output.

### Added

- `run --resume [ID]` / `run --list`: resume Pi sessions (`--session`/
  `--resume` passthrough) and list local ones without a container.
- `run`/`shell`/`exec` take `--timeout` (e.g. `5m`); refusal (not silence)
  when `timeout(1)` is missing.
- `ps --json` (one object per line) and `stats --json` (local session files).
- `config get <key> --source` and `config show --sources` (config file/default).
- `doctor --fix`: host-state repair via `config sync`, then diagnose as usual.
- `audit --explain [N]`: what rule fired, why, and how to proceed.
- `build --fresh` (pull a newer base), build timestamp label with a >90-day
  staleness warning, best-effort local SBOM on promote, and a stricter smoke
  test (no `sudo`, loose host settings rejected).
- `update`/`upgrade` roll the code back after a failed rebuild (never with a
  dirty worktree, never non-interactively without `--yes`).
- `stop --all` asks for confirmation (`--yes`/`--force` for scripts) and
  suggests similar names for unknown sessions.
- `exec`/`models` separate dash-leading input with `--` so it cannot parse as
  a Pi flag (trailing Pi flags keep working).
- Stable exit codes: 2 usage/project, 3 config, 4 Docker/image, 5 guard refusal.
- Config backups: every write keeps a timestamped copy (last 5).
- Docs: `docs/config-reference.md`, `docs/troubleshooting.md`, validated
  `examples/{mcp,allow,settings}.json.example`, issue/PR templates, and a
  weekly Docker e2e workflow.

### Changed

- Guard block messages now say `pi-policy/<id>` (was `opencode-policy/<id>`);
  remaining `opencode-policy` mentions refer to the upstream package only.
- Fuzz corpus for shell de-obfuscation locked in as regression tests.
- Completions cover the new flags and no longer break with `--profile`; CI
  gains advisory `shfmt`/`actionlint` steps.

### Removed (breaking)

- `pi-dockerized.sh`, `setup.sh`, `run-simple.sh` are deleted (were deprecated
  compat shims slated for v1.0). Use `bin/pi-dockerized` on PATH
  (`pi-dockerized install` sets it up).

## 0.16.0 — guard 4

### Security

- **Mount policy.** Custom mounts can no longer expose `$HOME` (or a parent),
  `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/.config/gcloud`,
  `~/.config/gh`, `~/.netrc`, `~/.git-credentials`, the wrapper's own config
  directory (secrets file, all profiles) or the Docker socket. Sources are
  checked on the literal and symlink-resolved path; relative host paths are
  refused; container targets that would hide system paths or sit inside the
  baked agent directory are refused; the project mount gets the same container
  path check (`~/etc` used to land on `/etc`). Sources are bound with
  `--mount`, so a missing source is skipped with a warning instead of being
  created by Docker as a root-owned directory.
- **Guard: Git host-execution vectors.** `.git/hooks/**`, `.git/config`,
  `.git/info/attributes` and `.gitmodules` cannot be written, and shell commands
  setting `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.editor`,
  `core.pager`, `core.askpass`, `credential.helper` or `gpg.program` are blocked.
- **Guard: de-obfuscation.** Commands are matched after removing quotes and
  backslash escapes and decoding `$'\x..'`/octal strings.
- **Guard: bounded evaluation.** A value over 16 KiB is refused; 100 KiB used to
  stall the guard for ~50 s on some patterns.
- **Guard: contents are data.** `write`/`edit` only check their path fields, so
  writing docs or tests that mention `rm -rf /` or `.env` works; `DENY_READ` is
  applied per value, so a trailing parameter cannot hide a target.
- **Guard: more credential stores** (`.git-credentials`, `.netrc`, `.aws`,
  `.kube`, `.docker/config.json`).
- **Guard: unknown tools.** `strict` refuses tools the policy does not model
  unless listed in `setting.allowed_tools`; `balanced` scans their values.
- **Fail closed.** `entrypoint.sh` runs `selftest.mjs` (pattern files present and
  non-empty, canary calls) before every container command; a policy exception
  blocks the call; missing/invalid pattern files and rules are reported on
  stderr instead of silently disabling rules.
- **Audit log** (`pi-dockerized audit`) and **host allow rules**
  (`config allow edit`, mounted read-only).
- **Test hooks** that run commands (`GPG_AGENT_PROBE_CMD`, `GPG_AGENT_LAUNCH_CMD`,
  `GPG_RELAY_CMD`) require `PI_DOCKERIZED_TEST=1`.
- Output hygiene: control characters are stripped from printed values, errors
  and warnings go to stderr, no more `echo -e` on user data.
- State tree `0700`, token files `0600`.
- Image: digest-pinned base, SHA-256-checked nvm/uv/pnpm installers, Node major
  and qmd pinned, Docker CLI only when `setting.docker_socket` is on, OCI labels.
- `update` lists incoming commits and can require a signed upstream head
  (`--verify` / `setting.verify_updates`); it keeps the pinned Pi release unless
  `--pi-version` is given.

### Changed (breaking): extensions are host-managed

- Extensions are no longer installed at image build time and `install-extensions`
  is gone. Only Pi Packages installed with the official `pi install` are
  supported (no custom or hand-written extensions, no local paths). They live on
  the host in `home/.pi/ext-agent/` (Pi's `settings.json`, `npm/`, `git/`),
  survive rebuilds, and sessions mount them read-only over the agent's own once
  something is installed (never for `--untrusted`). The guard stays baked.
- `pi-dockerized extensions list|install|remove|update|path|edit` run the real
  `pi list|install|remove|update` in a throwaway container (bridge network,
  read-write ext-agent dir, no secrets file, no project, npm install scripts off
  unless `--allow-scripts`) through the baked `container/ext-install.sh`.
- Since Pi writes the `settings.json` sessions then use, `container/ext-agent.mjs`
  seeds it from the image's defaults, reapplies the security keys
  (`defaultProjectTrust`, `sessionDir`, `defaultTools`, `enableInstallTelemetry`)
  after every Pi command, and `entrypoint.sh` refuses to start a session whose
  settings loosen them. The image smoke test checks that the official `pi list`
  reads a seeded ext-agent directory.
- To migrate: run `pi-dockerized extensions install <source>` for each line you
  had in `install-extensions`.

### Added

- Commands: `shell`, `ps`, `stop`, `audit`, `pull`, `rollback`, `uninstall`,
  `config get|set|allow|profiles`.
- Session flags `--untrusted`, `--policy`, `--network`, `--dir`; an `Exposure:`
  summary before every project session.
- Profiles (`--profile NAME`): separate config, secrets file, MCP servers,
  sessions and audit log.
- `exec` reads the prompt from stdin (`-` or a pipe), takes `--dir` and returns
  Pi's exit code.
- Image lifecycle: candidate build → smoke test → promote, `:previous` kept,
  `<wrapper>-guard<N>` tags, drift warnings; signed multi-arch images published
  by CI (`image.yml`) and verified by `pull`.
- qmd (`@tobilu/qmd`, pinned) in the image, with its index/models persisted in
  `home/.cache/qmd`.
- `scripts/refresh-policies.sh`, Renovate config, gitleaks/Trivy workflow,
  `selftest.mjs`, `balanced-excluded.json` (grouped, with reasons, validated
  against the vendored IDs).

### Changed

- **Project trust is `ask`, not `never`.** The baked and pinned
  `defaultProjectTrust` is now `ask`: interactive sessions prompt before loading
  a project's `.pi/` resources; print/exec sessions still skip them. Existing
  host `settings.json` files that say `never` fail the start check until that
  key is changed to `"ask"`.
- **Host-managed `settings.json`.** The host file (seeded once from the baked
  defaults, now documented in `container/settings.base.json`) is mounted
  read-only. It may hold only preference keys (`PREFERENCE_KEYS` in
  `ext-agent.mjs`); packages, extensions, skills, prompts, themes, command
  settings, proxy and telemetry keys, and any change to the security keys stop
  the session at start. While Pi Packages are installed, their settings file is
  mounted instead and the host preferences are not applied.
- **Host-managed Pi data.** `prompts/` and `themes/` are mounted read-write from
  the host (`~/.config/pi-dockerized/home/.pi/agent/`), `models.json` read-only
  (not mounted with `--untrusted`), and `~/.pi-lens` is persisted on the host so
  pi-lens state survives restarts.
- **Baked global `AGENTS.md`.** `container/AGENTS.md` again forbids system-wide
  installs and no longer claims extensions are fixed at build time (Pi Packages
  are host-managed); a guard test keeps it consistent with the guard's write
  root and size limit.
- The wrapper is split into `lib/cmd/*` and `lib/install/*`; `bin/pi-dockerized`
  only dispatches. Diagnostics moved to `container/doctor.sh` and
  `container/auth-check.sh`.
- The config loader reads the file once, reports unknown settings/invalid
  values with line numbers, and no longer drops a last line without a newline;
  `save_config` edits in place and keeps comments and unknown entries.
- The guard version is `GUARD_VERSION` in `policy.mjs` (was a comment in
  `index.ts`); `version` and `doctor` read it from the image.
- `build`/`update` tag through `promote_image`; `clean` removes every tag.
- CI actions are pinned by commit SHA; the guard tests run on Node 22 and 24.
- Entry point no longer sources NVM when `node` is already on `PATH`.

### Deprecated

- `pi-dockerized.sh`, `setup.sh`, `run-simple.sh` print a removal notice; they
  will be removed in v1.0.

### Not done / known gaps

- Keeping provider API keys out of the container environment (credential
  injecting proxy) is not implemented.
- The published image is built without the Docker CLI; build locally with
  `setting.docker_socket=true` if you need it.
