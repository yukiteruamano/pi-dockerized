#!/bin/bash

# sections.sh - the install wizard sections (config, completions, aliases, PATH,
# image build). Sourced by lib/install-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# True when NAME is one of the enabled --only sections.
# Uses the global SETUP_ONLY (comma-separated).
wants_section() {
    case ",$SETUP_ONLY," in
    *",$1,"*) return 0 ;;
    esac
    return 1
}

# Ensure this checkout's bin/ is executable and on PATH in both shells,
# and drop the legacy ~/.local/bin symlink (nothing lives there anymore).
# Usage: ensure_global_command
ensure_global_command() {
    local repo_dir target ok=true
    repo_dir="$(install_root 2>/dev/null || true)"
    target="${repo_dir}/bin/pi-dockerized"
    [ -n "$repo_dir" ] || target=""
    if [ -n "$target" ] && [ ! -x "$target" ]; then
        if chmod +x "$target" 2>/dev/null; then
            echo "Made the pi-dockerized binary executable"
        else
            echo "Could not make $target executable"
            ok=false
        fi
    fi
    if [ -L "$HOME/.local/bin/pi-dockerized" ]; then
        rm -f "$HOME/.local/bin/pi-dockerized" 2>/dev/null || true
        echo "Removed legacy symlink ~/.local/bin/pi-dockerized (now via PATH)"
    elif [ -e "$HOME/.local/bin/pi-dockerized" ]; then
        echo "$HOME/.local/bin/pi-dockerized exists and is not a symlink; left untouched (remove it manually)"
    fi
    # Drop the obsolete second binary from canonical installs (bin/ holds only
    # the pi-dockerized binary now).
    if [ -e "$PI_BIN_DIR/install" ]; then
        rm -f "$PI_BIN_DIR/install" 2>/dev/null || true
        echo "Removed obsolete $PI_BIN_DIR/install (use 'pi-dockerized install')"
    fi
    local rc
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        if ensure_path_in_rc "$rc"; then
            echo "Added pi-dockerized/bin to PATH in $rc"
        fi
    done
    if command -v pi-dockerized >/dev/null 2>&1; then
        echo "Command on PATH: $(command -v pi-dockerized)"
    else
        echo "Restart your shell (or source ~/.bashrc) for PATH to take effect"
    fi
    [ "$ok" = true ]
}

_install_bash_completion() {
    local repo_dir="$1"
    local bash_rc="$HOME/.bashrc"
    local completion_line="[ -f \"$repo_dir/completions/bash.sh\" ] && source \"$repo_dir/completions/bash.sh\""
    if grep -qF -- "$completion_line" "$bash_rc" 2>/dev/null; then
        echo "Bash completion already configured in ~/.bashrc"
    else
        {
            echo ""
            echo "# Pi Dockerized completion"
            echo "$completion_line"
        } >>"$bash_rc"
        echo "Added bash completion to ~/.bashrc"
        echo "  Run: source ~/.bashrc"
    fi
}

_install_zsh_completion() {
    local repo_dir="$1"
    local zsh_rc="$HOME/.zshrc"
    local completion_line="[ -f \"$repo_dir/completions/zsh.sh\" ] && source \"$repo_dir/completions/zsh.sh\""
    if grep -qF -- "$completion_line" "$zsh_rc" 2>/dev/null; then
        echo "Zsh completion already configured in ~/.zshrc"
    else
        {
            echo ""
            echo "# Pi Dockerized completion"
            echo "$completion_line"
        } >>"$zsh_rc"
        echo "Added zsh completion to ~/.zshrc"
        echo "  Run: source ~/.zshrc"
    fi
}

_install_bash_aliases() {
    ensure_global_command || true
    local rc=0
    ensure_aliases_in_rc "$HOME/.bashrc" || rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "Could not update aliases in ~/.bashrc"
    elif [ "$rc" -eq 0 ]; then
        echo "Added aliases to ~/.bashrc"
        echo "  Run: source ~/.bashrc"
    else
        echo "Bash aliases already configured in ~/.bashrc"
    fi
}

