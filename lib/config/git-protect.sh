#!/bin/bash

# git-protect.sh - what of the project's Git metadata a session can see and
# write: the read-only mounts of .git (nested repositories, gitfile and symlink
# targets included), git worktree support, and the post-session check of Git
# metadata that stayed writable. Git is never run on the project here: hooks
# and core.fsmonitor in it would run on the host.
# Sourced by lib/config-lib.sh (not executable directly).
# NOTE: no "set -e" — library file; callers control their own error handling.

# ============================================
# GIT WORKTREE SUPPORT
# ============================================

# Detect if a directory is a linked git worktree and print the main repo's .git
# directory (the common dir), or nothing. A worktree has a .git FILE containing
# "gitdir: <main>/.git/worktrees/<name>". The project is untrusted content, so
# the pointer is parsed here (git itself is never run on it) and only accepted
# when it has the shape git creates: <common>/worktrees/<name>, whose own
# `gitdir` file points back at this project's .git file. A planted pointer
# (e.g. a `commondir` aimed at another private repo) is ignored.
# Usage: main_git_dir=$(detect_git_worktree "/path/to/worktree")
detect_git_worktree() {
    local project_dir="$1" line gitdir back common project_real

    [ -f "$project_dir/.git" ] && [ ! -L "$project_dir/.git" ] || return 0
    IFS= read -r line 2>/dev/null <"$project_dir/.git" || return 0
    [[ "$line" == "gitdir: "* ]] || return 0
    gitdir="${line#gitdir: }"
    [[ "$gitdir" == /* ]] || gitdir="$project_dir/$gitdir"
    gitdir=$(canonical_path "$gitdir")

    [ "$(basename "$(dirname "$gitdir")")" = worktrees ] || return 0
    common=$(dirname "$(dirname "$gitdir")")

    # A real worktree's common dir lives outside the worktree. One inside the
    # project was planted by the session, which could swap it for a symlink
    # between this check and `docker run` (the daemon follows it).
    project_real=$(canonical_path "$project_dir")
    path_within "$common" "$project_real" && return 0

    # The back-pointer git writes for every linked worktree. Regular files
    # only: a FIFO would hang the wrapper.
    [ -f "$gitdir/gitdir" ] && [ ! -L "$gitdir/gitdir" ] || return 0
    IFS= read -r back 2>/dev/null <"$gitdir/gitdir" || return 0
    [ "$(canonical_path "$back")" = "$(canonical_path "$project_dir/.git")" ] || return 0

    # Sanity check: the common dir must be a real .git directory.
    if [ ! -d "$common/objects" ] || [ ! -d "$common/refs" ]; then
        return 0
    fi

    printf '%s' "$common"
}

# Build Docker volume/bind args needed for git worktree support.
# When the project is a git worktree, the .git file points to the main repo's
# .git directory which lives outside the project dir. We mount the main .git
# directory (read-only) at its real host path so the gitdir pointer resolves
# correctly inside the container. The common dir passes the same source and
# target checks as any other mount, and --untrusted sessions never get it.
#
# Read-only is intentional: it preserves the sandbox boundary (container only
# has write access to the mounted project directory). Read operations like
# git log, status, diff, and branch work. Write operations (commit, stash,
# fetch) will fail — run those on the host.
#
# Populates GIT_WORKTREE_ARGS array
# Usage: build_git_worktree_args "/path/to/project"
build_git_worktree_args() {
    local project_dir="$1"

    GIT_WORKTREE_ARGS=()
    [ "$SESSION_UNTRUSTED" != true ] || return 0

    local git_common_dir
    git_common_dir=$(detect_git_worktree "$project_dir")

    if [ -z "$git_common_dir" ]; then
        return 0
    fi
    if ! validate_mount_source "$git_common_dir" "git worktree" ||
        ! validate_container_path "$git_common_dir" "the git worktree"; then
        config_warning "Not mounting the main .git directory; git will be unavailable in the container"
        return 0
    fi

    config_info "Git worktree detected — mounting main .git directory (read-only) for git support"
    config_info "Main git directory: $git_common_dir"

    # Mount the main repo's .git directory at its real host path (read-only)
    GIT_WORKTREE_ARGS+=(-v "$git_common_dir:$git_common_dir:ro")
}

# ============================================
# READ-ONLY GIT METADATA
# ============================================

# How deep below the project nested repositories are looked for, and how many
# read-only git mounts a session gets at most (setting.git_hardening).
GIT_SCAN_DEPTH=4
GIT_MOUNT_MAX=32

# Print, NUL-separated, every .git and .gitmodules in the project up to
# GIT_SCAN_DEPTH (the project's own included), never descending into a .git or
# node_modules and never following symlinks.
# Usage: find_git_entries <project_dir>
find_git_entries() {
    find "$1" -maxdepth "$GIT_SCAN_DEPTH" \
        -name node_modules -prune -o \
        -name .git -prune -print0 -o \
        -name .gitmodules -print0 2>/dev/null
}

# Print the in-project paths to mount read-only for one git entry: the entry
# itself when it is a regular directory or file, plus the directory a gitfile
# (`gitdir: <dir>`) names, and the canonical target of a symlinked entry, each
# only when it lies inside the project (anything outside is not in the
# container at all; a worktree's common dir is build_git_worktree_args's).
# Usage: git_ro_sources <project_real> <entry>
git_ro_sources() {
    local project_real="$1" entry="$2" line target
    if [ -L "$entry" ]; then
        target=$(canonical_path "$entry")
        [ -e "$target" ] && path_within "$target" "$project_real" && printf '%s\n' "$target"
        return 0
    fi
    [ -d "$entry" ] && { printf '%s\n' "$entry"; return 0; }
    [ -f "$entry" ] || return 0
    printf '%s\n' "$entry"
    [ "$(basename "$entry")" = .git ] || return 0
    IFS= read -r line 2>/dev/null <"$entry" || true
    [[ "$line" == "gitdir: "* ]] || return 0
    target="${line#gitdir: }"
    [[ "$target" == /* ]] || target="$(dirname "$entry")/$target"
    target=$(canonical_path "$target")
    [ -d "$target" ] && path_within "$target" "$project_real" && printf '%s\n' "$target"
    return 0
}

# Mount the project's .git (directory or gitfile) and .gitmodules read-only
# over the project mount (setting.git_readonly, default on). Git on the host
# executes hooks, config and submodule settings from them, so a writable .git
# is a sandbox escape that no pattern match can fully close; a read-only bind
# also makes hard links into it fail (EXDEV). Symlinks are never bound as such:
# Docker would follow them to wherever they point.
# With setting.git_hardening (default on) the same holds for nested
# repositories and for in-project gitfile/symlink targets, up to GIT_MOUNT_MAX
# mounts; the rest are left to the guard and the post-session check.
# Appends to VOLUME_ARGS; sets GIT_RO_MOUNTS / GIT_RO_SKIPPED for the session
# summary. Usage: build_git_readonly_args <project_dir> <container_dir>
GIT_RO_MOUNTS=0
GIT_RO_SKIPPED=0
build_git_readonly_args() {
    local project_dir="$1" container_dir="$2" entry
    GIT_RO_MOUNTS=0
    GIT_RO_SKIPPED=0
    [ "${GIT_READONLY:-true}" = true ] || return 0
    if [ "${GIT_HARDENING:-true}" != true ]; then
        for entry in .git .gitmodules; do
            [ -e "$project_dir/$entry" ] && [ ! -L "$project_dir/$entry" ] || continue
            VOLUME_ARGS+=(--mount "type=bind,source=$project_dir/$entry,target=$container_dir/$entry,readonly")
            GIT_RO_MOUNTS=$((GIT_RO_MOUNTS + 1))
        done
        return 0
    fi

    local project_real source rel mounted skipped=0
    local -a rels=() sorted=() done_rels=()
    project_real=$(canonical_path "$project_dir")
    while IFS= read -r -d '' entry; do
        while IFS= read -r source; do
            # Lexical paths under project_dir (from find) or canonical ones
            # under project_real (resolved targets).
            if path_within "$source" "$project_real"; then
                rel="${source#"$project_real"}"
            else
                rel="${source#"$project_dir"}"
            fi
            rel="${rel#/}"
            [ -n "$rel" ] && rels+=("$rel")
        done < <(git_ro_sources "$project_real" "$entry")
    done < <(find_git_entries "$project_dir")
    [ "${#rels[@]}" -gt 0 ] || return 0
    # Sorted, a directory comes before what it contains (`.git` before
    # `.git/modules/x`), so covered paths are not mounted twice.
    mapfile -t -d '' sorted < <(printf '%s\0' "${rels[@]}" | LC_ALL=C sort -z -u)

    for rel in "${sorted[@]}"; do
        for mounted in "${done_rels[@]}"; do
            path_within "$rel" "$mounted" && continue 2
        done
        if [ "${#done_rels[@]}" -ge "$GIT_MOUNT_MAX" ] || ! _git_ro_mount "$project_dir/$rel" "$container_dir/$rel"; then
            skipped=$((skipped + 1))
            continue
        fi
        done_rels+=("$rel")
    done
    GIT_RO_MOUNTS=${#done_rels[@]}
    GIT_RO_SKIPPED=$skipped
    if [ "$skipped" -gt 0 ]; then
        config_warning "Git metadata: $skipped entries could not be mounted read-only (limit $GIT_MOUNT_MAX, or a name with both ',' and ':'); they stay writable in the container, guarded by pattern and reported when the session ends"
    fi
}

# Append one read-only bind to VOLUME_ARGS. Names come from the project
# (untrusted): a ',' would add fields to `--mount` and a ':' would split a
# `-v` spec, so `-v` is used for the former and a name with both is refused.
# Usage: _git_ro_mount <source> <target>
_git_ro_mount() {
    case "$1$2" in
    *,*:* | *:*,*) return 1 ;;
    *,*) VOLUME_ARGS+=(-v "$1:$2:ro") ;;
    *) VOLUME_ARGS+=(--mount "type=bind,source=$1,target=$2,readonly") ;;
    esac
}

# ============================================
# POST-SESSION CHECK
# ============================================

# Git metadata a session could still write (nested repositories past the
# limits, a project without .git at start, setting.git_readonly=false) is
# checked when the session ends: whatever changed under a git dir and can make
# the host's git run code is reported. Changes are found by ctime against a
# marker taken before `docker run`: a session can backdate an mtime with
# `touch -d`, never a ctime. Static only; nothing is modified.
GIT_WATCH_MARK=""
GIT_WATCH_PROJECT=""

# Config keys and sections that make git run a program.
GIT_RISKY_CONFIG_RE='^[[:space:]]*(\[include(if)?|(hookspath|fsmonitor|sshcommand|askpass|pager|editor|helper|program|external|clean|smudge|process|templatedir)[[:space:]]*=)'

# Start watching the project's git metadata (setting.git_hardening).
# Usage: git_watch_start <project_dir|"">
git_watch_start() {
    git_watch_stop
    [ "${GIT_HARDENING:-true}" = true ] && [ -n "$1" ] || return 0
    GIT_WATCH_MARK=$(mktemp "${TMPDIR:-/tmp}/pi-git-watch.XXXXXX" 2>/dev/null) || GIT_WATCH_MARK=""
    [ -n "$GIT_WATCH_MARK" ] && GIT_WATCH_PROJECT="$1"
}

# Remove the marker (run by the session cleanup).
git_watch_stop() {
    [ -n "$GIT_WATCH_MARK" ] && rm -f "$GIT_WATCH_MARK"
    GIT_WATCH_MARK=""
    GIT_WATCH_PROJECT=""
}

# Comma-separated risky key names a git config file sets (names only: values
# are session-written and never printed). Regular files only.
# Usage: git_config_risky_keys <file>
git_config_risky_keys() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 0
    LC_ALL=C grep -Eio "$GIT_RISKY_CONFIG_RE" "$1" 2>/dev/null |
        tr -d ' \t=[' | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u | paste -s -d, -
}

# Why one changed path matters to the host's git, or nothing.
# Usage: _git_watch_reason <path>
_git_watch_reason() {
    local path="$1" keys
    case "$path" in
    */hooks/*.sample) return 0 ;;
    */hooks/*)
        if [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ]; then
            echo "executable hook written"
        else
            echo "hook written"
        fi
        ;;
    */config | */config.worktree)
        keys=$(git_config_risky_keys "$path")
        [ -z "$keys" ] || echo "config sets $keys"
        ;;
    */commondir) echo "commondir written (points git at another directory)" ;;
    */.gitmodules) echo ".gitmodules written" ;;
    */.git)
        if [ -L "$path" ]; then echo "symlinked .git created"; else echo "gitfile written"; fi
        ;;
    esac
}

