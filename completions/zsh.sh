#compdef pi-dockerized
# shellcheck shell=bash disable=SC2034,SC2154,SC1087,SC2016,SC2206,SC2296,SC2128

# Zsh completion for pi-dockerized
# Source this file in your ~/.zshrc or place in /usr/local/share/zsh/site-functions/

_pi_dockerized() {
    local -a commands session_flags settings
    commands=(
        'run:Run Pi in Docker (default: current directory)'
        'exec:Run a non-interactive prompt (pi --print)'
        'shell:Open a shell inside the sandbox'
        'auth:Check provider credentials (from setting.env_file)'
        'models:List models available to the configured providers'
        'mcp:Manage MCP servers (list|login|logout)'
        'extensions:Host-managed extensions (list|install|remove|update|path|edit)'
        'stats:Show session usage statistics (best-effort)'
        'doctor:Diagnose guard, config, credentials, SSH/GPG forwarding'
        'audit:Review the tool calls the guard blocked'
        'ps:List running sessions'
        'stop:Stop running sessions'
        'install:First-time install / repair PATH, config, completions, aliases'
        'uninstall:Remove the shell integration'
        'upgrade:Full upgrade from GitHub (git pull + sync + image rebuild)'
        'update:Full upgrade from GitHub without the prompt'
        'build:Build the Docker image (smoke-tested before it is promoted)'
        'pull:Fetch the prebuilt, signed image'
        'rollback:Go back to the image the last build/pull replaced'
        'version:Show wrapper, image, guard, policy-set and Pi versions'
        'config:Show, edit, get/set settings, print config file path'
        'clean:Remove the Docker image (all tags)'
        'help:Show help message'
    )
    session_flags=(--untrusted --policy --network --timeout --resume --list --dir)
    settings=(
        ssh_agent_support gpg_agent_support gpg_allow_main_socket gpg_autostart_agent
        gpg_relay docker_socket network security_policy allowed_tools verify_updates
        memory cpus env_file theme model
    )

    _arguments -C \
        '--profile[Use a named profile (own config, keys and state)]:profile name:' \
        '1: :->cmds' \
        '*:: :->args'

    case $state in
        cmds)
            _describe -t commands 'pi-dockerized command' commands
            ;;
        args)
            case $words[1] in
                run|shell|exec|models)
                    _arguments \
                        '--untrusted[Strictest setup: strict policy, bridge network, no forwarding or mounts]' \
                        '--policy[Security policy for this session]:policy:(strict balanced off)' \
                        '--network[Network for this session]:network:(host bridge)'
                        '--timeout[Time limit for the session]:duration:' \
                        '--dir[Project directory]:directory:_files -/' \
                        '*:directory:_files -/'
                    ;;
                mcp)
                    _values 'mcp subcommand' list login logout
                    ;;
                extensions|plugin)
                    _values 'extensions subcommand' list install remove update path edit
                    ;;
                audit)
                    _values 'audit option' -n --summary --clear --explain
                    ;;
                ps|stats)
                    _values 'output format' --json
                    ;;
                doctor)
                    _values 'doctor flag' --fix
                    ;;
                stop)
                    local -a names
                    names=(${(f)"$(docker ps --filter label=pi-dockerized=1 --format '{{.Names}}' 2>/dev/null)"})
                    _values 'session' --all --yes --force $names
                    ;;
                config)
                    case $words[2] in
                        get|set)
                            _values 'setting' $settings
                            ;;
                        pi|allow)
                            _values 'action' path edit
                            ;;
                        sync)
                            _values 'flag' --check
                            ;;
                        *)
                            local -a config_cmds
                            config_cmds=(
                                'show:Show current configuration'
                                'edit:Edit wrapper config file in $EDITOR'
                                'get:Print one setting'
                                'set:Validate and save one setting'
                                'path:Print wrapper config file path'
                                'sync:Repair host-side Pi state (--check for drift only)'
                                'pi:Show or edit the Pi agent config (path|edit)'
                                'allow:Show or edit the host allow rules for the guard'
                                'profiles:List the named profiles'
                            )
                            _describe -t config_cmds 'config subcommand' config_cmds
                            ;;
                    esac
                    ;;
                upgrade|update)
                    _values 'self-update flag' --check --yes --no-build --verify --pi-version
                    ;;
                build)
                    _values 'build flag' --pi-version --bust-cache --fresh
                    ;;
                pull)
                    _values 'pull flag' --no-verify
                    ;;
                install)
                    _values 'install flag' --yes --only
                    ;;
                uninstall)
                    _values 'uninstall flag' --yes --image --purge-config
                    ;;
            esac
            ;;
    esac
}

compdef _pi_dockerized pi-dockerized
compdef _pi_dockerized pid
