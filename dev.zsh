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
DEV_DEFAULT_DIR="${DEV_HOME_DIR:-$HOME/code}"
DEV_AI_CMD="${DEV_AI_CMD:-claude}"

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
    local -a names=(${(s:,:)${DEV_WINDOWS:-editor,server,test,shell}})
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
    tmux set-option -w -t "=${session_name}:1" @dev_workspace "${paths[1]}"
    local i
    for (( i = 2; i <= ${#paths}; i++ )); do
        tmux new-window -t "=${session_name}:${i}" -n "${paths[i]:t}" -c "${paths[i]}"
        tmux set-option -w -t "=${session_name}:${i}" @dev_workspace "${paths[i]}"
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

    # Fill the first free number rather than appending past 9: existing tabs
    # never move, and the new one stays reachable with prefix N.
    local -a used=(${(f)"$(tmux list-windows -t "=${grid_session}:" -F '#{window_index}')"})
    local free=""
    for index in {1..9}; do
        (( ${used[(Ie)$index]} )) || { free="$index"; break; }
    done
    if [[ -z "$free" ]]; then
        echo -e "${RED}Error: the grid already has 9 tabs (prefix 1-9)${NC}"
        return 1
    fi

    if [[ -z "$wt_path" ]]; then
        wt_path="$(_dev_create_worktree "$repo" "$branch")" || return 1
    fi

    tmux new-window -t "=${grid_session}:${free}" -n "${wt_path:t}" -c "$wt_path"
    tmux set-option -w -t "=${grid_session}:${free}" @dev_workspace "$wt_path"
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
    if [[ -n "$DEV_WORKTREE_CREATE_CMD" ]]; then
        local cmd="${DEV_WORKTREE_CREATE_CMD//\{branch\}/${(qq)branch}}"
        out="$(cd "$repo" && sh -c "$cmd")"
        rc=$?
        if (( rc )); then
            echo -e "${RED}Error: the create command exited ${rc}: ${DEV_WORKTREE_CREATE_CMD}${NC}" >&2
            return 1
        fi
        # An array, not ${${(f)out}[-1]}: one line of output makes that a
        # scalar, and [-1] then takes its last character.
        local -a lines=(${(f)out})
        wt_path="${lines[-1]}"
        if [[ -z "$wt_path" || ! -d "$wt_path" ]]; then
            echo -e "${RED}Error: the create command printed no existing directory: ${DEV_WORKTREE_CREATE_CMD}${NC}" >&2
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
            echo -e "  ${BLUE}dev grid${NC}           One tab per git worktree of this repo"
            echo -e "  ${BLUE}dev grid status${NC}    Each tab's branch and changes"
            echo -e "  ${BLUE}dev grid add <br>${NC}  New worktree for a branch, as a new tab"
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
            echo -e "${YELLOW}'dev <name>' windows (all start at ${DEV_DEFAULT_DIR}; set DEV_WINDOWS to change):${NC}"
            echo -e "${layout}"
            echo ""
            echo -e "${YELLOW}Popup keybindings (inside tmux):${NC}"
            echo -e "  ${BLUE}Prefix a${NC}          AI assistant (claude)"
            echo -e "  ${BLUE}Prefix k${NC}          Kanban board (kb)"
            echo -e "  ${BLUE}Prefix g${NC}          Git UI (lazygit)"
            echo -e "  ${BLUE}Prefix j${NC}          Terminal (shell)"
            echo -e "  ${BLUE}Prefix N${NC}          New branch as a grid tab"
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
                add) _dev_grid_add "$3" ;;
                *)
                    echo -e "${RED}Unknown grid command: $2${NC}"
                    echo -e "${YELLOW}Usage: dev grid [status | add <branch>]${NC}"
                    return 1
                    ;;
            esac
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
            if _dev_setup_popup_keybindings; then
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

            tmux new-session -d -s "$session_name" -n "${windows[1]}" -c "$DEV_DEFAULT_DIR"
            _dev_number_from_one "$session_name"
            local i
            for (( i = 2; i <= ${#windows}; i++ )); do
                tmux new-window -t "=${session_name}:${i}" -n "${windows[i]}" -c "$DEV_DEFAULT_DIR"
            done
            tmux select-window -t "=${session_name}:1"

            _dev_attach_session "$session_name" "Created $(_dev_plural ${#windows} window), starting at ${windows[1]}"
            ;;
    esac
}

_dev_validate_ai_cmd() {
    if [[ "$DEV_AI_CMD" == *" "* ]]; then
        echo -e "${RED}Error: DEV_AI_CMD cannot contain spaces ('${DEV_AI_CMD}')${NC}"
        return 1
    fi
    return 0
}

# The shell script a popup key runs. tmux expands its #{...} formats at key
# press time, then hands it to sh. Both names are slugged there, not here: they
# are only known at key press, and tmux keeps ':' and '.' in a session name but
# cannot target one that has them. The attach target is quoted because the -E
# payload is word-split by sh, where an unquoted name with a space breaks the
# attach.
#
# The popup is stamped with its parent's session id, in the same tmux command
# that creates it. An id, not a name: `prefix $` renames sessions, and a name
# stamp would then make every popup of a live session look orphaned. The id is
# single-quoted because sh would read `$1` as a positional parameter.
_dev_popup_script() {
    local prefix="$1" cmd="$2" suffix="${3:+-$3}"
    local slug='[^a-zA-Z0-9_-]/-/'
    print -r -- 'SESSION="'"${prefix}"'-#{s/'"${slug}"':session_name}-#{window_index}-#{s/'"${slug}"':window_name}'"${suffix}"'"; tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -c "#{pane_current_path}" "'"${cmd}"'" \; set-option -t "$SESSION" @dev_parent '"'"'#{session_id}'"'"'; tmux display-popup -w 90% -h 90% -b single -E "tmux attach-session -t \"$SESSION\""'
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

_dev_plural() {
    (( $1 == 1 )) && print -r -- "$1 $2" || print -r -- "$1 ${2}s"
}

_dev_bind_popup() {
    local key="$1"
    shift
    tmux bind-key "$key" run-shell "$(_dev_popup_script "$@")"
}

# prefix N: a new branch as a new grid tab. Bound only if the key is free or
# already ours: dev never takes a key someone else bound. The full table is
# filtered because `list-keys -T prefix N` prints nothing on tmux 3.7b, bound
# or not.
_dev_bind_new_branch_key() {
    local current="$(tmux list-keys -T prefix 2>/dev/null | awk '$4 == "N"')"
    [[ -z "$current" || "$current" == *"grid add --prompt"* ]] || return 0
    tmux bind-key N display-popup -E -w 60 -h 8 -b single -T " New branch tab " \
        -d "#{pane_current_path}" zsh "$DEV_SCRIPT" grid add --prompt
}

_dev_setup_popup_keybindings() {
    tmux list-sessions &>/dev/null || return 1
    # A fixed index, not -ga: this runs on every shell start, and -ga would
    # append another reaper each time. Index 0, where a user's own hook lands,
    # is left alone.
    tmux set-hook -g 'session-closed[99]' "$(_dev_reaper_hook)"
    _dev_bind_popup j term "${SHELL:-zsh}"
    if _dev_validate_ai_cmd; then
        _dev_bind_popup a ai "[ -f ~/.ssh/id_ed25519 ] && ssh-add ~/.ssh/id_ed25519 2>/dev/null; ${DEV_AI_CMD} --enable-auto-mode" "${DEV_AI_CMD}"
    fi
    _dev_bind_new_branch_key
    _dev_has_command kb && _dev_bind_popup k kb kb
    _dev_has_command lazygit && _dev_bind_popup g lg lazygit
}

# Run directly if executed (not sourced), set up keybindings if sourced
if [[ "${zsh_eval_context[-1]}" != "file" ]]; then
    dev "$@"
else
    _dev_setup_popup_keybindings
fi
