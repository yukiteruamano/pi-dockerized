#!/bin/bash

# help.sh - the `help` text.
# Sourced by bin/pi-dockerized (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# Function to show help
show_help() {
    cat <<EOF
Pi Docker Wrapper

Usage: $0 [--profile NAME] [COMMAND] [OPTIONS]

Commands:
    run [FLAGS] [DIR]   Run Pi in Docker (default: current directory)
    exec [FLAGS] MSG    Run a non-interactive prompt (pi --print); MSG may come from stdin
    shell [FLAGS] [DIR] Open a shell inside the sandbox (same mounts and limits as run)
    auth                Check provider credentials (from setting.env_file)
    models [DIR]        List models available to the configured providers
    mcp [ARGS]          Manage MCP servers (list|login|logout; add/remove are host-only)
    extensions CMD      Pi Packages via the official pi install: list|install|remove|update|path|edit
    stats               Show session usage statistics (best-effort)
    doctor              Diagnose guard, config, credentials, SSH/GPG forwarding
    audit [-n N|--summary|--clear]  Review the tool calls the guard blocked
    ps                  List running sessions
    stop NAME|--all     Stop running sessions
    install [OPTS]      First-time install / repair PATH, config, completions, aliases
    uninstall [OPTS]    Remove the shell integration (--image, --purge-config)
    upgrade [--check|--yes|--no-build|--verify|--pi-version X]  Full upgrade: git pull + sync + image rebuild
    update  [--check|--yes|--no-build|--verify|--pi-version X]  Same, without the confirmation prompt
    build               Build the Docker image (smoke-tested before it replaces the current one)
    pull [TAG] [--no-verify]  Fetch the prebuilt, signed image instead of building
    rollback            Go back to the image the last build/pull replaced
    version             Show wrapper, image, guard, policy-set and Pi versions
    config [show|edit|get|set|path|sync|profiles]  Wrapper config (INI)
    config pi [path|edit]             Pi agent config (mcp.json)
    config allow [path|edit]          Host allow rules for the guard (allow.json)
    clean               Remove the Docker image (all tags)
    help                Show this help message

Session flags (run, shell, exec):
    --untrusted         Strictest setup for code you do not trust: strict policy,
                        bridge network, no SSH/GPG forwarding, no Docker socket,
                        no custom mounts
    --policy P          strict | balanced | off, for this session only
    --network N         host | bridge, for this session only
    --dir DIR           Project directory (exec, shell)

Environment Variables:
    DRY_RUN=true        Print the Docker command without executing it
    PI_DOCKERIZED_PROFILE=NAME   Same as --profile NAME

Examples:
    $0 run                          # Run in current directory
    $0 run /path/to/project         # Run in specific directory
    $0 run --untrusted ~/src/repo   # Run with the strictest setup
    $0 --profile work run           # Use the "work" profile (own config, keys, state)
    $0 auth                         # Check provider credentials
    $0 exec "Explain this repo"     # Non-interactive prompt
    git diff | $0 exec -            # Prompt read from stdin
    $0 mcp list                     # Show MCP servers and their status
    $0 doctor                       # Diagnose the setup
    $0 audit --summary              # What did the guard block?
    $0 config set network bridge    # Change one setting
    $0 build                        # Build the Docker image
    $0 rollback                     # Undo the last build/update
    $0 update                       # Full upgrade: git pull + sync + rebuild
    DRY_RUN=true $0 run             # Show Docker command without running

Getting Started:
    1. ./install.sh                   # One-liner install (curl|bash): PATH + config
    2. $0 build                       # Build the Docker image (or '$0 pull')
    3. $0 auth                        # Check provider credentials
    4. $0 run /path/to/project        # Run Pi

Security Features:
    - Isolated environment: only access to mounted project directory
    - Settings and the security guard baked read-only into the image; Pi Packages
      (extensions) live on the host (kept across rebuilds), mounted read-only
    - MCP servers (mcp.json) and the security guard are enforced read-only
    - Persistent state: Pi skills, sessions, auth and MCP OAuth live on the
      host under ~/.config/pi-dockerized/home/ and survive rebuilds
    - Non-root user: runs as the host UID/GID with all capabilities dropped
    - Automatic cleanup: containers are removed on exit (--rm)

Note: The host Docker socket is NOT mounted by default. It is opt-in because it
grants the container full control of the host Docker daemon (root-equivalent
on the host) and defeats the sandbox. Enable it with setting.docker_socket=true
in the config only when you need Docker-in-Docker / Testcontainers.

Security policy: setting.security_policy (strict | balanced | off) controls the
pattern sets enforced by the baked security-guard extension. The default
balanced drops patterns meant for shared cloud sandboxes and other common
false positives while keeping the dangerous ones.

Pi's self-update is disabled inside the container (PI_SKIP_VERSION_CHECK=1).

For more information, see README.md
EOF
}
