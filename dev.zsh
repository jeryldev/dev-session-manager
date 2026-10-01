#!/usr/bin/env zsh
# Dev Session Manager
# Quick development session bootstrapping with tmux
#
# Copyright (c) 2026 Jeryl Estopace
# GitHub: https://github.com/jeryldev
# LinkedIn: https://www.linkedin.com/in/jeryldev/
# Repository: https://github.com/jeryldev/dev-session-manager

# Version
DEV_VERSION="2.3.0"

# This file, sourced or executed: key bindings run it again from tmux.
DEV_SCRIPT="${${(%):-%x}:A}"

# Configuration
DEV_SESSION_PREFIX="dev-"

# Settings resolve env > config file > default, at the moment they are used:
# the same file then configures a sourced and an executed (Homebrew) install,
# where only exported variables would otherwise reach the latter.
typeset -gA _DEV_CFG_ENV=(
    ai_cmd DEV_AI_CMD
    ai_args DEV_AI_ARGS
    ssh_key DEV_SSH_KEY
    home_dir DEV_HOME_DIR
    windows DEV_WINDOWS
    worktree_create_cmd DEV_WORKTREE_CREATE_CMD
    agent_launch_cmd DEV_AGENT_LAUNCH_CMD
    key_agent DEV_KEY_AGENT
    key_term DEV_KEY_TERM
    key_kb DEV_KEY_KB
    key_git DEV_KEY_GIT
    key_new DEV_KEY_NEW
    key_coordinator DEV_KEY_COORDINATOR
    key_overview DEV_KEY_OVERVIEW
)
typeset -gA _DEV_CFG_DEFAULT=(
    ai_cmd claude
    home_dir "$HOME/code"
    windows editor,server,test,shell
    key_agent a
    key_term j
    key_kb k
    key_git g
    key_new N
    key_coordinator S
    key_overview O
)

_dev_config_file() {
    print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/dev-session-manager/config"
}

# A key's value from the config file: `key = value` lines, read as data.
_dev_config_file_value() {
    # `#` as "zero or more" below is extended glob; without it, it is literal.
    setopt localoptions extendedglob
    local file="$(_dev_config_file)" line key value
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* && "$line" != [[:space:]]#\#* ]] || continue
        key="${${line%%=*}//[[:space:]]/}"
        value="${line#*=}"
        value="${value##[[:space:]]#}"
        value="${value%%[[:space:]]#}"
        [[ "$key" == "$1" ]] && { print -r -- "$value"; return 0; }
    done < "$file"
    return 1
}

# Malformed lines in the config file, as "line N: text", for `dev config list`.
_dev_config_problems() {
    setopt localoptions extendedglob
    local file="$(_dev_config_file)" line n=0
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( n++ ))
        [[ -z "${line//[[:space:]]/}" || "$line" == [[:space:]]#\#* ]] && continue
        [[ "$line" == *=* ]] || print -r -- "line ${n}: ${line}"
    done < "$file"
}

# Refuses a value that would break where it is used; the message says why.
_dev_config_check() {
    local key="$1" value="$2"
    if [[ "$value" == *$'\n'* ]]; then
        echo -e "${RED}Error: a setting is one line${NC}"
        return 1
    fi
    case "$key" in
        ai_cmd)
            if [[ "$value" == *[[:space:]]* ]]; then
                echo -e "${RED}Error: ai_cmd is one word; put flags in ai_args${NC}"
                return 1
            fi
            ;;
        windows)
            DEV_WINDOWS="$value" _dev_window_names >/dev/null || return 1
            ;;
        key_*)
            if [[ ! "$value" =~ '^([CMS]-)*([A-Za-z0-9]|F[0-9]{1,2})$' ]]; then
                echo -e "${RED}Error: '${value}' is not a tmux key (e.g. a, N, M-a, F5)${NC}"
                return 1
            fi
            ;;
    esac
}

_dev_config() {
    local action="$1" key="$2" value="$3" file="$(_dev_config_file)"
    if [[ "$action" == (get|set|unset) && -z "${_DEV_CFG_ENV[$key]+set}" ]]; then
        echo -e "${RED}Error: unknown setting '${key}'${NC}"
        echo -e "${YELLOW}Settings: ${(oj:, :)${(k)_DEV_CFG_ENV}}${NC}"
        return 1
    fi
    case "$action" in
        get)
            value="$(_dev_cfg "$key")"
            [[ -n "$value" ]] || return 1
            print -r -- "$value"
            ;;
        set|unset)
            if [[ "$action" == set ]]; then
                _dev_config_check "$key" "$value" || return 1
            fi
            mkdir -p "${file:h}" || return 1
            local tmp="${file}.tmp.$$" line
            {
                if [[ -r "$file" ]]; then
                    while IFS= read -r line || [[ -n "$line" ]]; do
                        [[ "${${line%%=*}//[[:space:]]/}" == "$key" && "$line" == *=* ]] && continue
                        print -r -- "$line"
                    done < "$file"
                fi
                if [[ "$action" == set ]]; then
                    print -r -- "${key} = ${value}"
                fi
            } > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
            # A running server keeps what dev last published; refresh it so the
            # agent key sees the change without a new shell.
            tmux list-sessions &>/dev/null && _dev_setup_popup_keybindings force
            return 0
            ;;
        list)
            local problem env_var source
            for problem in ${(f)"$(_dev_config_problems)"}; do
                echo -e "${YELLOW}⚠ ${file}: ${problem} (not key = value; ignored)${NC}"
            done
            for key in ${(o)${(k)_DEV_CFG_ENV}}; do
                env_var="${_DEV_CFG_ENV[$key]}"
                if [[ -n "${(P)env_var}" ]]; then
                    source="(env ${env_var})"
                elif value="$(_dev_config_file_value "$key")" && [[ -n "$value" ]]; then
                    source="(file)"
                elif [[ -n "${_DEV_CFG_DEFAULT[$key]}" ]]; then
                    source="(default)"
                else
                    source="(unset)"
                fi
                printf "  %-20s %-32s %s\n" "$key" "$(_dev_cfg "$key")" "$source"
            done
            ;;
        path)
            print -r -- "$file"
            ;;
        *)
            echo -e "${RED}Usage: dev config get <key> | set <key> <value> | unset <key> | list | path${NC}"
            return 1
            ;;
    esac
}

_dev_cfg() {
    local key="$1" env_var="${_DEV_CFG_ENV[$1]}" value
    if [[ -n "$env_var" && -n "${(P)env_var}" ]]; then
        print -r -- "${(P)env_var}"
    elif value="$(_dev_config_file_value "$key")" && [[ -n "$value" ]]; then
        print -r -- "$value"
    else
        print -r -- "${_DEV_CFG_DEFAULT[$key]}"
    fi
}

# Colors are chosen per call, not when this file is sourced: sourced from
# .zshrc the file is read once, on a terminal, and every later `dev ... | cat`
# would still get escape codes. Assigned to the caller's locals (zsh scoping is
# dynamic), so helpers see them and the user's own $RED is never touched.
_dev_set_colors() {
    if [[ -t 1 ]]; then
        RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' NC='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' NC=''
    fi
}

# Check if a command is available
_dev_has_command() {
    command -v "$1" &> /dev/null
}

_dev_check_optional() {
    local cmd="$1" label="$2" install="$3"
    if _dev_has_command "$cmd"; then
        echo -e "  ${GREEN}✓${NC} $cmd ($label)"
    else
        echo -e "  ${RED}✗${NC} $cmd ($install)"
    fi
}

# Show prerequisite status with checkmarks
_dev_show_prerequisites() {
    echo ""
    echo -e "${YELLOW}Prerequisites:${NC}"

    # Check zsh
    if [[ -n "$ZSH_VERSION" ]]; then
        echo -e "  ${GREEN}✓${NC} zsh ($ZSH_VERSION)"
    else
        echo -e "  ${RED}✗${NC} zsh (not detected)"
    fi

    # Check tmux
    if _dev_has_command tmux; then
        local tmux_ver=$(tmux -V 2>/dev/null | cut -d' ' -f2)
        echo -e "  ${GREEN}✓${NC} tmux ($tmux_ver)"
    else
        echo -e "  ${RED}✗${NC} tmux (not installed)"
        echo -e "      ${YELLOW}Install: brew install tmux${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Optional tools:${NC}"
    _dev_check_optional claude  "AI popup: Prefix a"    "brew install claude-code"
    _dev_check_optional kb      "Kanban popup: Prefix k" "brew install jeryldev/tap/kb"
    _dev_check_optional lazygit "Git popup: Prefix g"   "brew install lazygit"

    echo ""
}

# Normalize session names
_dev_normalize_session_name() {
    local name="$1"
    if [[ ! "$name" =~ ^${DEV_SESSION_PREFIX} ]]; then
        echo "${DEV_SESSION_PREFIX}${name}"
    else
        echo "$name"
    fi
}

# Get display name (without prefix)
_dev_display_name() {
    local session_name="$1"
    echo "${session_name#${DEV_SESSION_PREFIX}}"
}

# Validate session name
_dev_validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Session name cannot be empty${NC}"
        return 1
    fi
    if [[ "$name" =~ [^a-zA-Z0-9_-] ]]; then
        echo -e "${RED}Error: Session name can only contain letters, numbers, hyphens, and underscores${NC}"
        return 1
    fi
    return 0
}

# Check if tmux is available
_dev_check_tmux() {
    if ! _dev_has_command tmux; then
        echo -e "${RED}Error: tmux is not installed${NC}"
        echo -e "${YELLOW}Install with: brew install tmux${NC}"
        return 1
    fi
    return 0
}


_dev_session_not_found() {
    local display_name="$1"
    echo -e "${RED}✗ Session '${display_name}' not found${NC}"
    echo -e "${YELLOW}Tip: Run 'dev ls' to see active sessions${NC}"
}

# Windows are numbered from 1 on any config, as `dev help` and the grid's
# `prefix N` promise: new-session puts the first window at the server's
# base-index, 0 on a stock config, which left `prefix 1` reaching nothing.
_dev_number_from_one() {
    local session_name="$1"
    tmux set-option -t "=${session_name}:" base-index 1
    local first_index=$(tmux display-message -p -t "=${session_name}:" '#{window_index}')
    [[ "$first_index" == "1" ]] || tmux move-window -s "=${session_name}:${first_index}" -t "=${session_name}:1"
}

