#compdef pi-dockerized
# shellcheck shell=bash disable=SC2034,SC2154,SC1087,SC2016,SC2206,SC2296,SC2128

# Zsh completion for pi-dockerized
# Source this file in your ~/.zshrc or place in /usr/local/share/zsh/site-functions/

# Existing profile names; with "default", the root profile too.
_pi_dockerized_profiles() {
    local -a names
    names=(${(f)"$(ls "${PI_CONFIG_ROOT:-$HOME/.config/pi-dockerized}/profiles" 2>/dev/null)"})
    names=(${names:#default})
    [[ "$1" == default ]] && names=(default $names)
    _describe -t profiles 'profile' names
}

# Session flags (run/shell/exec); run adds --resume/--list, exec takes a
# prompt instead of a directory.
_pi_dockerized_session() {
    local -a specs
    specs=(
        '--untrusted[Strictest setup: strict policy, bridge network, no forwarding or mounts]'
        '--policy[Security policy for this session]:policy:(strict balanced off)'
        '--network[Network for this session]:network:(host bridge)'
        '--timeout[Time limit for the session]:duration:'
        '--dir[Project directory]:directory:_files -/'
    )
    case $1 in
        run)
            specs+=(
                '--resume[Resume a previous session (bare: picker)]::session id:'
                '--list[List previous sessions]'
                '*:directory:_files -/'
            )
            ;;
        shell) specs+=('*:directory:_files -/') ;;
        exec) specs+=('*:prompt:') ;;
    esac
    _arguments $specs
}

_pi_dockerized() {
    local -a commands settings
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
        'profile:Profiles (list|create|remove|show|path|check|fix|run|root)'
        'clean:Remove the Docker image (all tags)'
        'help:Show help message'
    )
    settings=(
        ssh_agent_support gpg_agent_support gpg_allow_main_socket gpg_autostart_agent
        gpg_relay docker_socket git_readonly network security_policy allowed_tools
        verify_updates memory cpus pids_limit env_file theme model default_profile
    )

    _arguments -C \
        '--profile[Use a named profile (own config, keys and state)]:profile name:->profiles' \
        '(- :)'{-h,--help}'[Show help message]' \
        '1: :->cmds' \
        '*:: :->args'

    case $state in
        profiles)
            _pi_dockerized_profiles default
            ;;
        cmds)
            _describe -t commands 'pi-dockerized command' commands
            ;;
        args)
            case $words[1] in
                run|shell|exec)
                    _pi_dockerized_session $words[1]
                    ;;
                mcp)
                    (( CURRENT == 2 )) && compadd list login logout
                    ;;
                extensions|plugin)
                    if (( CURRENT == 2 )); then
                        compadd list install remove update path edit
                    else
                        case $words[2] in
                            install|add|update) compadd -- --allow-scripts ;;
                        esac
                    fi
                    ;;
                audit)
                    compadd -- -n --summary --clear --explain
                    ;;
                ps|stats)
                    compadd -- --json
                    ;;
                doctor|debug)
                    compadd -- --fix
                    ;;
                stop)
                    local -a names
                    names=(${(f)"$(docker ps --filter label=pi-dockerized=1 --format '{{.Names}}' 2>/dev/null)"})
                    compadd -- --all --yes --force $names
                    ;;
                config)
                    if (( CURRENT == 2 )); then
                        local -a config_cmds
                        config_cmds=(
                            'show:Show current configuration (--sources for origins)'
                            'edit:Edit wrapper config file in $EDITOR'
                            'get:Print one setting'
                            'set:Validate and save one setting'
                            'path:Print wrapper config file path'
                            'sync:Repair host-side Pi state (--check for drift only)'
                            'pi:Show or edit the Pi agent config (path|edit)'
                            'allow:Show or edit the host allow rules for the guard'
                            'trust:Show or edit the saved project-trust decisions'
                        )
                        _describe -t config_cmds 'config subcommand' config_cmds
                        return
                    fi
                    case $words[2] in
                        show) compadd -- --sources ;;
                        get)
                            if (( CURRENT == 3 )); then compadd $settings; else compadd -- --source; fi
                            ;;
                        set)
                            if (( CURRENT == 3 )); then
                                compadd $settings
                            elif (( CURRENT == 4 )); then
                                case $words[3] in
                                    ssh_agent_support|gpg_agent_support|gpg_allow_main_socket|gpg_autostart_agent|gpg_relay|docker_socket|git_readonly|verify_updates)
                                        compadd true false ;;
                                    network) compadd host bridge ;;
                                    security_policy) compadd strict balanced off ;;
                                    pids_limit) compadd 4096 unlimited ;;
                                    default_profile) _pi_dockerized_profiles default ;;
                                    env_file) _files ;;
                                esac
                            fi
                            ;;
                        sync) compadd -- --check ;;
                        pi|allow|trust) (( CURRENT == 3 )) && compadd path edit ;;
                    esac
                    ;;
                profile)
                    if (( CURRENT == 2 )); then
                        local -a profile_cmds
                        profile_cmds=(
                            'list:List named profiles (the active one is marked)'
                            'create:Create a profile with its own config and state'
                            'remove:Delete a profile and all its state'
                            'show:Show the settings of a profile (--sources for origins)'
                            'path:Print the directory of a profile'
                            'check:Audit a whole profile (read-only)'
                            'fix:Repair what check reports, then check again'
                            'run:Start a session with a profile'
                            'root:Show or edit the routing config (default_profile, profile.map)'
                        )
                        _describe -t profile_cmds 'profile subcommand' profile_cmds
                        return
                    fi
                    case $words[2] in
                        root)
                            (( CURRENT == 3 )) && compadd path edit
                            ;;
                        remove|rm)
                            if (( CURRENT == 3 )); then _pi_dockerized_profiles; else compadd -- --yes; fi
                            ;;
                        show)
                            compadd -- --sources
                            (( CURRENT == 3 )) && _pi_dockerized_profiles default
                            ;;
                        path|check|fix)
                            (( CURRENT == 3 )) && _pi_dockerized_profiles default
                            ;;
                        run)
                            if (( CURRENT == 3 )); then
                                _pi_dockerized_profiles default
                            else
                                shift 2 words
                                (( CURRENT -= 2 ))
                                _pi_dockerized_session run
                            fi
                            ;;
                    esac
                    ;;
                upgrade|update)
                    case $words[CURRENT-1] in
                        --pi-version) compadd latest ;;
                        *) compadd -- --check --yes --no-build --verify --no-verify --pi-version ;;
                    esac
                    ;;
                build)
                    case $words[CURRENT-1] in
                        --pi-version) compadd latest ;;
                        *) compadd -- --pi-version --bust-cache --fresh ;;
                    esac
                    ;;
                pull)
                    compadd -- --no-verify --allow-downgrade
                    ;;
                install)
                    case $words[CURRENT-1] in
                        --only) _sequence compadd - config completions aliases global path build ;;
                        *) compadd -- --yes --only --help ;;
                    esac
                    ;;
                uninstall)
                    compadd -- --yes --image --purge-config --all-profiles
                    ;;
            esac
            ;;
    esac
}

compdef _pi_dockerized pi-dockerized
compdef _pi_dockerized pid
