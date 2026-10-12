# Changelog

Notable changes per release. The wrapper version is `WRAPPER_VERSION` in
`bin/pi-dockerized`; the guard version is `GUARD_VERSION` in
`extensions/pi-security-guard/policy.mjs` (shown by `pi-dockerized version`).
Maintainers tag releases (`vX.Y.Z`); tags trigger the image workflow.

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