_install_zsh_aliases() {
    ensure_global_command || true
    local rc=0
    ensure_aliases_in_rc "$HOME/.zshrc" || rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "Could not update aliases in ~/.zshrc"
    elif [ "$rc" -eq 0 ]; then
        echo "Added aliases to ~/.zshrc"
        echo "  Run: source ~/.zshrc"
    else
        echo "Zsh aliases already configured in ~/.zshrc"
    fi
}

# Config section: create the config file or run the interactive setup.
install_section_config() {
    if wants_section config; then
        if [ "$SETUP_YES" = true ]; then
            if config_exists; then
                config_info "Non-interactive defaults: keeping existing config."
            else
                init_config_file
            fi
        else
            interactive_config_setup
        fi
    fi
}

# Shell completions section. Usage: install_section_completions <repo_root>
install_section_completions() {
    local REPO_ROOT="$1"
    if wants_section completions; then
        echo ""
        echo "Shell Completions Setup"
        local bash_completion_line="[ -f \"$REPO_ROOT/completions/bash.sh\" ] && source \"$REPO_ROOT/completions/bash.sh\""
        local zsh_completion_line="[ -f \"$REPO_ROOT/completions/zsh.sh\" ] && source \"$REPO_ROOT/completions/zsh.sh\""
        local bash_completion_installed=false zsh_completion_installed=false
        if [ -f "$HOME/.bashrc" ] && grep -qF -- "$bash_completion_line" "$HOME/.bashrc" 2>/dev/null; then
            bash_completion_installed=true
        fi
        if [ -f "$HOME/.zshrc" ] && grep -qF -- "$zsh_completion_line" "$HOME/.zshrc" 2>/dev/null; then
            zsh_completion_installed=true
        fi
        if [ "$SETUP_YES" = true ]; then
            echo "Non-interactive defaults: installing for shells with existing rc files."
            [ -f "$HOME/.bashrc" ] && _install_bash_completion "$REPO_ROOT"
            [ -f "$HOME/.zshrc" ] && _install_zsh_completion "$REPO_ROOT"
        else
            local install_completions=""
            if [ "$bash_completion_installed" = true ] && [ "$zsh_completion_installed" = true ]; then
                echo "Shell completions already configured (bash + zsh)"
                local reconfigure_completions=""
                read -r -p "Reconfigure completions? (y/N): " reconfigure_completions || reconfigure_completions=""
                [[ "$reconfigure_completions" =~ ^[Yy]$ ]] || install_completions="skip"
            elif [ "$bash_completion_installed" = true ]; then
                echo "Bash completion already configured"
                echo "Would you like to also install zsh completions?"
                local install_zsh_only=""
                read -r -p "Install zsh completions? (y/N): " install_zsh_only || install_zsh_only=""
                if [[ "$install_zsh_only" =~ ^[Yy]$ ]]; then
                    _install_zsh_completion "$REPO_ROOT"
                fi
                install_completions="skip"
            elif [ "$zsh_completion_installed" = true ]; then
                echo "Zsh completion already configured"
                echo "Would you like to also install bash completions?"
                local install_bash_only=""
                read -r -p "Install bash completions? (y/N): " install_bash_only || install_bash_only=""
                if [[ "$install_bash_only" =~ ^[Yy]$ ]]; then
                    _install_bash_completion "$REPO_ROOT"
                fi
                install_completions="skip"
            fi
            if [ "${install_completions:-}" != "skip" ]; then
                echo "Would you like to install shell completions? (enables tab completion for commands)"
                read -r -p "Install completions? (y/n): " install_completions || install_completions=""
                if [[ "$install_completions" =~ ^[Yy]$ ]]; then
                    echo ""
                    echo "Available completions:"
                    echo "  1) bash"
                    echo "  2) zsh"
                    echo "  3) both"
                    echo "  4) skip"
                    local shell_choice=""
                    read -r -p "Select option (1-4): " shell_choice || shell_choice=""
                    case "$shell_choice" in
                    1) _install_bash_completion "$REPO_ROOT" ;;
                    2) _install_zsh_completion "$REPO_ROOT" ;;
                    3)
                        _install_bash_completion "$REPO_ROOT"
                        _install_zsh_completion "$REPO_ROOT"
                        ;;
                    4) echo "Skipping completions installation." ;;
                    *) echo "Invalid choice, skipping completions." ;;
                    esac
                else
                    echo "Skipping completions installation."
                fi
            fi
        fi
    fi
}