# Report the git metadata changed since git_watch_start, then stop watching.
# Never fails the session.
# Usage: git_watch_report
git_watch_report() {
    [ -n "$GIT_WATCH_MARK" ] && [ -f "$GIT_WATCH_MARK" ] || return 0
    local project="$GIT_WATCH_PROJECT" path reason header=false
    while IFS= read -r -d '' path; do
        reason=$(_git_watch_reason "$path")
        [ -n "$reason" ] || continue
        if [ "$header" = false ]; then
            print_warning "Git metadata changed during the session; review it before running git there on the host:"
            header=true
        fi
        print_warning "  ${path#"$project"/}: $reason"
    done < <(find "$project" -maxdepth $((GIT_SCAN_DEPTH + 4)) \
        \( -name node_modules -o -path '*/.git/objects' -o -path '*/.git/modules/*/objects' \
        -o -path '*/.git/lfs' -o -path '*/.git/logs' \) -prune -o \
        -cnewer "$GIT_WATCH_MARK" \
        \( -path '*/.git/hooks/*' -o -path '*/.git/modules/*/hooks/*' \
        -o -path '*/.git/config' -o -path '*/.git/config.worktree' -o -path '*/.git/commondir' \
        -o -path '*/.git/modules/*/config' -o \( -name .git ! -type d \) -o -name .gitmodules \) \
        -print0 2>/dev/null)
    git_watch_stop
}

# ============================================
# SESSION SUMMARY
# ============================================

# How this session protects git metadata, for the startup summary. Reads the
# state left by build_git_readonly_args / build_git_worktree_args; the
# post-session check runs with git_hardening (see git_watch_start).
# Usage: git_protection_summary <project_dir>
git_protection_summary() {
    local repo=no summary
    [ -e "$1/.git" ] && repo=yes
    summary="repo=$repo read-only=$(_onoff "${GIT_READONLY:-true}") hardening=$(_onoff "${GIT_HARDENING:-true}")"
    if [ "${GIT_READONLY:-true}" = true ]; then
        summary="$summary ro-mounts=$GIT_RO_MOUNTS"
        [ "$GIT_RO_SKIPPED" -gt 0 ] && summary="$summary writable=$GIT_RO_SKIPPED"
    fi
    [ "${#GIT_WORKTREE_ARGS[@]}" -gt 0 ] && summary="$summary worktree=ro"
    printf '%s post-session-check=%s' "$summary" "$(_onoff "${GIT_HARDENING:-true}")"
}
