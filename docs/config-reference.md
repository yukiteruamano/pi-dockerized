# Config reference

Every `setting.*` key, its type, default and effect. The single source of truth
is `_setting_spec` in `lib/config/settings.sh` (a test fails when this table
misses a key in `SETTING_KEYS`). Edit with `pi-dockerized config edit`, one key
with `pi-dockerized config set <key> <value>`, inspect with
`pi-dockerized config show` / `config get <key> [--source]`.

| Setting | Type | Default | Effect |
|---|---|---|---|
| `ssh_agent_support` | bool | `false` | Forward `SSH_AUTH_SOCK` into sessions (keys stay on the host; only `config`/`known_hosts` mount read-only) |
| `gpg_agent_support` | bool | `false` | Forward the host GnuPG agent (public keyring mirrored; private keys never leave the host) |
| `gpg_allow_main_socket` | bool | `false` | Allow the full-control main agent socket when the restricted extra socket is missing |
| `gpg_autostart_agent` | bool | `true` | Launch the host `gpg-agent` when its socket is missing |
| `gpg_relay` | bool | `true` | Relay sockets from `/run/*` tmpfs through a normal-filesystem socket Docker can bind |
| `docker_socket` | bool | `false` | Mount `/var/run/docker.sock` (root-equivalent on the host; rebuild the image after enabling) |
| `network` | `host`\|`bridge` | `host` | Container network; `--untrusted` forces `bridge` |
| `security_policy` | `strict`\|`balanced`\|`off` | `balanced` | Guard pattern sets; backstops stay active even when `off` |
| `allowed_tools` | list | empty | Strict-mode allowlist: `name`, `name:*`, or `name:scope+scope` (comma-separated) |
| `verify_updates` | bool | `false` | `update`/`upgrade` require a signed upstream head |
| `memory` | size | empty | Container memory limit, e.g. `4g` |
| `cpus` | number | empty | Container CPU limit, e.g. `2` |
| `env_file` | path | empty | Secrets file (dotenv, `0600`) passed as `docker --env-file`, never mounted |
| `theme` | name | empty | Pi theme passed as `--use-theme` |
| `model` | name | empty | Startup model passed as `--model` |

Custom mounts (`mount.<name>=<host>:<container>`) and profiles (`--profile NAME`,
own config/keys/sessions under `~/.config/pi-dockerized/profiles/`) live in the
same INI file; see `examples/config.example` for an annotated file.