# Shell aliases section.
install_section_aliases() {
    if wants_section aliases; then
        echo ""
        echo "Shell Aliases Setup"
        local bash_aliases_installed=false zsh_aliases_installed=false
        if [ -f "$HOME/.bashrc" ] && aliases_configured "$HOME/.bashrc"; then
            bash_aliases_installed=true
        fi
        if [ -f "$HOME/.zshrc" ] && aliases_configured "$HOME/.zshrc"; then
            zsh_aliases_installed=true
        fi
        local setup_aliases="ask"
        if [ "$SETUP_YES" = true ]; then
            echo "Non-interactive defaults: installing for shells with existing rc files."
            [ -f "$HOME/.bashrc" ] && _install_bash_aliases
            [ -f "$HOME/.zshrc" ] && _install_zsh_aliases
        else
            if [ "$bash_aliases_installed" = true ] && [ "$zsh_aliases_installed" = true ]; then
                echo "Shell aliases already configured (bash + zsh)"
                local reconfigure_aliases=""
                read -r -p "Reconfigure aliases? (y/N): " reconfigure_aliases || reconfigure_aliases=""
                [[ "$reconfigure_aliases" =~ ^[Yy]$ ]] || setup_aliases="skip"
            elif [ "$bash_aliases_installed" = true ]; then
                echo "Bash aliases already configured"
                echo "Would you like to also install zsh aliases?"
                local install_zsh_aliases_only=""
                read -r -p "Install zsh aliases? (y/N): " install_zsh_aliases_only || install_zsh_aliases_only=""
                if [[ "$install_zsh_aliases_only" =~ ^[Yy]$ ]]; then
                    _install_zsh_aliases
                fi
                setup_aliases="skip"
            elif [ "$zsh_aliases_installed" = true ]; then
                echo "Zsh aliases already configured"
                echo "Would you like to also install bash aliases?"
                local install_bash_aliases_only=""
                read -r -p "Install bash aliases? (y/N): " install_bash_aliases_only || install_bash_aliases_only=""
                if [[ "$install_bash_aliases_only" =~ ^[Yy]$ ]]; then
                    _install_bash_aliases
                fi
                setup_aliases="skip"
            fi
            if [ "$setup_aliases" != "skip" ]; then
                echo "Would you like to set up convenient aliases for pi-dockerized?"
                echo "This will create short aliases like 'pid' for easier command access."
                read -r -p "Setup aliases? (y/n): " setup_aliases || setup_aliases=""
                if [[ "$setup_aliases" =~ ^[Yy]$ ]]; then
                    echo ""
                    echo "Recommended aliases:"
                    echo "  pid       -> pi-dockerized"
                    echo "  pid-run   -> pi-dockerized run"
                    echo "  pid-auth  -> pi-dockerized auth"
                    echo ""
                    echo "Available shells:"
                    echo "  1) bash"
                    echo "  2) zsh"
                    echo "  3) both"
                    echo "  4) skip"
                    local alias_shell_choice=""
                    read -r -p "Select option (1-4): " alias_shell_choice || alias_shell_choice=""
                    case "$alias_shell_choice" in
                    1) _install_bash_aliases ;;
                    2) _install_zsh_aliases ;;
                    3)
                        _install_bash_aliases
                        _install_zsh_aliases
                        ;;
                    4) echo "Skipping aliases installation." ;;
                    *) echo "Invalid choice, skipping aliases." ;;
                    esac
                else
                    echo "Skipping aliases installation."
                fi
            fi
        fi
    fi
}