# The windows `dev <name>` creates, one per line: DEV_WINDOWS (comma list) or
# the default four. Checked before anything is built: a name tmux cannot
# target would leave a half-made session, and prefix 1-9 reaches only nine.
_dev_window_names() {
    local -a names=(${(s:,:)$(_dev_cfg windows)})
    local name
    for name in "${names[@]}"; do
        if [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_-] ]]; then
            echo -e "${RED}Error: invalid window name in DEV_WINDOWS: '${name}' (letters, numbers, - and _ only)${NC}" >&2
            return 1
        fi
    done
    if (( ${#names} > 9 )); then
        echo -e "${RED}Error: DEV_WINDOWS lists ${#names} windows; prefix 1-9 reaches nine${NC}" >&2
        return 1
    fi
    print -l -- "${names[@]}"
}

_dev_slug() {
    print -r -- "${1//[^a-zA-Z0-9_-]/-}"
}

# The main checkout of the repo containing the current directory, from any of
# its worktrees: --show-toplevel would name the worktree instead.
_dev_repo_root() {
    local common
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    common="${common:A}"
    if [[ "${common:t}" == ".git" ]]; then
        print -r -- "${common:h}"
    else
        print -r -- "$common"
    fi
}

# One usable worktree path per line, main checkout first. NUL-separated
# porcelain, because a path may contain a newline; a record starts at its
# `worktree` line. Bare entries have no checkout, and a prunable one's
# directory is gone, so neither can be a tab.
_dev_worktrees() {
    local repo="$1" field wt_path="" skip=""
    local -a fields=("${(@0)$(git -C "$repo" worktree list --porcelain -z)}")
    for field in "${fields[@]}" "worktree "; do
        if [[ "$field" == "worktree "* ]]; then
            if [[ -n "$wt_path" && -z "$skip" ]]; then
                if [[ -d "$wt_path" ]]; then
                    print -r -- "$wt_path"
                else
                    print -r -- "Skipping ${wt_path}: directory not found" >&2
                fi
            elif [[ -n "$wt_path" && "$skip" == prunable* ]]; then
                print -r -- "Skipping ${wt_path}: ${skip}" >&2
            fi
            wt_path="${field#worktree }" skip=""
        elif [[ "$field" == bare || "$field" == prunable* ]]; then
            skip="$field"
        fi
    done
}

_dev_sha1() {
    print -rn -- "$1" | git hash-object --stdin
}

# Stamped on every grid tab. The ids are derived from paths, never stored, so
# a grid rebuilt after a reboot gets the same ones and each agent resumes its
# own conversation. The session id is a SHA-1 shaped as a version-5 UUID,
# which is what `claude --session-id` takes.
_dev_sid_for() {
    local h="$(_dev_sha1 "$1")"
    local variant="$(( (16#${h[17]} & 3) | 8 ))"
    local sid="${h[1,8]}-${h[9,12]}-5${h[14,16]}-$(( [##16] variant ))${h[18,20]}-${h[21,32]}"
    print -r -- "${(L)sid}"
}

_dev_stamp_workspace() {
    local target="$1" wt_path="$2" repo="$3"
    local path_hash="$(_dev_sha1 "$wt_path")"
    tmux set-option -w -t "$target" @dev_workspace "$wt_path"
    tmux set-option -w -t "$target" @dev_ws_id "$(_dev_slug "${wt_path:t}")-${path_hash[1,4]}"
    tmux set-option -w -t "$target" @dev_agent_sid "$(_dev_sid_for "dev-grid:${repo}:${wt_path}")"
}

_dev_grid_build() {
    local repo session_name stamp
    if ! repo="$(_dev_repo_root)"; then
        echo -e "${RED}Error: not a git repository: ${PWD}${NC}"
        return 1
    fi
    session_name="${DEV_SESSION_PREFIX}$(_dev_slug "${repo:t}")-grid"
    local display_name=$(_dev_display_name "$session_name")

    # The stamp, not the name, says a session is this repo's grid: `dev
    # myrepo-grid` makes a role session with exactly this name, and adopting it
    # would put `frontend` where the first workspace belongs.
    if tmux has-session -t "=${session_name}" 2>/dev/null; then
        stamp="$(tmux show-options -t "=${session_name}:" -v @dev_grid 2>/dev/null)"
        if [[ "$stamp" == "$repo" ]]; then
            # Report drift, never act on it: a removed worktree's tab may hold
            # unsaved work, and new ones are added only when asked.
            local -a added removed
            _dev_grid_drift "$repo" "$session_name"
            if (( ${#added} + ${#removed} )); then
                echo -e "${YELLOW}⚠ $(_dev_plural ${#added} workspace) added, ${#removed} removed — run 'dev grid sync' / 'dev grid prune'${NC}"
            fi
            _dev_attach_session "$session_name" "Attaching to grid: ${display_name}"
            return
        elif [[ -z "$stamp" ]]; then
            echo -e "${RED}✗ '${session_name}' exists but is not a workspace grid${NC}"
            echo ""
            echo -e "  Attach to it:   ${BLUE}dev attach ${display_name}${NC}"
            echo -e "  Or remove it:   ${BLUE}dev kill ${display_name}${NC}"
            echo -e "  Then re-run:    ${BLUE}dev grid${NC}"
        else
            echo -e "${RED}✗ '${session_name}' is the grid of ${stamp}${NC}"
            echo -e "  Remove it with ${BLUE}dev kill ${display_name}${NC}, or rename this repo's directory"
        fi
        return 1
    fi

    local -a paths=(${(f)"$(_dev_worktrees "$repo")"})
    if (( ${#paths} == 0 )); then
        echo -e "${RED}Error: no usable worktrees in ${repo}${NC}"
        return 1
    fi
    # prefix 1-9 reaches nine tabs. A tenth would quietly need prefix w, and
    # building a subset nobody chose is worse than refusing.
    if (( ${#paths} > 9 )); then
        echo -e "${RED}Error: ${#paths} worktrees, but a grid holds 9 tabs (prefix 1-9)${NC}"
        echo -e "${YELLOW}Remove some with 'git worktree remove', or wait for workspace selection${NC}"
        return 1
    fi

    echo -e "${GREEN}Creating grid: ${display_name}${NC}"
    tmux new-session -d -s "$session_name" -n "${paths[1]:t}" -c "${paths[1]}"
    _dev_number_from_one "$session_name"
    tmux set-option -t "=${session_name}:" @dev_grid "$repo"
    _dev_stamp_workspace "=${session_name}:1" "${paths[1]}" "$repo"
    local i
    for (( i = 2; i <= ${#paths}; i++ )); do
        tmux new-window -t "=${session_name}:${i}" -n "${paths[i]:t}" -c "${paths[i]}"
        _dev_stamp_workspace "=${session_name}:${i}" "${paths[i]}" "$repo"
    done
    tmux select-window -t "=${session_name}:1"
    _dev_attach_session "$session_name" "Created $(_dev_plural ${#paths} tab), one per worktree"
}

# The grid session stamped for a repo, found by its stamp, never its name.
_dev_grid_session() {
    local repo="$1" stamp name
    tmux list-sessions -F '#{@dev_grid}|#{session_name}' 2>/dev/null |
        while IFS='|' read -r stamp name; do
            [[ "$stamp" == "$repo" ]] && { print -r -- "$name"; return; }
        done
}

# Sets repo and grid_session in the caller, or explains why it cannot.
_dev_grid_locate() {
    if ! repo="$(_dev_repo_root)"; then
        echo -e "${RED}Error: not a git repository: ${PWD}${NC}"
        return 1
    fi
    grid_session="$(_dev_grid_session "$repo")"
    if [[ -z "$grid_session" ]]; then
        echo -e "${RED}No grid for ${repo}${NC}"
        echo -e "${YELLOW}Run 'dev grid' to build one${NC}"
        return 1
    fi
}

_dev_grid_status() {
    local repo grid_session
    _dev_grid_locate || return 1
    local -a rows=(${(f)"$(tmux list-windows -t "=${grid_session}:" -F '#{window_index}|#{@dev_workspace}|#{window_name}')"})
    local index workspace name branch changes row width=9
    for row in "${rows[@]}"; do
        name="${row#*|*|}"
        (( ${#name} > width )) && width=${#name}
    done
    printf "  %-3s %-${width}s  %-28s %s\n" "#" "workspace" "branch" "state"
    for row in "${rows[@]}"; do
        IFS='|' read -r index workspace name <<< "$row"
        if [[ -z "$workspace" ]]; then
            printf "  %-3s %-${width}s  %-28s %s\n" "$index" "$name" "-" "not a workspace"
            continue
        fi
        branch="$(git -C "$workspace" branch --show-current 2>/dev/null)"
        [[ -n "$branch" ]] || branch="(detached $(git -C "$workspace" rev-parse --short HEAD 2>/dev/null))"
        changes=$(git -C "$workspace" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        (( changes )) && changes="${changes} changed" || changes="clean"
        printf "  %-3s %-${width}s  %-28s %s\n" "$index" "$name" "$branch" "$changes"
    done
}

# The worktree that has the branch checked out, if any.
_dev_worktree_for_branch() {
    local repo="$1" branch="$2" field wt_path=""
    for field in "${(@0)$(git -C "$repo" worktree list --porcelain -z)}"; do
        case "$field" in
            "worktree "*) wt_path="${field#worktree }" ;;
            "branch refs/heads/${branch}") print -r -- "$wt_path"; return ;;
        esac
    done
}

_dev_grid_add() {
    local branch="$1"
    if [[ "$branch" == "--prompt" ]]; then
        _dev_grid_add_prompt
        return
    fi
    if [[ -z "$branch" ]]; then
        echo -e "${RED}Usage: dev grid add <branch>${NC}"
        return 1
    fi
    if ! git check-ref-format --branch "$branch" &>/dev/null; then
        echo -e "${RED}Error: '${branch}' is not a valid branch name${NC}"
        return 1
    fi
    local repo grid_session
    _dev_grid_locate || return 1

    local wt_path="$(_dev_worktree_for_branch "$repo" "$branch")"
    local index workspace
    if [[ -n "$wt_path" ]]; then
        while IFS='|' read -r index workspace; do
            if [[ "$workspace" == "$wt_path" ]]; then
                _dev_grid_show_tab "$grid_session" "$index"
                echo -e "${BLUE}${branch} is already tab ${index}${NC}"
                return 0
            fi
        done < <(tmux list-windows -t "=${grid_session}:" -F '#{window_index}|#{@dev_workspace}')
    fi

    local free="$(_dev_grid_free_indexes "$grid_session" | head -1)"
    if [[ -z "$free" ]]; then
        echo -e "${RED}Error: the grid already has 9 tabs (prefix 1-9)${NC}"
        return 1
    fi

    if [[ -z "$wt_path" ]]; then
        wt_path="$(_dev_create_worktree "$repo" "$branch")" || return 1
    fi

    _dev_grid_open_tab "$grid_session" "$free" "$wt_path" "$repo"
    _dev_grid_show_tab "$grid_session" "$free"
    echo -e "${GREEN}✓ ${branch} is tab ${free}${NC}"
}

# What prefix N runs in its popup. The branch is read as a line of text, so it
# is only ever data; on failure the popup stays open long enough to read why.
_dev_grid_add_prompt() {
    local branch rc
    print -n "Branch for the new tab: "
    read -r branch || return 0
    [[ -n "$branch" ]] || return 0
    _dev_grid_add "$branch"
    rc=$?
    if (( rc )) && [[ -t 0 ]]; then
        print -n "Press Enter to close "
        read -r
    fi
    return $rc
}

# A configured command (bin/agent-grid, say, which also provisions a database
# and ports) or plain `git worktree add`. The branch is single-quoted into the
# command: git accepts ; $( ) and backticks in branch names. A failing command
# is an error, never a reason to fall back to git and build half a workspace.
_dev_create_worktree() {
    local repo="$1" branch="$2" out wt_path rc
    local create_cmd="$(_dev_cfg worktree_create_cmd)"
    if [[ -n "$create_cmd" ]]; then
        local cmd="${create_cmd//\{branch\}/${(qq)branch}}"
        out="$(cd "$repo" && sh -c "$cmd")"
        rc=$?
        if (( rc )); then
            echo -e "${RED}Error: the create command exited ${rc}: ${create_cmd}${NC}" >&2
            return 1
        fi
        # An array, not ${${(f)out}[-1]}: one line of output makes that a
        # scalar, and [-1] then takes its last character.
        local -a lines=(${(f)out})
        wt_path="${lines[-1]}"
        if [[ -z "$wt_path" || ! -d "$wt_path" ]]; then
            echo -e "${RED}Error: the create command printed no existing directory: ${create_cmd}${NC}" >&2
            return 1
        fi
    else
        wt_path="${repo:h}/${repo:t}-$(_dev_slug "$branch")"
        if [[ -e "$wt_path" ]]; then
            echo -e "${RED}Error: ${wt_path} already exists${NC}" >&2
            return 1
        fi
        if git -C "$repo" show-ref --verify --quiet "refs/heads/${branch}"; then
            git -C "$repo" worktree add -q "$wt_path" "$branch" >&2 || return 1
        else
            git worktree add -q -b "$branch" "$wt_path" >&2 || return 1
        fi
    fi
    print -r -- "${wt_path:A}"
}

# Tab numbers 1-9 not in use, lowest first. New tabs fill these rather than
# appending past 9: existing tabs never move, and every tab stays reachable
# with prefix N.
_dev_grid_free_indexes() {
    local -a used=(${(f)"$(tmux list-windows -t "=${1}:" -F '#{window_index}')"})
    local index
    for index in {1..9}; do
        (( ${used[(Ie)$index]} )) || print -r -- "$index"
    done
}

_dev_grid_open_tab() {
    local grid_session="$1" index="$2" wt_path="$3" repo="$4"
    tmux new-window -d -t "=${grid_session}:${index}" -n "${wt_path:t}" -c "$wt_path"
    _dev_stamp_workspace "=${grid_session}:${index}" "$wt_path" "$repo"
}

# Worktrees with no tab (into `added`) and tabs whose worktree is gone (into
# `removed`, as "index|path"), for the caller's arrays.
_dev_grid_drift() {
    local repo="$1" grid_session="$2" index workspace
    local -a worktrees=(${(f)"$(_dev_worktrees "$repo" 2>/dev/null)"}) tabs=()
    while IFS='|' read -r index workspace; do
        [[ -n "$workspace" ]] || continue
        tabs+=("$workspace")
        (( ${worktrees[(Ie)$workspace]} )) || removed+=("${index}|${workspace}")
    done < <(tmux list-windows -t "=${grid_session}:" -F '#{window_index}|#{@dev_workspace}')
    for workspace in "${worktrees[@]}"; do
        (( ${tabs[(Ie)$workspace]} )) || added+=("$workspace")
    done
}

_dev_grid_sync() {
    local dry_run=0 repo grid_session
    [[ "$1" == "--dry-run" ]] && dry_run=1
    _dev_grid_locate || return 1
    local -a added removed free=(${(f)"$(_dev_grid_free_indexes "$grid_session")"})
    _dev_grid_drift "$repo" "$grid_session"
    if (( ! ${#added} )); then
        echo -e "${GREEN}✓ Nothing to sync${NC}"
        return 0
    fi
    if (( ${#added} > ${#free} )); then
        echo -e "${RED}Error: $(_dev_plural ${#added} "new worktree"), but only ${#free} free tabs (prefix 1-9)${NC}"
        echo -e "${YELLOW}Remove tabs with 'dev grid prune' after 'git worktree remove', or close a tab you no longer need${NC}"
        return 1
    fi
    local i
    for (( i = 1; i <= ${#added}; i++ )); do
        if (( dry_run )); then
            echo "  would add ${added[i]:t} as tab ${free[i]}"
        else
            _dev_grid_open_tab "$grid_session" "${free[i]}" "${added[i]}" "$repo"
            echo -e "${GREEN}✓ ${added[i]:t} is tab ${free[i]}${NC}"
        fi
    done
}

_dev_grid_prune() {
    local dry_run=0 repo grid_session
    [[ "$1" == "--dry-run" ]] && dry_run=1
    _dev_grid_locate || return 1
    local -a added removed
    _dev_grid_drift "$repo" "$grid_session"
    if (( ! ${#removed} )); then
        echo -e "${GREEN}✓ Nothing to prune${NC}"
        return 0
    fi
    local entry index workspace ws_id sid parent popup_ws
    for entry in "${removed[@]}"; do
        index="${entry%%|*}" workspace="${entry#*|}"
        if (( dry_run )); then
            echo "  would remove tab ${index} (${workspace:t})"
            continue
        fi
        # The tab's popups carry its workspace id; they go with it.
        ws_id="$(tmux show-options -w -t "=${grid_session}:${index}" -qv @dev_ws_id)"
        if [[ -n "$ws_id" ]]; then
            tmux list-windows -a -F '#{session_id}|#{@dev_parent}|#{@dev_ws_id}' |
                while IFS='|' read -r sid parent popup_ws; do
                    [[ -n "$parent" && "$popup_ws" == "$ws_id" ]] && tmux kill-session -t "$sid" 2>/dev/null
                done
        fi
        tmux kill-window -t "=${grid_session}:${index}"
        echo -e "${GREEN}✓ Removed tab ${index} (${workspace:t})${NC}"
    done
}

_dev_grid_kill() {
    local dry_run=0 repo grid_session
    [[ "$1" == "--dry-run" ]] && dry_run=1
    _dev_grid_locate || return 1
    local session_id="$(tmux display-message -p -t "=${grid_session}:" '#{session_id}')"
    local -a popups=(${(f)"$(_dev_popup_descendants "$session_id")"})
    if (( dry_run )); then
        echo "  would kill ${grid_session} and $(_dev_plural ${#popups} popup)"
        return 0
    fi
    # The overview first (D14): its panes are clients of the agent popups.
    local popup_id
    for popup_id in "${popups[@]}"; do
        [[ "$(tmux show-options -t "$popup_id" -qv @dev_overview 2>/dev/null)" == 1 ]] && tmux kill-session -t "$popup_id" 2>/dev/null
    done
    for popup_id in "${popups[@]}"; do
        tmux kill-session -t "$popup_id" 2>/dev/null
    done
    tmux kill-session -t "$session_id"
    echo -e "${GREEN}✓ Killed ${grid_session} (and $(_dev_plural ${#popups} popup))${NC}"
}

_dev_grid_show_tab() {
    local grid_session="$1" index="$2"
    tmux select-window -t "=${grid_session}:${index}"
    [[ -n "$TMUX" ]] && tmux switch-client -t "=${grid_session}:${index}"
    return 0
}

_dev_attach_session() {
    local session_name="$1" message="$2"
    _dev_setup_popup_keybindings
    echo -e "${BLUE}${message}${NC}"
    # Inside tmux, attach would refuse to nest; switching the client is what
    # the user means. '=' makes the name exact: tmux otherwise falls back to a
    # prefix match, and dev-proj would reach dev-project.
    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "=${session_name}"
    else
        tmux attach -t "=${session_name}"
    fi
}

# Center text in a box
_dev_center_text() {
    local text="$1"
    local width="$2"
    local text_len=${#text}
    local padding=$(( (width - text_len) / 2 ))
    local left_pad=$(printf '%*s' "$padding" '')
    local right_pad=$(printf '%*s' "$((width - text_len - padding))" '')
    echo "${left_pad}${text}${right_pad}"
}

# Dev session manager
# Usage: dev <command> [args]
dev() {
    local cmd="$1"
    local box_width=56
    local RED GREEN YELLOW BLUE NC
    _dev_set_colors

    case "$cmd" in
        help|h|-h|--help)
            local title="Dev session manager"
            local centered_title=$(_dev_center_text "$title" "$box_width")

            echo -e "${GREEN}╔$(printf '═%.0s' {1..56})╗${NC}"
            echo -e "${GREEN}║${NC}${centered_title}${GREEN}║${NC}"
            echo -e "${GREEN}╚$(printf '═%.0s' {1..56})╝${NC}"

            _dev_show_prerequisites

            echo -e "${YELLOW}Commands:${NC}"
            echo -e "  ${BLUE}dev <name>${NC}         Create or attach to a dev session"
            echo -e "  ${BLUE}dev attach <name>${NC}  Attach to an existing dev session"
            echo -e "  ${BLUE}dev ls${NC}             List all dev sessions"
            echo -e "  ${BLUE}dev ls --all${NC}       ...and the popup sessions under each"
            echo -e "  ${BLUE}dev kill <name>${NC}    Kill a dev session and its popups"
            echo -e "  ${BLUE}dev clean${NC}          Remove popups whose session is gone"
            echo -e "  ${BLUE}dev${NC}                In a git repo: same as dev grid"
            echo -e "  ${BLUE}dev config list${NC}    Settings, and where each comes from"
            echo -e "  ${BLUE}dev agent status${NC}   Each grid tab's agent: working, idle, waiting, dead"
            echo -e "  ${BLUE}dev agent start <t>${NC} Start tab t's agent (the one prefix a opens)"
            echo -e "  ${BLUE}dev agent send <t>${NC}  Brief tab t's agent and confirm it arrived"
            echo -e "  ${BLUE}dev grid${NC}           One tab per git worktree of this repo"
            echo -e "  ${BLUE}dev grid status${NC}    Each tab's branch and changes"
            echo -e "  ${BLUE}dev grid add <br>${NC}  New worktree for a branch, as a new tab"
            echo -e "  ${BLUE}dev grid sync${NC}      Add tabs for new worktrees (--dry-run)"
            echo -e "  ${BLUE}dev grid prune${NC}     Remove tabs of removed worktrees (--dry-run)"
            echo -e "  ${BLUE}dev grid kill${NC}      Close the grid and its popups (--dry-run)"
            echo -e "  ${BLUE}dev reload${NC}         Reload popup keybindings"
            echo -e "  ${BLUE}dev help${NC}           Show this help"
            echo -e "  ${BLUE}dev tmux${NC}           Show tmux commands reference"
            echo -e "  ${BLUE}dev version${NC}        Show version"
            echo ""
            echo -e "${YELLOW}Examples:${NC}"
            echo -e "  ${BLUE}dev myproject${NC}      Create 'dev-myproject' session"
            echo -e "  ${BLUE}dev 1${NC}              Create 'dev-1' session"
            echo -e "  ${BLUE}dev attach 1${NC}       Attach to 'dev-1'"
            echo -e "  ${BLUE}dev kill 1${NC}         Kill 'dev-1'"
            echo ""
            local -a windows=(${(f)"$(_dev_window_names 2>/dev/null)"})
            local layout="" i
            for (( i = 1; i <= ${#windows}; i++ )); do
                layout+="  ${i}. ${windows[i]}"
            done
            echo -e "${YELLOW}'dev <name>' windows (all start at $(_dev_cfg home_dir); set DEV_WINDOWS to change):${NC}"
            echo -e "${layout}"
            echo ""
            echo -e "${YELLOW}Popup keybindings (inside tmux):${NC}"
            local conflicts="$(tmux show-options -gqv @dev_key_conflicts 2>/dev/null)" setting k label held
            for setting label in key_agent "AI assistant ($(_dev_cfg ai_cmd))" key_kb "Kanban board (kb)" \
                    key_git "Git UI (lazygit)" key_term "Terminal (shell)" key_new "New branch as a grid tab" \
                    key_coordinator "Grid coordinator agent" key_overview "Overview of the grid's agents"; do
                k="$(_dev_cfg "$setting")"
                held=""
                [[ ";${conflicts};" == *";${k}="* ]] && held="${${conflicts#*${k}=}%%;*}"
                if [[ -n "$held" ]]; then
                    printf "  ${BLUE}%-17s${NC} %s ${YELLOW}(not bound: taken by %s; dev config set %s <key>)${NC}\n" "Prefix ${k}" "$label" "$held" "$setting"
                else
                    printf "  ${BLUE}%-17s${NC} %s\n" "Prefix ${k}" "$label"
                fi
            done
            echo ""
            ;;

        version|v|-v|--version)
            echo -e "Dev session manager ${GREEN}v${DEV_VERSION}${NC}"
            echo -e "https://github.com/jeryldev/dev-session-manager"
            ;;

        ls|list)
            if ! _dev_check_tmux; then
                return 1
            fi

            echo -e "${GREEN}Active dev sessions:${NC}"
            local sessions=$(tmux list-sessions 2>/dev/null | grep "^${DEV_SESSION_PREFIX}")
            if [[ "$2" == "--all" ]]; then
                local orphan_rows=$(_dev_orphan_popups)
                if [[ -n "$orphan_rows" ]]; then
                    echo -e "${YELLOW}Orphaned popups (parent gone, 'dev clean' removes them):${NC}"
                    local id parent name
                    while IFS='|' read -r id parent name; do
                        echo "  $name"
                    done <<< "$orphan_rows"
                    echo ""
                fi
            fi
            if [ -z "$sessions" ]; then
                echo -e "  ${YELLOW}No dev sessions found${NC}"
            else
                while IFS= read -r line; do
                    echo "  ${line#${DEV_SESSION_PREFIX}}"
                    if [[ "$2" == "--all" ]]; then
                        local popup_id
                        for popup_id in ${(f)"$(_dev_popup_descendants "$(tmux display-message -p -t "=${line%%:*}:" '#{session_id}')")"}; do
                            echo "    ↳ $(tmux display-message -p -t "$popup_id" '#{session_name}')"
                        done
                    fi
                done <<< "$sessions"
                echo ""
                echo -e "${BLUE}Tip: Use 'dev attach <name>' to attach or 'dev kill <name>' to kill${NC}"
            fi
            ;;

        attach|a)
            if ! _dev_check_tmux; then
                return 1
            fi

            if [ -z "$2" ]; then
                echo -e "${RED}Usage: dev attach <name>${NC}"
                echo -e "${YELLOW}Example: dev attach myproject${NC}"
                return 1
            fi

            if ! _dev_validate_name "$2"; then
                return 1
            fi

            local session_name=$(_dev_normalize_session_name "$2")
            local display_name=$(_dev_display_name "$session_name")

            if tmux has-session -t "=${session_name}" 2>/dev/null; then
                _dev_attach_session "$session_name" "Attaching to: ${display_name}"
            else
                _dev_session_not_found "$display_name"
            fi
            ;;

        kill|k)
            if ! _dev_check_tmux; then
                return 1
            fi

            if [ -z "$2" ]; then
                echo -e "${RED}Usage: dev kill <name>${NC}"
                echo -e "${YELLOW}Example: dev kill myproject${NC}"
                return 1
            fi

            if ! _dev_validate_name "$2"; then
                return 1
            fi

            local session_name=$(_dev_normalize_session_name "$2")
            local display_name=$(_dev_display_name "$session_name")

            if tmux has-session -t "=${session_name}" 2>/dev/null; then
                # The trailing ':' matters: display-message takes a pane target,
                # where a bare '=name' resolves to nothing, silently.
                # Popups first, by id: the session-closed hook would race us
                # for them otherwise, and a leaked popup's name may not be
                # targetable at all.
                local session_id=$(tmux display-message -p -t "=${session_name}:" '#{session_id}')
                local -a popups=(${(f)"$(_dev_popup_descendants "$session_id")"})
                local popup_id
                for popup_id in "${popups[@]}"; do
                    tmux kill-session -t "$popup_id" 2>/dev/null
                done
                tmux kill-session -t "=${session_name}"
                if (( ${#popups} )); then
                    echo -e "${GREEN}✓ Killed session: ${display_name} (and $(_dev_plural ${#popups} popup))${NC}"
                else
                    echo -e "${GREEN}✓ Killed session: ${display_name}${NC}"
                fi
            else
                _dev_session_not_found "$display_name"
            fi
            ;;

        grid)
            if ! _dev_check_tmux; then
                return 1
            fi
            case "$2" in
                "") _dev_grid_build ;;
                status) _dev_grid_status ;;
                sync) _dev_grid_sync "$3" ;;
                prune) _dev_grid_prune "$3" ;;
                kill) _dev_grid_kill "$3" ;;
                add) _dev_grid_add "$3" ;;
                *)
                    echo -e "${RED}Unknown grid command: $2${NC}"
                    echo -e "${YELLOW}Usage: dev grid [status | add <branch> | sync | prune | kill] [--dry-run]${NC}"
                    return 1
                    ;;
            esac
            ;;

        config)
            _dev_config "$2" "$3" "$4"
            ;;

        agent)
            if ! _dev_check_tmux; then
                return 1
            fi
            case "$2" in
                start) shift 2; _dev_agent_start "$@" ;;
                send) shift 2; _dev_agent_send "$@" ;;
                status) _dev_agent_status "$3" ;;
                overview)
                    local here="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
                    _dev_overview "$here" "$(tmux display-message -p '#{client_name}' 2>/dev/null)"
                    ;;
                *)
                    echo -e "${RED}Usage: dev agent start|send|status ...${NC}"
                    return 1
                    ;;
            esac
            ;;

        __coordinator)
            _dev_coordinator "$2" "$3"
            ;;

        __overview)
            _dev_overview "$2" "$3"
            ;;

        __agent)
            # What the agent popup runs; not a user command.
            _dev_agent_exec "$2"
            ;;

        clean)
            if ! _dev_check_tmux; then
                return 1
            fi
            local dry_run=0
            [[ "$2" == "--dry-run" ]] && dry_run=1

            local orphan_rows=$(_dev_orphan_popups)
            local -a doomed
            local id parent name
            if [[ -n "$orphan_rows" ]]; then
                while IFS='|' read -r id parent name; do
                    doomed+=("$id" ${(f)"$(_dev_popup_descendants "$id")"})
                done <<< "$orphan_rows"
            fi

            if (( ! ${#doomed} )); then
                echo -e "${GREEN}✓ No orphaned popups${NC}"
            elif (( dry_run )); then
                echo -e "${YELLOW}Would remove $(_dev_plural ${#doomed} "orphaned popup"):${NC}"
                for id in "${doomed[@]}"; do
                    echo "  $(tmux display-message -p -t "$id" '#{session_name}')"
                done
            else
                for id in "${doomed[@]}"; do
                    tmux kill-session -t "$id" 2>/dev/null
                done
                echo -e "${GREEN}✓ Removed $(_dev_plural ${#doomed} "orphaned popup")${NC}"
            fi

            # Unstamped popups from before v2.4 are only ours by name, and a
            # name is not proof: report them, never kill them.
            local legacy_rows=$(tmux list-sessions -F '#{session_id}|#{@dev_parent}|#{session_name}' 2>/dev/null |
                grep -E '^[^|]*\|\|(ai|kb|lg|term)-')
            if [[ -n "$legacy_rows" ]]; then
                echo ""
                echo -e "${YELLOW}Popup sessions from before v2.4 (not removed; they carry no owner stamp):${NC}"
                while IFS='|' read -r id parent name; do
                    echo "  $name    tmux kill-session -t '$id'"
                done <<< "$legacy_rows"
            fi
            ;;

        reload)
            if ! tmux list-sessions &>/dev/null; then
                echo -e "${YELLOW}No active tmux server. Start a session first.${NC}"
                return 1
            fi
            echo -e "${BLUE}Reloading dev configuration...${NC}"
            if _dev_setup_popup_keybindings force; then
                echo -e "${GREEN}✓ Popup keybindings updated${NC}"
            else
                echo -e "${YELLOW}⚠ Some keybindings were skipped${NC}"
            fi
            ;;

        tmux|t)
            local title="Tmux commands reference"
            local centered_title=$(_dev_center_text "$title" "$box_width")

            echo -e "${GREEN}╔$(printf '═%.0s' {1..56})╗${NC}"
            echo -e "${GREEN}║${NC}${centered_title}${GREEN}║${NC}"
            echo -e "${GREEN}╚$(printf '═%.0s' {1..56})╝${NC}"
            echo ""
            echo -e "${YELLOW}Note: These examples use Ctrl+b as the prefix (default).${NC}"
            echo -e "${YELLOW}Your prefix may differ. Check with: tmux show-option -g prefix${NC}"
            echo ""
            echo -e "${YELLOW}Detach and exit:${NC}"
            echo -e "  ${BLUE}Prefix d${NC}          ${GREEN}Detach${NC} from session (keeps running)"
            echo -e "  ${BLUE}exit${NC}              ${RED}Exit${NC} shell (closes pane/window)"
            echo -e "  ${BLUE}dev kill <name>${NC}   ${RED}Kill${NC} entire session"
            echo ""
            echo -e "${YELLOW}Window navigation:${NC}"
            echo -e "  ${BLUE}Prefix n${NC}          Next window"
            echo -e "  ${BLUE}Prefix p${NC}          Previous window"
            echo -e "  ${BLUE}Prefix 0-9${NC}        Jump to window number"
            echo -e "  ${BLUE}Prefix w${NC}          Show window list"
            echo ""
            echo -e "${YELLOW}Window management:${NC}"
            echo -e "  ${BLUE}Prefix c${NC}          Create new window"
            echo -e "  ${BLUE}Prefix ,${NC}          Rename current window"
            echo -e "  ${BLUE}Prefix &${NC}          Kill current window"
            echo ""
            echo -e "${YELLOW}Pane splits:${NC}"
            echo -e "  ${BLUE}Prefix %${NC}          Split vertically (side by side)"
            echo -e "  ${BLUE}Prefix \"${NC}         Split horizontally (top/bottom)"
            echo -e "  ${BLUE}Prefix z${NC}          Toggle pane zoom (fullscreen)"
            echo -e "  ${BLUE}Prefix x${NC}          Close current pane"
            echo ""
            echo -e "${YELLOW}Pane navigation:${NC}"
            echo -e "  ${BLUE}Prefix arrow${NC}      Navigate with arrow keys"
            echo -e "  ${BLUE}Prefix o${NC}          Cycle through panes"
            echo ""
            echo -e "${YELLOW}Copy mode (scrollback):${NC}"
            echo -e "  ${BLUE}Prefix [${NC}          Enter copy mode"
            echo -e "  ${BLUE}q${NC}                 Exit copy mode"
            echo ""
            echo -e "${YELLOW}Session management:${NC}"
            echo -e "  ${BLUE}Prefix \$${NC}         Rename session"
            echo -e "  ${BLUE}Prefix s${NC}          Show all sessions"
            echo -e "  ${BLUE}Prefix (${NC}          Switch to previous session"
            echo -e "  ${BLUE}Prefix )${NC}          Switch to next session"
            echo ""
            echo -e "${YELLOW}Dev popups:${NC}"
            echo -e "  ${BLUE}Prefix a${NC}          AI assistant popup"
            echo -e "  ${BLUE}Prefix k${NC}          Kanban board popup"
            echo -e "  ${BLUE}Prefix g${NC}          Git UI popup"
            echo -e "  ${BLUE}Prefix j${NC}          Terminal popup"
            echo ""
            echo -e "${GREEN}Quick reference:${NC}"
            echo -e "  ${BLUE}Detach${NC} = Prefix d (session stays alive, can reattach)"
            echo -e "  ${BLUE}Exit${NC}   = type 'exit' (closes current pane/window)"
            echo -e "  ${BLUE}Kill${NC}   = dev kill <name> (destroys entire session)"
            echo ""
            ;;

        "")
            # Inside a repo the shortest command opens its grid.
            if _dev_repo_root &>/dev/null; then
                _dev_check_tmux || return 1
                _dev_grid_build
                return
            fi
            echo -e "${RED}Usage: dev <command> [args]${NC}"
            echo -e "${YELLOW}Run 'dev help' for more information${NC}"
            echo -e "${YELLOW}Run 'dev' alone inside a git repo to open its grid${NC}"
            return 1
            ;;

        *)
            # Check tmux before creating session
            if ! _dev_check_tmux; then
                return 1
            fi

            # Create or attach to session
            if ! _dev_validate_name "$1"; then
                return 1
            fi

            local -a windows
            windows=(${(f)"$(_dev_window_names)"}) || return 1

            local session_name=$(_dev_normalize_session_name "$1")
            local display_name=$(_dev_display_name "$session_name")

            # Check if session already exists
            if tmux has-session -t "=${session_name}" 2>/dev/null; then
                if [[ ! -t 0 ]]; then
                    echo -e "${RED}Error: Session '${display_name}' already exists (non-interactive, cannot prompt)${NC}"
                    return 1
                fi
                echo -e "${YELLOW}⚠ Session '${display_name}' already exists!${NC}"
                echo -ne "${GREEN}Attach to it? (y/n) ${NC}"
                read -r choice
                case "$choice" in
                    y|Y)
                        _dev_attach_session "$session_name" "Attaching to: ${display_name}"
                        ;;
                    *)
                        echo -e "${RED}Operation cancelled${NC}"
                        echo -e "${BLUE}Tip: Use 'dev kill $1' to kill the session${NC}"
                        ;;
                esac
                return 0
            fi

            # Create new session
            echo -e "${GREEN}Creating session: ${display_name}${NC}"

            local home_dir="$(_dev_cfg home_dir)"
            tmux new-session -d -s "$session_name" -n "${windows[1]}" -c "$home_dir"
            _dev_number_from_one "$session_name"
            local i
            for (( i = 2; i <= ${#windows}; i++ )); do
                tmux new-window -t "=${session_name}:${i}" -n "${windows[i]}" -c "$home_dir"
            done
            tmux select-window -t "=${session_name}:1"

            _dev_attach_session "$session_name" "Created $(_dev_plural ${#windows} window), starting at ${windows[1]}"
            ;;
    esac
}

_dev_validate_ai_cmd() {
    local ai_cmd="$(_dev_cfg ai_cmd)"
    if [[ "$ai_cmd" == *" "* ]]; then
        echo -e "${RED}Error: DEV_AI_CMD cannot contain spaces ('${ai_cmd}'); put flags in DEV_AI_ARGS${NC}"
        return 1
    fi
    return 0
}

# The shell script a popup key runs. tmux expands its #{...} formats at key
# press time, then hands it to sh.
#
# The popup's key is the window's workspace id when it has one (grid tabs, and
# popups, which inherit it), so renaming the tab or cd-ing elsewhere reaches
# the same popup and a popup opened inside a popup is not nested. Otherwise it
# is session-index-window, both names slugged there, not here: they are only
# known at key press, and tmux keeps ':' and '.' in a session name but cannot
# target one that has them. Every value spliced in is slug-safe or an id.
#
# The new popup is stamped in the tmux command that creates it: with its
# parent's session id (`prefix $` renames sessions; an id survives that), its
# key, and the pane its workspace started from, so dev can find the workspace
# again without copying paths through sh. The id is single-quoted because sh
# reads `$1` as a positional parameter. '=' makes every lookup exact: tmux
# otherwise prefix-matches, and term-x-0-edit would find term-x-0-edit2.
#
# Pass "nodisplay" as the fourth argument to create the popup's session
# without showing it: `dev agent start` makes exactly what the key would.
_dev_popup_script() {
    local prefix="$1" cmd="$2" suffix="${3:+-$3}" display="${4:-display}"
    local slug='[^a-zA-Z0-9_-]/-/'
    local key='#{?#{@dev_ws_id},#{@dev_ws_id},#{s/'"${slug}"':session_name}-#{window_index}-#{s/'"${slug}"':window_name}}'
    local origin='#{?#{@dev_origin},#{@dev_origin},#{pane_id}}'
    local create='SESSION="'"${prefix}-${key}${suffix}"'"; tmux has-session -t "=$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -c "#{pane_current_path}" "'"${cmd}"'" \; set-option -t "=$SESSION:" @dev_parent '"'"'#{session_id}'"'"' \; set-option -w -t "=$SESSION:" @dev_ws_id "'"${key}"'" \; set-option -w -t "=$SESSION:" @dev_origin "'"${origin}"'" \; set-option -w -t "=$SESSION:" @dev_popup_kind "'"${prefix}"'"'
    local show='; tmux display-popup -w 90% -h 90% -b single -T " '"${key}"' " -E "tmux attach-session -t \"=$SESSION\""'
    if [[ "$display" == nodisplay ]]; then
        print -r -- "$create"
    else
        print -r -- "${create}${show}"
    fi
}

# The session-closed hook that reaps a closed session's popups. Pure sh and
# tmux: on a sourced install `dev` is a shell function run-shell cannot see.
# `##{...}` survives the hook's own format expansion and reaches list-sessions
# intact. Each reaped popup fires the hook again, so popups of popups go too.
_dev_reaper_hook() {
    print -r -- 'run-shell "tmux list-sessions -F '"'"'##{session_id}|##{@dev_parent}'"'"' | while IFS=\"|\" read -r id parent; do [ \"\$parent\" = '"'"'#{hook_session}'"'"' ] && tmux kill-session -t \"\$id\"; done; true"'
}

# "id|parent id|name" for every session a popup key created.
_dev_popup_sessions() {
    local id parent name
    tmux list-sessions -F '#{session_id}|#{@dev_parent}|#{session_name}' 2>/dev/null |
        while IFS='|' read -r id parent name; do
            [[ -n "$parent" ]] && print -r -- "${id}|${parent}|${name}"
        done
}

# Session ids of every popup descended from the given session id.
_dev_popup_descendants() {
    local rows="$(_dev_popup_sessions)" id parent name current
    local -a queue=("$1") found
    while (( ${#queue} )); do
        current="${queue[1]}"
        shift queue
        while IFS='|' read -r id parent name; do
            [[ -n "$id" && "$parent" == "$current" ]] && found+=("$id") queue+=("$id")
        done <<< "$rows"
    done
    (( ${#found} )) && print -l -- "${found[@]}"
}

# Popups whose parent session no longer exists. Ids are never reused while
# the server lives, so a missing parent id means the parent is really gone.
_dev_orphan_popups() {
    local live=" $(tmux list-sessions -F '#{session_id}' 2>/dev/null | tr '\n' ' ') "
    local id parent name
    _dev_popup_sessions | while IFS='|' read -r id parent name; do
        [[ "$live" != *" $parent "* ]] && print -r -- "${id}|${parent}|${name}"
    done
}

# A setting as the agent popup sees it. The popup runs under the tmux server's
# environment, not the user's shell, so the values resolved when dev last bound
# its keys are published as server options and read back here.
_dev_agent_cfg() {
    local value="$(tmux show-options -gqv "@dev_cfg_$1" 2>/dev/null)"
    [[ -n "$value" ]] && print -r -- "$value" || _dev_cfg "$1"
}

_dev_publish_config() {
    local key value
    for key in ai_cmd ai_args ssh_key agent_launch_cmd; do
        value="$(_dev_cfg "$key")"
        if [[ -n "$value" ]]; then
            tmux set-option -g "@dev_cfg_${key}" "$value"
        else
            tmux set-option -gu "@dev_cfg_${key}" 2>/dev/null
        fi
    done
}

# The shell command that starts a pane's agent, built here in zsh so every
# value is quoted once, properly. A popup's pane leads back to the pane its
# workspace started from.
_dev_agent_command() {
    local pane="$1" origin
    origin="$(tmux display-message -p -t "$pane" '#{@dev_origin}' 2>/dev/null)"
    [[ -n "$origin" ]] && tmux display-message -p -t "$origin" '' &>/dev/null && pane="$origin"

    local workspace ws_id sid ai_cmd
    workspace="$(tmux display-message -p -t "$pane" '#{@dev_workspace}')"
    ws_id="$(tmux display-message -p -t "$pane" '#{@dev_ws_id}')"
    sid="$(tmux display-message -p -t "$pane" '#{@dev_agent_sid}')"
    ai_cmd="$(tmux display-message -p -t "$pane" '#{@dev_ai_cmd}')"
    [[ -n "$ai_cmd" ]] || ai_cmd="$(_dev_agent_cfg ai_cmd)"
    local ai_args="$(_dev_agent_cfg ai_args)"
    [[ -z "$ai_args" && "$ai_cmd" == claude ]] && ai_args="--enable-auto-mode"
    # Flags given to `dev agent start <ws> -- ...` for this workspace.
    local extra="$(tmux display-message -p -t "$pane" '#{@dev_agent_args}')"
    ai_args="${ai_args}${extra:+ $extra}"
    ai_args="${ai_args# }"
    local launch="$(_dev_agent_cfg agent_launch_cmd)" ssh_key="$(_dev_agent_cfg ssh_key)"

    local out=""
    [[ -n "$workspace" ]] && out+="cd ${(qq)workspace} || exit 1; "
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        out+="ssh-add ${(qq)ssh_key} 2>/dev/null; "
    elif [[ -n "$ssh_key" ]]; then
        local warning="dev: ssh key not found, skipped: ${ssh_key}"
        out+="echo ${(qq)warning} >&2; "
    fi

    if [[ -n "$launch" ]]; then
        # The user's own command, so it runs as written; only the values are
        # quoted. A failing launcher is not retried as plain claude.
        launch="${launch//\{ws\}/${(qq)ws_id}}"
        launch="${launch//\{path\}/${(qq)workspace}}"
        launch="${launch//\{sid\}/${(qq)sid}}"
        out+="$launch"
    else
        local base="${ai_cmd}${ai_args:+ $ai_args}"
        if [[ "$ai_cmd" == claude && -n "$sid" ]]; then
            # --resume first: --session-id refuses an id that already exists.
            out+="$base --resume ${(qq)sid} || $base --session-id ${(qq)sid}"
        else
            out+="$base"
        fi
    fi
    print -r -- "$out"
}

_dev_agent_exec() {
    local cmd origin
    cmd="$(_dev_agent_command "$1")" || return 1
    # Marks the workspace as having had an agent, so status can tell a dead
    # one from one never started.
    origin="$(tmux display-message -p -t "$1" '#{@dev_origin}' 2>/dev/null)"
    tmux set-option -w -t "${origin:-$1}" @dev_agent_started 1 2>/dev/null
    exec sh -c "$cmd"
}

_dev_plural() {
    (( $1 == 1 )) && print -r -- "$1 $2" || print -r -- "$1 ${2}s"
}

# Text only dev's own bindings contain, the 2.3.x ones included: a key bound
# to anything else is the user's, and dev leaves it alone.
_dev_is_dev_binding() {
    [[ "$1" == *"display-popup -w 90% -h 90% -b single"* || "$1" == *"grid add --prompt"* ||
       "$1" == *" __coordinator "* || "$1" == *" __overview "* ]]
}

# The prefix-table line binding a key, or nothing. Matched by position after
# `-T prefix`, not by column: `bind-key -r -T prefix a ...` shifts the columns,
# and a missed match would read as "free" and overwrite the user's key.
_dev_prefix_binding() {
    tmux list-keys -T prefix 2>/dev/null | awk -v k="$1" '{
        for (i = 1; i < NF - 1; i++) if ($i == "-T" && $(i+1) == "prefix") { if ($(i+2) == k) print; break }
    }'
}

_dev_prefix_binding_key() {
    print -r -- "$1" | awk '{ for (i = 1; i < NF - 1; i++) if ($i == "-T" && $(i+1) == "prefix") { print $(i+2); break } }'
}

# Binds a prefix key unless someone else holds it; reports a conflict instead.
# The full table is filtered: `list-keys -T prefix <key>` prints nothing on
# tmux 3.7b, bound or not.
_dev_bind_key() {
    local key="$1" label="$2"
    shift 2
    local current="$(_dev_prefix_binding "$key")"
    if [[ -n "$current" ]] && ! _dev_is_dev_binding "$current"; then
        local held="${current#*${key} }"
        held="${held##[[:space:]]#}"
        _dev_key_conflicts+=("${key}=${held}")
        echo -e "${YELLOW}⚠ prefix ${key} is already bound (${held}); ${label} is not bound. Set a free key with 'dev config set'.${NC}" >&2
        return 0
    fi
    tmux bind-key "$key" "$@"
}

_dev_bind_popup() {
    local key="$1" label="$2"
    shift 2
    _dev_bind_key "$key" "$label" run-shell "$(_dev_popup_script "$@")"
}

# Everything binding depends on. A new shell on an unchanged machine finds the
# same signature on the server and binds nothing; a brew upgrade, a newly
# installed lazygit or a changed setting changes it and rebinds.
_dev_binding_signature() {
    local key parts="${DEV_VERSION}|${DEV_SCRIPT}|${SHELL}"
    _dev_has_command kb && parts+="|kb"
    _dev_has_command lazygit && parts+="|lazygit"
    for key in ai_cmd ai_args ssh_key agent_launch_cmd key_agent key_term key_kb key_git key_new key_coordinator key_overview; do
        parts+="|$(_dev_cfg "$key")"
    done
    print -r -- "$parts"
}

# Pass "force" to bind even when nothing changed (dev reload, dev config set).
_dev_setup_popup_keybindings() {
    setopt localoptions extendedglob
    tmux list-sessions &>/dev/null || return 1
    local signature="$(_dev_binding_signature)"
    if [[ "$1" != force && "$(tmux show-options -gqv @dev_bind_sig 2>/dev/null)" == "$signature" ]]; then
        return 0
    fi

    # A fixed index, not -ga: -ga would append another reaper on every
    # rebind. Index 0, where a user's own hook lands, is left alone.
    tmux set-hook -g 'session-closed[99]' "$(_dev_reaper_hook)"
    _dev_publish_config

    local -A wanted=(
        key_term "$(_dev_cfg key_term)"
        key_agent "$(_dev_cfg key_agent)"
        key_new "$(_dev_cfg key_new)"
        key_kb "$(_dev_cfg key_kb)"
        key_git "$(_dev_cfg key_git)"
        key_coordinator "$(_dev_cfg key_coordinator)"
        key_overview "$(_dev_cfg key_overview)"
    )
    local -a _dev_key_conflicts
    local name seen=" " bind_status=0

    # Release keys dev bound before that are no longer configured.
    local line bound
    tmux list-keys -T prefix 2>/dev/null | while IFS= read -r line; do
        bound="$(_dev_prefix_binding_key "$line")"
        _dev_is_dev_binding "$line" || continue
        [[ " ${(v)wanted} " == *" ${bound} "* ]] || tmux unbind-key -T prefix "$bound"
    done

    for name in key_term key_agent key_new key_kb key_git key_coordinator key_overview; do
        if [[ "$seen" == *" ${wanted[$name]} "* ]]; then
            echo -e "${RED}Error: prefix ${wanted[$name]} is configured for two actions; ${name} is not bound${NC}" >&2
            wanted[$name]=""
            bind_status=1
        fi
        seen+="${wanted[$name]} "
    done

    [[ -n "${wanted[key_term]}" ]] && _dev_bind_popup "${wanted[key_term]}" Terminal term "${SHELL:-zsh}"
    if [[ -n "${wanted[key_agent]}" ]] && _dev_validate_ai_cmd; then
        _dev_bind_popup "${wanted[key_agent]}" "AI assistant" ai "zsh ${(qq)DEV_SCRIPT} __agent '#{pane_id}'" "$(_dev_cfg ai_cmd)"
    fi
    [[ -n "${wanted[key_new]}" ]] && _dev_bind_key "${wanted[key_new]}" "New branch tab" \
        display-popup -E -w 60 -h 8 -b single -T " New branch tab " \
        -d "#{pane_current_path}" zsh "$DEV_SCRIPT" grid add --prompt
    if [[ -n "${wanted[key_kb]}" ]] && _dev_has_command kb; then
        _dev_bind_popup "${wanted[key_kb]}" "Kanban board" kb kb
    fi
    [[ -n "${wanted[key_coordinator]}" ]] && _dev_bind_key "${wanted[key_coordinator]}" "Coordinator" \
        run-shell "zsh ${(qq)DEV_SCRIPT} __coordinator '#{pane_id}' '#{client_name}'"
    [[ -n "${wanted[key_overview]}" ]] && _dev_bind_key "${wanted[key_overview]}" "Overview" \
        run-shell "zsh ${(qq)DEV_SCRIPT} __overview '#{pane_id}' '#{client_name}'"
    if [[ -n "${wanted[key_git]}" ]] && _dev_has_command lazygit; then
        _dev_bind_popup "${wanted[key_git]}" "Git UI" lg lazygit
    fi

    tmux set-option -g @dev_key_conflicts "${(j:;:)_dev_key_conflicts}"
    tmux set-option -g @dev_bind_sig "$signature"
    _dev_has_command kb && _dev_has_command lazygit && (( ! bind_status ))
}

# ─── Workspace agents: dev agent start / send / status ───

# What an agent's screen says it is doing: working, idle, waiting or unknown.
# Read from claude 2.1.286's own screens (tests/fixtures/agent-screens); a
# screen that matches none is unknown, never a guessed idle. Byte patterns, so
# the multibyte spinner glyph matches in any locale.
_dev_agent_screen_state() {
    local screen="$(cat)" line prev=""
    if [[ "$screen" == *"Enter to confirm"* ]]; then
        print -r -- waiting
        return
    fi
    for line in "${(@f)screen}"; do
        # The spinner line: a glyph, then a capitalised word and an ellipsis
        # ("✶ Julienning…"); the finished form ("✻ Cooked for 2s") has none.
        if [[ "$line" =~ '^[^ ]{1,4} [A-Z][a-z]+…' ]]; then
            print -r -- working
            return
        fi
    done
    for line in "${(@f)screen}"; do
        # The input box: a rule, then the ❯ prompt.
        if [[ "$prev" == ─* && "$line" == ❯* ]]; then
            print -r -- idle
            return
        fi
        prev="$line"
    done
    print -r -- unknown
}

_dev_agent_screen_ctx() {
    local screen="$(cat)"
    [[ "$screen" =~ 'ctx:([0-9]+)%' ]] && print -r -- "${match[1]}"
}

# The first line of a question an agent is waiting on, for status and watch.
_dev_agent_screen_question() {
    local line
    for line in "${(@f)$(cat)}"; do
        line="${line##[[:space:]]##}"
        [[ "$line" == *"?"* ]] && { print -r -- "$line"; return; }
    done
}

# Sets repo and grid_session in the caller. A coordinator carries DEV_GRID, so
# its dev agent calls find their grid from any directory.
_dev_agent_grid() {
    if [[ -n "$DEV_GRID" ]]; then
        repo="$DEV_GRID"
        grid_session="$(_dev_grid_session "$repo")"
        if [[ -z "$grid_session" ]]; then
            echo -e "${RED}No grid for ${repo}${NC}"
            return 1
        fi
    else
        _dev_grid_locate
    fi
}

# The tab index a workspace is named by: its tab number, label or path.
_dev_agent_resolve() {
    local ws="$1" index name workspace
    local want_path="${ws:A}"
    local -a rows=(${(f)"$(tmux list-windows -t "=${grid_session}:" -F '#{window_index}|#{window_name}|#{@dev_workspace}')"})
    local row
    for row in "${rows[@]}"; do
        IFS='|' read -r index name workspace <<< "$row"
        if [[ -n "$workspace" && ( "$ws" == "$index" || "$ws" == "$name" || "$want_path" == "$workspace" ) ]]; then
            print -r -- "$index"
            return 0
        fi
    done
    echo -e "${RED}Error: no workspace '${ws}' in ${grid_session}. Tabs:${NC}" >&2
    for row in "${rows[@]}"; do
        IFS='|' read -r index name workspace <<< "$row"
        echo "  ${index} ${name}" >&2
    done
    return 1
}

# The session running a workspace's agent, found by stamp, never by name.
_dev_agent_session_of() {
    local ws_id="$1" name kind id
    [[ -n "$ws_id" ]] || return 1
    tmux list-windows -a -F '#{session_name}|#{@dev_popup_kind}|#{@dev_ws_id}' 2>/dev/null |
        while IFS='|' read -r name kind id; do
            [[ "$kind" == ai && "$id" == "$ws_id" ]] && { print -r -- "$name"; return 0; }
        done
    return 1
}

_dev_agent_start() {
    local ws="$1" brief=""
    shift
    local -a extra
    while (( $# )); do
        case "$1" in
            --brief) brief="$2"; shift 2 ;;
            --) shift; extra=("$@"); break ;;
            *) echo -e "${RED}Error: unknown option $1${NC}"; return 1 ;;
        esac
    done
    if [[ -z "$ws" ]]; then
        echo -e "${RED}Usage: dev agent start <tab|label|path> [--brief <file>] [-- <agent flags>]${NC}"
        return 1
    fi
    local repo grid_session index
    _dev_agent_grid || return 1
    index="$(_dev_agent_resolve "$ws")" || return 1
    local target="=${grid_session}:${index}"
    local ws_id="$(tmux show-options -w -t "$target" -qv @dev_ws_id)"
    local running
    if running="$(_dev_agent_session_of "$ws_id")"; then
        echo -e "${BLUE}Agent for tab ${index} already running (${running})${NC}"
        [[ -n "$brief" ]] && _dev_agent_send "$index" --file "$brief"
        return 0
    fi
    if (( ${#extra} )); then
        tmux set-option -w -t "$target" @dev_agent_args "${(j: :)${(qq)extra[@]}}"
    fi
    local pane="$(tmux display-message -p -t "$target" '#{pane_id}')"
    tmux run-shell -t "$pane" "$(_dev_popup_script ai "zsh ${(qq)DEV_SCRIPT} __agent '#{pane_id}'" "$(_dev_cfg ai_cmd)" nodisplay)"
    tmux set-option -w -t "$target" @dev_agent_started 1

    # A launcher that fails ends the session at once. Say so: a dead agent
    # that looks started is the silent failure this command exists to stop.
    local i
    for i in 1 2 3 4 5 6 7 8; do
        sleep 0.2
        running="$(_dev_agent_session_of "$ws_id")" || {
            echo -e "${RED}Error: the agent for tab ${index} exited as soon as it started${NC}"
            echo -e "${YELLOW}Check ai_cmd / agent_launch_cmd with 'dev config list'${NC}"
            return 1
        }
    done
    echo -e "${GREEN}✓ Agent for tab ${index} started (${running})${NC}"
    [[ -n "$brief" ]] && _dev_agent_send "$index" --file "$brief"
    return 0
}

# Whether a message reached the agent: its first characters are on screen,
# and not only in the input box. claude (and agents like it) moves a submitted
# line into the transcript and empties the prompt; text still on the last
# `❯` line was typed but not taken. Agents without a ❯ prompt only need the
# text to appear.
_dev_agent_receipt() {
    local screen="$1" snippet="$2" line last_prompt=""
    [[ "$screen" == *"$snippet"* ]] || return 1
    for line in "${(@f)screen}"; do
        [[ "$line" == ❯* ]] && last_prompt="$line"
    done
    [[ "$last_prompt" != *"$snippet"* ]]
}

_dev_agent_send() {
    local ws="$1" file="" confirm=1 timeout=15
    shift
    local -a words
    while (( $# )); do
        case "$1" in
            --file) file="$2"; shift 2 ;;
            --no-confirm) confirm=0; shift ;;
            --timeout) timeout="$2"; shift 2 ;;
            *) words+=("$1"); shift ;;
        esac
    done
    local text="${(j: :)words}"
    if [[ -z "$ws" || ( -z "$file" && -z "$text" ) ]]; then
        echo -e "${RED}Usage: dev agent send <tab|label|path> (--file <brief> | <text>) [--no-confirm] [--timeout <s>]${NC}"
        return 1
    fi
    local repo grid_session index session
    _dev_agent_grid || return 1
    index="$(_dev_agent_resolve "$ws")" || return 1
    local ws_id="$(tmux show-options -w -t "=${grid_session}:${index}" -qv @dev_ws_id)"
    # Never starts one implicitly: a brief to the wrong, fresh agent is worse
    # than an error.
    if ! session="$(_dev_agent_session_of "$ws_id")"; then
        echo -e "${RED}Error: no agent running for tab ${index}; start one with 'dev agent start ${index}'${NC}"
        return 1
    fi

    # Long or multi-line text arrives truncated when pasted into an agent's
    # input, so it goes to a file and one short line points at it.
    local line
    if [[ -n "$file" ]]; then
        if [[ ! -r "$file" ]]; then
            echo -e "${RED}Error: cannot read ${file}${NC}"
            return 1
        fi
        line="Read and follow the instructions in ${file:A}"
    elif (( ${#text} > 500 )) || [[ "$text" == *$'\n'* ]]; then
        local dir="${XDG_STATE_HOME:-$HOME/.local/state}/dev-session-manager/briefs"
        mkdir -p "$dir" || return 1
        file="${dir}/${ws_id}-$(date +%Y%m%d-%H%M%S)-$$.md"
        print -r -- "$text" > "$file" || return 1
        line="Read and follow the instructions in ${file}"
    else
        line="$text"
    fi

    local pane="$(tmux display-message -p -t "=${session}:" '#{pane_id}')"
    # Text and Enter are separate key events: text sent with its Enter in one
    # call can sit in the input box unsubmitted. Each send is checked: tmux can
    # refuse one ("no current client") and carry on.
    if ! tmux send-keys -t "$pane" -l -- "$line" || ! tmux send-keys -t "$pane" Enter; then
        echo -e "${RED}Error: could not type into tab ${index}'s agent (tmux send-keys failed)${NC}"
        return 1
    fi
    if (( ! confirm )); then
        echo -e "${YELLOW}Sent to tab ${index} (unconfirmed)${NC}"
        return 0
    fi
    local snippet="${line[1,40]}" i
    for (( i = 0; i < timeout * 4; i++ )); do
        if _dev_agent_receipt "$(tmux capture-pane -p -J -t "$pane")" "$snippet"; then
            echo -e "${GREEN}✓ Delivered to tab ${index}${NC}"
            return 0
        fi
        sleep 0.25
    done
    echo -e "${RED}✗ Not confirmed: the message did not appear in tab ${index}'s agent within ${timeout}s${NC}"
    return 1
}

_dev_json_str() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\t'/\\t}"
    value="${value//[[:cntrl:]]/}"
    print -rn -- "\"${value}\""
}

_dev_agent_status() {
    local json=0
    [[ "$1" == "--json" ]] && json=1
    local repo grid_session
    _dev_agent_grid || return 1
    local -a rows=(${(f)"$(tmux list-windows -t "=${grid_session}:" -F '#{window_index}|#{window_name}|#{@dev_workspace}|#{@dev_ws_id}|#{@dev_agent_started}')"})
    local row index name workspace ws_id started branch changes agent detail ctx session screen width=9
    for row in "${rows[@]}"; do
        name="${${row#*|}%%|*}"
        (( ${#name} > width )) && width=${#name}
    done
    (( json )) || printf "  %-3s %-${width}s  %-24s %-10s %-8s %s\n" "#" "workspace" "branch" "state" "agent" "detail"
    for row in "${rows[@]}"; do
        IFS='|' read -r index name workspace ws_id started <<< "$row"
        [[ -n "$workspace" ]] || continue
        branch="$(git -C "$workspace" branch --show-current 2>/dev/null)"
        [[ -n "$branch" ]] || branch="(detached $(git -C "$workspace" rev-parse --short HEAD 2>/dev/null))"
        changes=$(git -C "$workspace" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        detail="" ctx=""
        if session="$(_dev_agent_session_of "$ws_id")"; then
            screen="$(tmux capture-pane -p -t "=${session}:" 2>/dev/null)"
            agent="$(print -r -- "$screen" | _dev_agent_screen_state)"
            ctx="$(print -r -- "$screen" | _dev_agent_screen_ctx)"
            [[ "$agent" == waiting ]] && detail="$(print -r -- "$screen" | _dev_agent_screen_question)"
        elif [[ "$started" == 1 ]]; then
            agent=dead
        else
            agent=none
        fi
        if (( json )); then
            print -r -- "{\"tab\":${index},\"label\":$(_dev_json_str "$name"),\"path\":$(_dev_json_str "$workspace"),\"branch\":$(_dev_json_str "$branch"),\"dirty\":${changes},\"agent\":\"${agent}\",\"detail\":$(_dev_json_str "$detail"),\"ctx\":${ctx:-null}}"
        else
            (( changes )) && changes="${changes} changed" || changes="clean"
            printf "  %-3s %-${width}s  %-24s %-10s %-8s %s\n" "$index" "$name" "$branch" "$changes" "$agent" "${detail}${ctx:+ (ctx ${ctx}%)}"
        fi
    done
}

# ─── prefix S (the coordinator) and prefix O (the overview) ───

# The repo of the grid a pane belongs to: its own session's stamp, the
# coordinator's, or — inside a popup — that of the pane its workspace started
# from. Empty outside a grid.
_dev_grid_of_pane() {
    local pane="$1" repo origin
    repo="$(tmux display-message -p -t "$pane" '#{@dev_grid}' 2>/dev/null)"
    [[ -n "$repo" ]] || repo="$(tmux display-message -p -t "$pane" '#{@dev_coordinator_of}' 2>/dev/null)"
    if [[ -z "$repo" ]]; then
        origin="$(tmux display-message -p -t "$pane" '#{@dev_origin}' 2>/dev/null)"
        [[ -n "$origin" ]] && repo="$(tmux display-message -p -t "$origin" '#{@dev_grid}' 2>/dev/null)"
    fi
    print -r -- "$repo"
}

_dev_tell() {
    local client="$1" message="$2"
    if [[ -n "$client" ]]; then
        tmux display-message -c "$client" "$message"
    else
        print -r -- "$message" >&2
    fi
}

# One coordinator per grid: an ordinary agent, started in the repo root with
# DEV_GRID set so its own `dev agent ...` calls find this grid from anywhere.
# Stamped as a child of the grid, so `dev grid kill` takes it too.
_dev_coordinator() {
    local pane="$1" client="$2" repo grid_session name
    repo="$(_dev_grid_of_pane "$pane")"
    grid_session="$(_dev_grid_session "$repo")"
    if [[ -z "$repo" || -z "$grid_session" ]]; then
        _dev_tell "$client" "No grid here — run 'dev grid' in a repo first"
        return 1
    fi
    name="coord-${grid_session#${DEV_SESSION_PREFIX}}"
    if [[ "$(tmux display-message -p -t "$pane" '#{session_name}')" == "$name" ]]; then
        _dev_tell "$client" "Already in the coordinator"
        return 0
    fi
    # new-session is the lock: of two presses at once, one fails as a
    # duplicate and simply opens what the other made.
    if tmux new-session -d -s "$name" -c "$repo" -e "DEV_GRID=${repo}" 2>/dev/null; then
        tmux set-option -t "=${name}:" @dev_parent "$(tmux display-message -p -t "=${grid_session}:" '#{session_id}')"
        tmux set-option -t "=${name}:" @dev_coordinator_of "$repo"
        tmux set-option -w -t "=${name}:" @dev_workspace "$repo"
        tmux set-option -w -t "=${name}:" @dev_ws_id "$name"
        tmux set-option -w -t "=${name}:" @dev_popup_kind coordinator
        tmux set-option -w -t "=${name}:" @dev_agent_sid "$(_dev_sid_for "dev-grid:${repo}:coordinator")"
        local coord_pane="$(tmux display-message -p -t "=${name}:" '#{pane_id}')"
        tmux respawn-pane -k -t "$coord_pane" "zsh ${(qq)DEV_SCRIPT} __agent ${(qq)coord_pane}"
    fi
    [[ -n "$client" ]] && tmux display-popup -c "$client" -w 90% -h 90% -b single \
        -T " coordinator · ${grid_session} " -E "tmux attach-session -t '=${name}'"
    return 0
}

_dev_overview_popup_command() {
    print -r -- "tmux attach-session -t '=${1}'; tmux kill-session -t '=${1}'"
}

# Builds the overview of a grid's running workspace agents and prints its
# name: one read-only pane per agent, attached to the very sessions the tabs
# use. Read-only, because it is for watching; prefix a in a tab is for work.
_dev_overview_build() {
    local pane="$1" repo grid_session name ws_id agent
    repo="$(_dev_grid_of_pane "$pane")"
    grid_session="$(_dev_grid_session "$repo")"
    if [[ -z "$repo" || -z "$grid_session" ]]; then
        echo "No grid here — run 'dev grid' in a repo first" >&2
        return 1
    fi
    local -a agents
    for ws_id in ${(f)"$(tmux list-windows -t "=${grid_session}:" -F '#{@dev_ws_id}')"}; do
        agent="$(_dev_agent_session_of "$ws_id")" && agents+=("$agent")
    done
    if (( ! ${#agents} )); then
        echo "No workspace agents running in ${grid_session}" >&2
        return 1
    fi
    name="overview-${grid_session#${DEV_SESSION_PREFIX}}"
    tmux kill-session -t "=${name}" 2>/dev/null
    tmux new-session -d -s "$name" -c "$repo" "TMUX= tmux attach-session -r -t ${(qq):-=${agents[1]}}"
    for agent in "${agents[@]:1}"; do
        tmux split-window -t "=${name}:" -c "$repo" "TMUX= tmux attach-session -r -t ${(qq):-=${agent}}"
        tmux select-layout -t "=${name}:" tiled
    done
    tmux set-option -t "=${name}:" @dev_parent "$(tmux display-message -p -t "=${grid_session}:" '#{session_id}')"
    tmux set-option -t "=${name}:" @dev_overview 1
    print -r -- "$name"
}

_dev_overview() {
    local pane="$1" client="$2" name
    if ! name="$(_dev_overview_build "$pane" 2>&1)"; then
        _dev_tell "$client" "$name"
        return 1
    fi
    [[ -n "$client" ]] && tmux display-popup -c "$client" -w 95% -h 95% -b single \
        -T " overview " -E "$(_dev_overview_popup_command "$name")"
    return 0
}

# Run directly if executed (not sourced), set up keybindings if sourced
if [[ "${zsh_eval_context[-1]}" != "file" ]]; then
    dev "$@"
else
    _dev_setup_popup_keybindings
fi
