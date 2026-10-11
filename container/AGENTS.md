# Security Rules — pi-dockerized

Global rules for every session running inside the pi-dockerized container.
They are enforced alongside the `pi-security-guard` extension (baked read-only
into the image). Do not attempt to weaken or bypass them.

## Commands

- Never run `sudo` or anything as root.
- Never run destructive commands: `rm -rf /...`, `mkfs`, `dd`, `shutdown`, `reboot`.
- Treat `git push` (especially `--force`) as approval-required: explain first.
- Do not control the host Docker daemon (no `docker system prune`, no privileged containers).
- Do not try to change Pi's extensions, MCP servers or Pi itself: they are fixed
  at image build time. `pi update`, `pi install` and `pi mcp add/remove` are blocked.

## Files and secrets

- Never read or print secret files: `.env*` (except `.env.example`), `*.pem`,
  `*.key`, `auth.json`, `mcp-auth.json`, `trust.json`, SSH keys (`id_rsa`,
  `id_dsa`, `id_ecdsa`, `id_ed25519`, `id_*_sk`, `~/.ssh/`), `~/.npmrc`,
  `~/.mcp-auth/`, `~/.gnupg/private-keys-v1.d/`, tokens or credentials of any kind.
- Only modify files inside the mounted project directory; touching anything
  outside it is denied.

## Process

- Review diffs before applying risky changes; prefer small, verifiable edits.
- Ask the user when a command's impact is unclear.
- If a security rule seems wrong for a legitimate task, tell the user instead of
  working around it.

## Tool Usage

The security guard evaluates the whole command string — including prose inside
commit messages, heredocs and `grep` patterns. Keep that in mind:

- Never write the word `sudo` in any command, commit message or `grep` pattern;
  the built-in backstop matches it anywhere. Say "privilege escalation" instead.
- Writable locations are the project directory and `/tmp/pi`. Any other path
  (`~/.config`, `/etc`, `/tmp` outside that folder, …) is denied. Change the
  wrapper config from the host (e.g. `pi-dockerized config edit`).
- Never read or print secret files (`.env`, `*.pem`, `*.key`, `auth.json`,
  `.npmrc`, `.mcp-auth`, SSH keys). Avoid dumping the environment: it carries
  provider credentials from the secrets file (printing it is not blocked).
- Provider credentials arrive via environment variables from the host secrets
  file (`setting.env_file`); never write them into files or print them.
  Reference them as `${VAR}` in `mcp.json`.
- `apt-get`/`apt` are blocked: install dependencies with `uv add` (Python) or
  `pnpm add` (Node).
- Do not reference `/var/run/docker.sock` directly; Docker access is opt-in.
- Prefer small, single-purpose commands; the full string is inspected.
- If a legitimate command is wrongly blocked, tell the user instead of finding
  a workaround.

## Core Workflow — quality bar for every task

Applies to all languages. Security sections above always win on conflict.

- Evidence before synthesis: inspect files with `read`/`grep` before claiming anything; reproduce a bug before fixing it.
- Verify by execution: after implementing or fixing, run the project's build + tests + lint/typecheck and report the output. Never mark work done without running it.
- Prefer project tooling: use `package.json` / `pyproject.toml` / `Makefile` / `CMakePresets.json` / `go.mod` / `Cargo.toml` scripts before generic commands.
- Small, verifiable diffs: prefer `edit` over creating files; never create files unless needed. Review the diff before risky changes.
- Clean code: small single-responsibility functions, intentional names, early returns, no dead code, no `TODO` without a ticket, keep complexity low.
- Maintainability: one module = one responsibility; split files past ~300-500 LOC; keep dependencies one-directional; inject dependencies instead of globals; document only non-obvious `why`, not `what`.
- Modularity: separate I/O / domain / infrastructure; public APIs small and explicit; accept small interfaces, return concrete types; no circular imports.
- Secure by default: validate inputs at the boundary, fail closed, least privilege, never log or return secrets/internals, handle every error path.

## Language Tooling & Practices

The container provides Node.js (NVM), pnpm, uv and Git. Other toolchains
are available only when the project brings them — the practices below still
apply wherever you work. Run lint/typecheck/format through the project's own
tooling when it exists.

### Python — uv only

- Never use `pip`, `python -m pip` or `ensurepip`, not even inside a venv.
- Always create a venv first: `uv venv`, then `uv sync`, run with `uv run`.
- Add dependencies with `uv add`, never by hand-editing `uv.lock`.
- One-off tools via `uvx` (e.g. `uvx httpie`).
- Respect `requires-python` in `pyproject.toml`.
- Clean/verify: `uv run ruff check`, `uv run ruff format --check`, `uv run mypy` or `pyright`, `uv run pytest -q` must pass before handing in work.
- Style: full type hints on public functions, pure functions where possible, `src/` layout, thin `__init__.py`, no circular imports.
- Security: no `eval`/`exec`/`pickle` on external input; use `secrets` for tokens; parameterize SQL; run `pip-audit`/`bandit` when available.

