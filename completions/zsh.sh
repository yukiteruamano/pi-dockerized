#compdef pi-dockerized
# shellcheck shell=bash disable=SC2034,SC2154,SC1087,SC2016

# Zsh completion for pi-dockerized
# Source this file in your ~/.zshrc or place in /usr/local/share/zsh/site-functions/

_pi_dockerized() {
    local -a commands
    commands=(
        'run:Run Pi in Docker (default: current directory)'
        'auth:Check provider credentials (from setting.env_file)'
        'models:List models available to the configured providers'
        'exec:Run a non-interactive prompt (pi --print)'
        'mcp:Manage MCP servers (list|login|logout)'
        'extensions:List installed extensions (install is build-time only)'
        'stats:Show session usage statistics (best-effort)'
        'doctor:Diagnose guard, config, credentials, SSH/GPG forwarding'
        'install:First-time install / repair PATH, config, completions, aliases'
        'upgrade:Full upgrade from GitHub (git pull + sync + image rebuild)'
        'build:Build the Docker image'
        'update:Full upgrade from GitHub (git pull + sync + image rebuild)'
        'version:Show Pi version in the container'
        'config:Show, edit, or print config file path'
        'clean:Remove the Docker image'
        'help:Show help message'
    )

    _arguments -C \
        '1: :->cmds' \
        '*:: :->args'

    case $state in
        cmds)
            _describe -t commands 'pi-dockerized command' commands
            ;;
        args)
            case $words[1] in
                run|models)
                    _files -/
                    ;;
                mcp)
                    _values 'mcp subcommand' list login logout
                    ;;
                extensions|plugin)
                    _values 'extensions subcommand' list
                    ;;
                config)
                    local -a config_cmds
                    config_cmds=(
                        'show:Show current configuration'
                        'edit:Edit wrapper config file in $EDITOR'
                        'path:Print wrapper config file path'
                        'sync:Repair host-side Pi state (--check for drift only)'
                        'pi:Show or edit the Pi agent config (path|edit)'
                    )
                    _describe -t config_cmds 'config subcommand' config_cmds
                    ;;
                upgrade|update)
                    _values 'self-update flag' --check --yes --no-build --pi-version
                    ;;
                install)
                    _values 'install flag' --yes --only
                    ;;
            esac
            ;;
    esac
}

compdef _pi_dockerized pi-dockerized
compdef _pi_dockerized pid
