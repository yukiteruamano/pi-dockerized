#!/bin/bash

# extensions.sh - the `extensions` command: Pi Packages, installed with the
# official `pi install` and kept on the host.
# Sourced by bin/pi-dockerized (not executable directly).
# shellcheck disable=SC2034 # DOCKER_CMD/NETWORK are consumed by the other sourced modules
# NOTE: no "set -e" — library file; callers control their own error handling.
#
# `pi install|remove|update|list` run in a throwaway container whose agent
# directory is EXT_AGENT_DIR on the host (read-write): Pi writes its
# settings.json there and installs into npm/ and git/. Sessions mount those
# three read-only over the agent's own, so packages survive image rebuilds and
# the agent can never change the code it loads. The security guard is not a
# package: it stays baked into the image.
#
# The installer container has network (bridge) but no secrets file, no project,
# no session state and no custom mounts; npm install scripts are skipped unless
# --allow-scripts. container/ext-install.sh seeds the settings from the baked
# defaults and reapplies their security keys after every Pi command.

# What `pi install` takes, minus local paths (the installer cannot see your
# disk) and anything that could be read as an option. Usage: validate_ext_source <src>
validate_ext_source() {
    local src="$1"
    if [[ "$src" =~ ^(npm:|git:|https://)[A-Za-z0-9@][A-Za-z0-9@/_.:+#~=%?\&^-]*$ ]]; then
        return 0
    fi
    print_error "Unsupported package source '$src'."
    print_info "Use a Pi Package source as 'pi install' takes it: npm:<name>[@version], git:<host>/<owner>/<repo>[@ref] or an https:// git URL."
    return 1
}

# Run the baked ext-install.sh with the official `pi` arguments.
# Usage: run_ext_install <allow_scripts:true|false> <pi args...>
run_ext_install() {
    local allow_scripts="$1"
    shift
    check_image "$IMAGE_NAME" || exit "$E_DOCKER"
    ensure_pi_dirs
    parse_config

    # The installer needs the internet, not the host network, and must not see
    # provider keys: packages and their scripts are third-party code.
    NETWORK=bridge
    build_common_docker_args

    local -a tty_args=(-i) script_env=()
    if [ -t 0 ] && [ -t 1 ]; then tty_args=(-it); fi
    # npm reads this variable, so Pi's own npm calls skip install scripts.
    if [ "$allow_scripts" != true ]; then script_env=(-e "npm_config_ignore_scripts=true"); fi

    SESSION_CONTAINER="pi-extensions-$$"
    DOCKER_CMD=(
        docker run "${tty_args[@]}" --name "$SESSION_CONTAINER"
        --workdir "$PI_EXT_AGENT_CONTAINER_DIR"
        "${DOCKER_COMMON_ARGS[@]}"
        -e "PI_CODING_AGENT_DIR=$PI_EXT_AGENT_CONTAINER_DIR"
        "${script_env[@]}"
        -v "$EXT_AGENT_DIR:$PI_EXT_AGENT_CONTAINER_DIR:rw"
        -v "$PI_HOME/.npm:/home/coder/.npm:rw"
        "$IMAGE_NAME" /usr/local/lib/pi-dockerized/ext-install.sh "$@"
    )
    launch_session
}

_extensions_usage() {
    echo "Usage: $0 extensions <command>" >&2
    echo "  list                                what 'pi list' reports for the host packages" >&2
    echo "  install SRC [--allow-scripts]       SRC: npm:<name>[@ver] | git:<host>/<owner>/<repo>[@ref]" >&2
    echo "  remove SRC                          uninstall a package (same SRC syntax)" >&2
    echo "  update [SRC] [--allow-scripts]      update one package, or all of them" >&2
    echo "  path                                print the host directory" >&2
    echo "  edit                                edit its settings.json by hand" >&2
}

# Manage the host's Pi Packages. Changes apply to the next session started.
# Usage: manage_extensions [list|install|remove|update|path|edit] ...
manage_extensions() {
    local subcommand="${1:-list}"
    shift || true

    local allow_scripts=false arg
    local -a positional=()
    for arg in "$@"; do
        if [ "$arg" = "--allow-scripts" ]; then allow_scripts=true; else positional+=("$arg"); fi
    done

    local rc=0
    case "$subcommand" in
    list)
        [ "${#positional[@]}" -eq 0 ] || {
            _extensions_usage
            exit 1
        }
        run_ext_install false list
        ;;
    install | add)
        [ "${#positional[@]}" -eq 1 ] || {
            _extensions_usage
            exit 1
        }
        validate_ext_source "${positional[0]}" || exit 1
        run_ext_install "$allow_scripts" install "${positional[0]}" || rc=$?
        [ "$rc" -eq 0 ] && print_info "Restart running sessions to load the change."
        return "$rc"
        ;;
    remove | rm | uninstall)
        [ "${#positional[@]}" -eq 1 ] && [ "$allow_scripts" = false ] || {
            _extensions_usage
            exit 1
        }
        validate_ext_source "${positional[0]}" || exit 1
        run_ext_install false remove "${positional[0]}" || rc=$?
        [ "$rc" -eq 0 ] && print_info "Restart running sessions to unload it."
        return "$rc"
        ;;
    update)
        if [ "${#positional[@]}" -eq 0 ]; then
            run_ext_install "$allow_scripts" update --extensions || rc=$?
        elif [ "${#positional[@]}" -eq 1 ]; then
            validate_ext_source "${positional[0]}" || exit 1
            run_ext_install "$allow_scripts" update "${positional[0]}" || rc=$?
        else
            _extensions_usage
            exit 1
        fi
        [ "$rc" -eq 0 ] && print_info "Restart running sessions to load the change."
        return "$rc"
        ;;
    path)
        echo "$EXT_AGENT_DIR"
        ;;
    edit)
        if [ ! -f "$EXT_AGENT_DIR/settings.json" ]; then
            print_error "Nothing installed yet: '$0 extensions install <source>' creates $EXT_AGENT_DIR/settings.json."
            exit 1
        fi
        edit_file "$EXT_AGENT_DIR/settings.json"
        print_info "Sessions refuse to start if its security keys (defaultProjectTrust, sessionDir, ...) change."
        ;;
    *)
        print_error "Unknown extensions command: $subcommand"
        _extensions_usage
        exit 1
        ;;
    esac
}