### JavaScript/TypeScript — pnpm only

- Never use `npm install`; use `pnpm add|install|run` and `pnpm dlx`.
- `npx` is acceptable only to serve local MCP servers.
- Respect the `packageManager` field and commit `pnpm-lock.yaml`.
- Clean/verify: `pnpm exec tsc --noEmit`, `pnpm lint`, `pnpm exec prettier --check .`, `pnpm test` must pass before handing in work.
- Style: `strict:true`, no untyped `any` at boundaries (validate with `zod`), small modules, no `eval` / `innerHTML` with untrusted data.
- Security: sanitize HTML, set CSRF/XSS headers server-side, run `pnpm audit` and fix high/critical.

### C/C++

- Set the standard explicitly (`-std=c17`, `-std=c++20`) with `-Wall -Wextra -Werror` in dev/CI.
- Keep builds out of the source tree; prefer CMake (see below).
- Format with the project's configured formatter (`clang-format --dry-run --Werror`); lint with `clang-tidy` when configured.
- Style: headers expose a minimal API (`#pragma once`), `.cpp` holds details; no `using namespace std` in headers; RAII in C++; no mutable globals.
- Security: no `strcpy`/`sprintf`/`gets`; check bounds and return codes; test with `-fsanitize=address,undefined`; pair every allocation with ownership.

### Rust

- `cargo fmt --check`, `cargo clippy -- -D warnings` and `cargo test` must pass before handing in work.
- Use edition 2021 or newer; commit `Cargo.lock` for binaries, not for libraries.
- Style: no `unwrap`/`expect` outside tests; propagate with `?`; `thiserror` for library errors; small modules, small traits.
- Security: no new `unsafe` without a `// SAFETY:` comment plus a test; run `cargo audit`/`cargo deny` when available; never `panic!` on network input.

### Go

- `gofmt -l` must be clean; run `go vet ./...` and `go test ./...` (plus `-race` for concurrent code) before handing in work.
- Always work inside a module (`go.mod`); use `staticcheck` and `govulncheck ./...` when available.
- Style: wrap errors with `%w`, never ignore `err`; `context.Context` as first arg on I/O; accept small interfaces, return structs; keep packages small (`internal/` for non-public).
- Security: validate inputs, set HTTP timeouts, parameterize SQL, no `unsafe`.

### Make

- Mark non-file targets `.PHONY`; keep recipes parallel-safe (`make -j`).
- Provide a `help` target documenting the available targets.
- Style: one target = one responsibility; delegate lint/test to `make lint` / `make test`; shellcheck recipe lines containing shell.

### CMake

- Always configure out-of-source (`cmake -S . -B build`); prefer presets (`CMakePresets.json`); build with `cmake --build --preset <p>` and test with `ctest --preset <p>`.
- Modern target-based style (`target_link_libraries`, no global `include_directories`); set `-Wall -Wextra -Werror` per target.
- Style: one directory = one target with a clear name; keep toolchain details in presets, not in logic.

### Meson + Ninja

- `meson setup builddir`, then build and test with `ninja -C builddir` / `meson test -C builddir --print-errorlogs`.
- Style: keep `meson_options.txt` typed with sane defaults; one test entry per suite.

### HTML/CSS

- Semantic HTML5 (`header`/`main`/`nav`/`section`, real `button`/`a` elements).
- Format with `prettier --check`; use design tokens and mobile-first responsive CSS; avoid large inline-style blocks.
- Accessibility bar (WCAG 2.2 AA): labels on inputs, alt text, visible focus, contrast >= 4.5:1; escape dynamic data; add `rel="noopener"` to `target="_blank"`.

### Bash — for repo and project scripts

- Start scripts with `#!/bin/bash` and `set -euo pipefail`; quote `"$vars"`; use `$()` and arrays for command args.
- `bash -n` and `shellcheck -S warning` must pass; format with `shfmt` when the project uses it.
- Style: `snake_case` functions with a usage comment; fail with a message on stderr and non-zero exit.

### Dockerfile — when touching images

- Pin the base (`debian:trixie-slim`, never `latest`); set `SHELL ["/bin/bash", "-o", "pipefail", "-c"]`; parameterize versions via `ARG`.
- Never add privilege escalation, the daemon, or `--privileged`; run as non-root; clean apt caches in the same `RUN` layer.
- Style: one concern per layer; verify with `hadolint` when available.

### Git workflow

- Small focused commits with conventional subjects (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`); explain `git push --force` and destructive history rewrites before running them.
- Never commit secrets, lockfile hand-edits outside the package manager, or generated build output.