# PATH section. Usage: install_section_global <repo_root>
install_section_global() {
    local REPO_ROOT="$1"
    if wants_section global; then
        echo ""
        echo "PATH Installation"
        local path_already_ok=false
        if command -v pi-dockerized >/dev/null 2>&1; then
            path_already_ok=true
        fi
        if [ -L "$HOME/.local/bin/pi-dockerized" ]; then
            rm -f "$HOME/.local/bin/pi-dockerized" 2>/dev/null || true
            echo "Removed legacy symlink ~/.local/bin/pi-dockerized"
        elif [ -e "$HOME/.local/bin/pi-dockerized" ]; then
            echo "$HOME/.local/bin/pi-dockerized exists and is not a symlink; left untouched (remove it manually)"
        fi
        # Obsolete second binary: bin/ holds only pi-dockerized now.
        if [ -e "$PI_BIN_DIR/install" ]; then
            rm -f "$PI_BIN_DIR/install" 2>/dev/null || true
            echo "Removed obsolete $PI_BIN_DIR/install (use 'pi-dockerized install')"
        fi
        if [ "$path_already_ok" = true ]; then
            echo "Already on PATH: $(command -v pi-dockerized)"
            local rc
            for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
                [ -f "$rc" ] || continue
                if ensure_path_in_rc "$rc"; then
                    echo "Added pi-dockerized/bin to PATH in $rc"
                fi
            done
        else
            echo "Put this checkout's bin/ on PATH so 'pi-dockerized' works anywhere."
            echo "No symlink, stub or copy is created in ~/.local/bin."
            local install_global=""
            if [ "$SETUP_YES" = true ]; then
                echo "Non-interactive defaults: adding to PATH."
                install_global="y"
            else
                read -r -p "Add to PATH? (y/n): " install_global || install_global=""
            fi
            if [[ "$install_global" =~ ^[Yy]$ ]]; then
                local bin_target="$REPO_ROOT/bin/pi-dockerized"
                if [ ! -x "$bin_target" ] && ! chmod +x "$bin_target" 2>/dev/null; then
                    echo "Could not make $bin_target executable"
                fi
                local added_to_rc=false rc_file
                for rc_file in "$HOME/.zshrc" "$HOME/.bashrc"; do
                    [ -f "$rc_file" ] || continue
                    if ensure_path_in_rc "$rc_file"; then
                        echo "Added pi-dockerized/bin to PATH in $rc_file"
                        added_to_rc=true
                    fi
                done
                if [ "$added_to_rc" = true ]; then
                    echo "  Restart your shell or run: source ~/.bashrc (or ~/.zshrc)"
                else
                    echo "  Add this to your shell rc file:"
                    echo "    $PI_BIN_PATH_LINE"
                fi
                echo ""
                echo "  You can now run 'pi-dockerized' from any directory:"
                echo "    pi-dockerized run"
                echo "    pi-dockerized build"
                echo "    pi-dockerized auth"
            else
                echo "Skipping PATH installation."
                echo "  You can always run it directly: $REPO_ROOT/bin/pi-dockerized"
            fi
        fi
        if [ "$(readlink -f "$REPO_ROOT")" != "$(readlink -f "$PI_INSTALL_DIR")" ] && [ -d "$PI_INSTALL_DIR/.git" ]; then
            echo "Note: running from $REPO_ROOT (canonical: $PI_INSTALL_DIR)"
        fi
    fi
}

# Docker image section. Usage: install_section_build <repo_root>
install_section_build() {
    local REPO_ROOT="$1"
    if wants_section build; then
        echo ""
        echo "Docker Image"
        if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
            echo "Docker is not running; skipping build (run 'pi-dockerized build' later)"
        else
            local build_answer=""
            if [ "$SETUP_YES" = true ]; then
                build_answer="y"
            else
                read -r -p "Build the Docker image now? (Y/n): " build_answer || build_answer=""
                build_answer="${build_answer:-y}"
            fi
            if [[ "$build_answer" =~ ^[Yy]$ ]]; then
                build_image || echo "Build failed; run 'pi-dockerized build' later"
            else
                echo "Skipping build (run 'pi-dockerized build' later)."
            fi
        fi
    fi
}
