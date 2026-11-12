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
| `git_readonly` | bool | `true` | Mount the project's `.git` and `.gitmodules` read-only (Git on the host runs hooks and config from them). Commit, stash and fetch from the host; `--untrusted` forces it on |
| `network` | `host`\|`bridge` | `host` | Container network; `--untrusted` forces `bridge`. `host` also shares abstract Unix sockets (X11, D-Bus) with the host |
| `security_policy` | `strict`\|`balanced`\|`off` | `balanced` | Guard pattern sets; backstops stay active even when `off` |
| `allowed_tools` | list | empty | Strict-mode allowlist: `name`, `name:*`, or `name:scope+scope` (comma-separated) |
| `verify_updates` | bool | `true` | `update`/`upgrade` require an upstream head signed by a key in `.github/release-signers` (import it into your keyring first) |
| `memory` | size | empty | Container memory limit, e.g. `4g` |
| `cpus` | number | empty | Container CPU limit, e.g. `2` |
| `pids_limit` | number\|`unlimited` | `4096` | Container process cap (`docker --pids-limit`); contains fork bombs at the kernel |
| `env_file` | path | empty | Secrets file (dotenv, `0600`) passed as `docker --env-file`, never mounted |
| `theme` | name | empty | Pi theme passed as `--use-theme` |
| `model` | name | empty | Startup model passed as `--model` |
| `default_profile` | name | empty | Profile used when `--profile` is not given. Root config only (`config set` writes it there from any profile; must name an existing profile); `--profile default` escapes back to the default profile |

Each profile, `default` included, has its own INI file at
`~/.config/pi-dockerized/profiles/<name>/config` with its settings and custom
mounts (`mount.<name>=<host>:<container>`); see `examples/config.example` for
an annotated file. Profiles are created explicitly (`profile create NAME` or
`--profile NAME install`; `profile check|fix NAME` audit and repair one): any
other command with an unknown profile is an error, so a typo cannot run a
session on a fresh empty profile. The root `~/.config/pi-dockerized/config`
holds only routing (`profile root edit`): `default_profile` and
`profile.map.<key>=<path>:<profile>` lines that map project directories to
profiles (longest path wins; an explicit `--profile` always takes precedence;
`default` maps back to the default profile). Configs from versions up to 0.16,
which kept the default profile in the root, are migrated automatically.
