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
bash -n bin/pi-dockerized install.sh pi-dockerized.sh setup.sh run-simple.sh entrypoint.sh
for f in lib/*.sh completions/*.sh; do bash -n "$f"; done

# 2. ShellCheck (any of these)
shellcheck -x -S warning bin/* lib/*.sh install.sh setup.sh pi-dockerized.sh run-simple.sh completions/*.sh
# …or without a local install:
cat lib/config-lib.sh | docker run --rm -i koalaman/shellcheck:stable -s bash -x -S warning -

# 3. Dockerfile
cat Dockerfile | docker run --rm -i hadolint/hadolint:latest hadolint -

# 4. Policy + wrapper contract tests (Node.js 22+)
node --check extensions/pi-security-guard/policy.mjs
node tests/security-guard.test.mjs
bash tests/wrapper-args.test.sh
```

## Style

- Follow the conventions in [AGENTS.md](AGENTS.md) (kebab-case scripts,
  snake_case functions, UPPER_SNAKE constants, quoted variables, `$()`, arrays
  for Docker arguments).
- Every executable script starts with `#!/bin/bash` + `set -e`;
  `lib/config-lib.sh` and `lib/install-lib.sh` are sourced libraries and must
  **not** use `set -e`.
- The binary is `bin/pi-dockerized` (no extension), reached via `<install>/bin`
  on PATH. Nothing is ever placed in `~/.local/bin`.
- Keep security the priority: never weaken a deny rule without a documented
  reason and a test.

## Security layer changes

- **`extensions/pi-security-guard/` is the source of truth.** `index.ts` wires
  the Pi `tool_call` handler; `policy.mjs` holds the pure, testable policy
  (pattern loading, `DENY_*` backstops, evaluation). Bump
  `PI_DOCKERIZED_GUARD_VERSION` in `index.ts` when behavior changes.
- The extension is **baked into the image** at build time (the Dockerfile copies
  it and `policies/*.json`), so a change only takes effect after a rebuild.
- **`policies/*.json` are vendored verbatim** from opencode-policy
  (`policies/README.md`). To change behavior for local use, prefer the policy
  mode (`strict` / `balanced` / `off`) or `policies/allow-patterns.json` over
  editing the vendored files.
- Add a case to `tests/security-guard.test.mjs` for every new deny/allow
  behavior — both that the dangerous thing is blocked and that normal
  development is not.

## Extensions at build time

- New extensions/packages go in `install-extensions` (one `pi install` source
  per line, exact pins preferred). They are installed and locked read-only in
  the image.

## Docs

Update `README.md` (and `SECURITY.md` where relevant) for user-visible changes.
The wrapper config lives at `~/.config/pi-dockerized/config`.
