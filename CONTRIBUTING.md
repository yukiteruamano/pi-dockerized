# Contributing

Thanks for helping improve `pi-dockerized`. This project is pure Bash plus a
small TypeScript security extension (`extensions/pi-security-guard/`) with
dependency-free policy logic (`policy.mjs`) and vendored JSON policy data.

## Before you start

```bash
./install.sh          # installs bin/ on PATH, creates ~/.config/pi-dockerized + host state
pi-dockerized build   # builds the Pi image and bakes the extensions
```

## Checks (run before opening a PR)

CI runs all of these; you can run them locally:

```bash
# 1. Syntax
bash -n bin/pi-dockerized install.sh entrypoint.sh
for f in lib/*.sh lib/*/*.sh completions/*.sh scripts/*.sh container/*.sh tests/*.sh; do bash -n "$f"; done

# 2. ShellCheck (any of these)
shellcheck -x -S warning bin/* lib/*.sh lib/*/*.sh install.sh entrypoint.sh scripts/*.sh container/*.sh completions/*.sh tests/*.sh
# …or without a local install (pinned image, same as CI's tool version):
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 -x -S warning bin/* lib/*.sh lib/*/*.sh install.sh entrypoint.sh scripts/*.sh container/*.sh

# 3. Dockerfile
cat Dockerfile | docker run --rm -i hadolint/hadolint:v2.12.0 hadolint --config /dev/null -

# 4. Guard + wrapper tests (Node.js 22.6+ for the extension test)
for f in extensions/pi-security-guard/*.mjs container/*.mjs; do node --check "$f"; done
node tests/security-guard.test.mjs
node tests/guard-extension.test.mjs
node tests/ext-agent.test.mjs
bash tests/wrapper-args.test.sh
bash tests/wrapper-commands.test.sh
```

CI also builds nothing on the contributor's machine, but the image workflow
(`.github/workflows/image.yml`) smoke-tests every release,
`e2e.yml` runs a weekly Docker build + doctor + dry-run pass, and
`security.yml` scans the image and the history for secrets.

## Style

- Follow the conventions in [AGENTS.md](AGENTS.md) (kebab-case scripts,
  snake_case functions, UPPER_SNAKE constants, quoted variables, `$()`, arrays
  for Docker arguments).
- Every executable script starts with `#!/bin/bash` + `set -e`;
  `lib/config-lib.sh`, `lib/config/*.sh`, `lib/cmd/*.sh`, `lib/install-lib.sh`
  and `lib/install/*.sh` are sourced libraries and must **not** use `set -e`.
- Keep each module under ~500 lines; `bin/pi-dockerized` only dispatches.
- Messages go through `print_*`/`config_*` (core.sh): never `echo -e` with user
  data; warnings and errors go to stderr.
- The binary is `bin/pi-dockerized` (no extension), reached via `<install>/bin`
  on PATH. Nothing is ever placed in `~/.local/bin`.
- Keep security the priority: never weaken a deny rule without a documented
  reason and a test.

## Security layer changes

- **`extensions/pi-security-guard/` is the source of truth.** `index.ts` wires
  the Pi `tool_call` handler (rule loading, audit log, fail-closed wrapper);
  `policy.mjs` holds the pure, testable evaluation; `backstops.mjs` the built-in
  deny-lists; `shell.mjs` the de-obfuscation; `selftest.mjs` the boot check;
  `balanced-excluded.json` what the `balanced` mode drops (with reasons).
  **Bump `GUARD_VERSION` in `policy.mjs` when behavior changes** — CI fails a
  pull request that touches the guard or `policies/` without doing so.
- The extension is **baked into the image** at build time (the Dockerfile copies
  it and `policies/*.json`), so a change only takes effect after a rebuild.
- **`policies/*.json` are vendored verbatim** from upstream opencode-policy
  (`policies/README.md`); refresh them with `scripts/refresh-policies.sh` (shows
  the diff first, `--apply` writes it). To change behavior for local use, prefer
  the policy mode (`strict` / `balanced` / `off`), `config allow edit` (host
  `allow.json`) or `policies/allow-patterns.json` over editing the vendored files.
- Add a case to `tests/security-guard.test.mjs` for every new deny/allow
  behavior — both that the dangerous thing is blocked and that normal
  development is not. Wiring (audit, allow file, unknown tools, self-test)
  is covered by `tests/guard-extension.test.mjs`. Regexes over user text must
  stay cheap: the oversize/perf checks in the policy test exist for a reason.

## Extensions

- Extensions are Pi Packages, installed on the host with the **official** Pi
  package commands (`pi-dockerized extensions install`, via
  `container/ext-install.sh`). Do not add a custom installer, support for
  local/hand-written extensions, or a build-time install step: only the security
  guard is baked in.
- `container/ext-agent.mjs` keeps the settings' security keys intact (seed after
  install, enforce, check at every start; tested by `tests/ext-agent.test.mjs`).
  If you add a key to `container/settings.base.json` that is part of the sandbox,
  add it to `SECURITY_KEYS` there. A host `settings.json` may carry only the
  keys in `PREFERENCE_KEYS` (`check --host`); add a preference there only when it
  cannot load code or paths, run a command, route traffic or identify the user.
- Package sources are validated by `validate_ext_source` (`lib/cmd/extensions.sh`):
  keep it to what `pi install` takes, and never let a value be read as an option.

## Docs

Update `README.md` (and `SECURITY.md` where relevant) for user-visible changes.
The wrapper config lives at `~/.config/pi-dockerized/config`.
