# Troubleshooting

Each `pi-dockerized doctor` section, what its failures mean, and the fix.
Host-side repairs first: `pi-dockerized doctor --fix` re-runs `config sync`
(permissions, missing dirs/files) before diagnosing.

| Doctor says | Meaning | Fix |
|---|---|---|
| `self-test: FAILED` | Guard files damaged | `pi-dockerized build` (fail-closed image never runs Pi unguarded) |
| `settings security keys: BROKEN` | Host `settings.json` loosens the sandbox | Remove the named key, or delete the file to re-seed defaults; with Pi Packages, check `ext-agent/settings.json` |
| `settings.json: MISSING` / `mcp.json: MISSING` | Host state incomplete | `pi-dockerized config sync` (or `doctor --fix`) |
| `mcp.json: INVALID JSON` | Typo in MCP servers | `pi-dockerized config pi edit`; secrets must be `${VAR}` refs, values live in `setting.env_file` |
| `skills: WRITABLE` / `baked agent files: WRITABLE` | Mounts wrong (image or wrapper drift) | `pi-dockerized build`, then `version` to compare wrapper vs image |
| `host packages: WRITABLE` | Pi Packages mounted read-write | Reinstall hosting (`extensions` flow mounts them read-only); never use `--untrusted` output as reference here |
| `SSH_AUTH_SOCK is unset or not a socket` | Agent not forwarded | Start `ssh-agent` on the host, enable `setting.ssh_agent_support=true`; the socket must be owned by you (`forwarding_socket_ok`) |
| `agent socket: MISSING` | GnuPG forwarding broken | `gpgconf --launch gpg-agent`, enable `setting.gpg_agent_support=true` |
| `public keyring: MISSING` | No public material mirrored | Check `~/.gnupg` on the host; private keys are never copied by design |
| `env file: not configured` | No provider keys reach the container | Create a `0600` dotenv, point `setting.env_file` at it, re-run `auth` |
| `version check: ENABLED` | `PI_SKIP_VERSION_CHECK` lost | Rebuild; never set it back manually (self-update is blocked by the guard) |
| `audit log: not mounted` | `audit.log` missing on the host | `config sync` recreates it; blocked calls are only recorded with it mounted |
| Image `X days old` warning (wrapper, not doctor) | Base image stale | `pi-dockerized build --fresh` |

Session behavior:

- Pi exits immediately without TUI → no TTY (use a real terminal, or `exec` for
  non-interactive prompts). `exec` returns Pi's exit code.
- `Blocked by ... (pi-policy/...)` → `pi-dockerized audit --explain` names the
  rule, its reason, and the exact allow/session-flag to proceed.
- `tool ... is not allowed in strict mode` → add it to `setting.allowed_tools`
  (`name` or `name:scope+scope`); see `docs/config-reference.md`.
- `stop --all` refuses → pass `--yes` (scripts must opt in).
