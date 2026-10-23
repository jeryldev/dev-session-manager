#!/usr/bin/env zsh
# Dev Session Manager
# Quick development session bootstrapping with tmux
#
# Copyright (c) 2026 Jeryl Estopace
# GitHub: https://github.com/jeryldev
# LinkedIn: https://www.linkedin.com/in/jeryldev/
# Repository: https://github.com/jeryldev/dev-session-manager

# Version
DEV_VERSION="3.5.0"

# This file, sourced or executed: key bindings run it again from tmux. Made
# absolute but not resolved: Homebrew's bin/dev is a symlink into a versioned
# Cellar directory that the next upgrade removes.
DEV_SCRIPT="${${(%):-%x}:a}"

# Configuration
DEV_SESSION_PREFIX="dev-"

# Names `dev <name>` cannot use, because they are commands. `dev help` prints
# this list, and a test runs each one to prove it really is a command.
DEV_RESERVED_NAMES=(a agent attach clean config grid h help k kill list ls reload t tmux v version)

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
    watch_cmd DEV_WATCH_CMD
    worktree_remove_cmd DEV_WORKTREE_REMOVE_CMD
    grid_cmd DEV_GRID_CMD
    key_agent DEV_KEY_AGENT
    key_term DEV_KEY_TERM
    key_kb DEV_KEY_KB
    key_git DEV_KEY_GIT
    key_new DEV_KEY_NEW
    key_coordinator DEV_KEY_COORDINATOR
    key_overview DEV_KEY_OVERVIEW
    key_remove DEV_KEY_REMOVE
    key_close DEV_KEY_CLOSE
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
    key_remove X
    key_close W
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

    # Check tmux. 3.3 is the floor: the popups use display-popup -b and -T.
    if _dev_has_command tmux; then
        local tmux_ver=$(tmux -V 2>/dev/null | cut -d' ' -f2)
        local major="${tmux_ver%%.*}" minor="${${tmux_ver#*.}%%[^0-9]*}"
        if (( major < 3 || (major == 3 && minor < 3) )); then
            echo -e "  ${RED}✗${NC} tmux ($tmux_ver) — dev needs tmux 3.3 or newer for its popups"
        else
            echo -e "  ${GREEN}✓${NC} tmux ($tmux_ver)"
        fi
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
    if [[ "$name" == __* ]]; then
        echo -e "${RED}Error: names starting with __ are reserved for dev itself${NC}"
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
    return 1
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
    print -rl -- "${names[@]}"
}

# For options that take a value: `shift 2` without one fails without
# shifting in zsh, and the option loop would never end.
_dev_need_value() {
    (( $2 >= 2 )) && return 0
    echo -e "${RED}Error: $1 needs a value${NC}" >&2
    return 1
}

# A value tmux would otherwise expand as a format (-n, -c, -T, display-message
# text): `#S` in a path became the session name and the tab opened in $HOME.
_dev_tmux_literal() {
    print -r -- "${1//\#/##}"
}

# Sets branch and changes in the caller for a workspace directory. A missing
# directory or a git that fails says so: "clean" would make a broken
# workspace look safe to remove.
_dev_workspace_git() {
    local workspace="$1" porcelain
    if [[ ! -d "$workspace" ]]; then
        branch="-" changes="missing"
        return 1
    fi
    if ! porcelain="$(git -C "$workspace" status --porcelain 2>/dev/null)"; then
        branch="-" changes="git error"
        return 1
    fi
    branch="$(git -C "$workspace" branch --show-current 2>/dev/null)"
    [[ -n "$branch" ]] || branch="(detached $(git -C "$workspace" rev-parse --short HEAD 2>/dev/null))"
    # An array: ${#${(f)x}} of a single line is its length in characters.
    local -a lines=(${(f)porcelain})
    changes=${#lines}
    return 0
}

# Free text kept in tmux options (paths, settings, commands) is stored
# hex-encoded. tmux 3.3-3.4 rewrite values on the way out — `$` comes back as
# `\$`, and in a non-UTF-8 locale every non-ASCII character as `_` — so a raw
# path or launch command would not survive the round trip. Values tmux itself
# must read in formats (workspace ids, pane and session ids) are plain ASCII and
# stay as they are. Unencoded values from older builds are read as they are.
_dev_text_set() {
    local value="${@[-1]}"
    if [[ -z "$value" ]]; then
        tmux set-option "${@[1,-2]}" ""
    else
        tmux set-option "${@[1,-2]}" "hex:$(print -rn -- "$value" | od -An -v -tx1 | tr -d ' \n')"
    fi
}

_dev_text_get() {
    local value hex out=""
    value="$(tmux show-options -qv "$@" 2>/dev/null)" || return 1
    if [[ "$value" == hex:* ]]; then
        hex="${value#hex:}"
        while [[ -n "$hex" ]]; do
            out+="\\x${hex[1,2]}"
            hex="${hex[3,-1]}"
        done
        print -rn -- "${(g::)out}"
        print
    else
        print -r -- "$value"
    fi
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

# The grid's workspaces as "path<TAB>label" lines, label possibly empty: from
# grid_cmd if configured, else the repo's .dev-grid, else git. .dev-grid is
# read as data and never executed (D7): a cloned repo must not be able to run
# code through it. A failing grid_cmd is an error, never a fall back to the
# other sources (D12) — a plausible grid from the wrong source is worse.
_dev_workspace_source() {
    local repo="$1" grid_cmd="$(_dev_cfg grid_cmd)" source="" out rc
    if [[ -n "$grid_cmd" ]]; then
        out="$(cd "$repo" && sh -c "$grid_cmd")"
        rc=$?
        if (( rc )); then
            echo -e "${RED}Error: grid_cmd exited ${rc}: ${grid_cmd}${NC}" >&2
            return 1
        fi
        if [[ -z "$out" ]]; then
            echo -e "${RED}Error: grid_cmd printed no workspaces: ${grid_cmd}${NC}" >&2
            return 1
        fi
        source="grid_cmd"
    elif [[ -f "${repo}/.dev-grid" ]]; then
        out="$(< "${repo}/.dev-grid")"
        source=".dev-grid"
    else
        local wt
        for wt in ${(f)"$(_dev_worktrees "$repo")"}; do
            print -r -- "${wt}"$'\t'
        done
        return 0
    fi
    local line entry_path label skipped=0 used=0
    for line in "${(@f)out}"; do
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        entry_path="${line%%$'\t'*}"
        [[ "$line" == *$'\t'* ]] && label="${line#*$'\t'}" || label=""
        [[ "$entry_path" == /* ]] || entry_path="${repo}/${entry_path}"
        if [[ ! -d "$entry_path" ]]; then
            echo -e "${YELLOW}⚠ Skipping ${entry_path}: not a directory (${source})${NC}" >&2
            (( skipped++ ))
            continue
        fi
        print -r -- "${entry_path:A}"$'\t'"${label}"
        (( used++ ))
    done
    if (( ! used )); then
        echo -e "${RED}Error: no usable workspaces in ${source}: $(_dev_plural $skipped entry) skipped${NC}" >&2
        return 1
    fi
}

# The source's workspaces after --filter (a substring of the label or the
# directory name) and --limit, as the grid was built with them.
_dev_workspace_entries() {
    local repo="$1" filter="$2" limit="$3" entries
    entries="$(_dev_workspace_source "$repo")" || return 1
    local -a all=(${(f)entries}) kept
    local entry name
    for entry in "${all[@]}"; do
        name="${entry#*$'\t'}"
        [[ -n "$name" ]] || name="${${entry%%$'\t'*}:t}"
        [[ -z "$filter" || "$name" == *"$filter"* || "${${entry%%$'\t'*}:t}" == *"$filter"* ]] && kept+=("$entry")
    done
    if [[ -n "$filter" ]] && (( ! ${#kept} )); then
        echo -e "${RED}Error: --filter '${filter}' matches none of the ${#all} workspaces${NC}" >&2
        return 1
    fi
    [[ -n "$limit" ]] && kept=("${kept[@]:0:$limit}")
    print -rl -- "${kept[@]}"
}

# Over the cap on a terminal: the user picks up to nine, and the choice is
# written to .dev-grid (kept out of git: it is one person's working set).
_dev_grid_select() {
    local repo="$1"
    shift
    local -a entries=("$@") picked
    local i answer token from to n
    echo -e "${YELLOW}${#entries} workspaces, but a grid holds 9 tabs (prefix 1-9):${NC}" >&2
    for (( i = 1; i <= ${#entries}; i++ )); do
        printf "  %2d) %s\n" "$i" "${${entries[i]%%$'\t'*}:t}" >&2
    done
    print -n "Pick up to 9 (e.g. 1 3 5-7): " >&2
    read -r answer || return 1
    for token in ${=answer}; do
        if [[ "$token" =~ '^([0-9]+)-([0-9]+)$' ]]; then
            from="${match[1]}" to="${match[2]}"
        elif [[ "$token" =~ '^[0-9]+$' ]]; then
            from="$token" to="$token"
        else
            echo -e "${RED}Error: '${token}' is not a number or a range${NC}" >&2
            return 1
        fi
        for (( n = from; n <= to; n++ )); do
            if (( n < 1 || n > ${#entries} )); then
                echo -e "${RED}Error: ${n} is not in 1-${#entries}${NC}" >&2
                return 1
            fi
            (( ${picked[(Ie)$n]} )) || picked+=("$n")
        done
    done
    if (( ! ${#picked} || ${#picked} > 9 )); then
        echo -e "${RED}Error: pick between 1 and 9 workspaces${NC}" >&2
        return 1
    fi
    local entry label
    : > "${repo}/.dev-grid" || return 1
    for n in "${picked[@]}"; do
        entry="${entries[n]}"
        label="${entry#*$'\t'}"
        print -r -- "${entry%%$'\t'*}${label:+$'\t'$label}" >> "${repo}/.dev-grid"
        print -r -- "$entry"
    done
    local exclude="$(git -C "$repo" rev-parse --git-path info/exclude)"
    [[ "$exclude" == /* ]] || exclude="${repo}/${exclude}"
    mkdir -p "${exclude:h}"
    grep -qx '.dev-grid' "$exclude" 2>/dev/null || print -r -- '.dev-grid' >> "$exclude"
    echo -e "${GREEN}✓ Saved to ${repo}/.dev-grid${NC}" >&2
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

# Where `dev agent reset` keeps a workspace's conversation generation: one file
# per conversation key, named by its hash, holding a number. No file is
# generation 0, the id every version before reset derived.
_dev_agent_generation_file() {
    print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/dev-session-manager/agent-generations/$(_dev_sha1 "$1")"
}

_dev_agent_generation() {
    local file="$(_dev_agent_generation_file "$1")" n=0
    [[ -r "$file" ]] && n="$(<"$file")"
    [[ "$n" == <-> ]] || n=0
    print -r -- "$n"
}

# A workspace's conversation id: derived from its key, so /exit, a reboot and
# a rebuilt grid all resume the same conversation, until a reset moves it on.
_dev_agent_sid() {
    local key="$1" n="$(_dev_agent_generation "$1")"
    (( n )) && key+="#${n}"
    _dev_sid_for "$key"
}

_dev_stamp_workspace() {
    local target="$1" wt_path="$2" repo="$3" label="$4"
    local path_hash="$(_dev_sha1 "$wt_path")"
    _dev_text_set -w -t "$target" @dev_workspace "$wt_path"
    # Kept apart from the window name, which tmux reports escaped, and
    # differently by version (3.8 doubles a backslash, 3.4 does not).
    [[ -n "$label" ]] && _dev_text_set -w -t "$target" @dev_label "$label"
    tmux set-option -w -t "$target" @dev_ws_id "$(_dev_slug "${wt_path:t}")-${path_hash[1,4]}"
    _dev_text_set -w -t "$target" @dev_agent_key "dev-grid:${repo}:${wt_path}"
    tmux set-option -w -t "$target" @dev_agent_sid "$(_dev_agent_sid "dev-grid:${repo}:${wt_path}")"
}

_dev_grid_build() {
    local repo session_name="" stamp filter="" limit=""
    while (( $# )); do
        case "$1" in
            --filter) _dev_need_value "$1" $# || return 1; filter="$2"; shift 2 ;;
            --limit) _dev_need_value "$1" $# || return 1; limit="$2"; shift 2 ;;
            --session) _dev_need_value "$1" $# || return 1; session_name="$2"; shift 2 ;;
            *) echo -e "${RED}Error: unknown option $1${NC}"; return 1 ;;
        esac
    done
    if [[ -n "$limit" && ! "$limit" =~ '^[1-9]$' ]]; then
        echo -e "${RED}Error: --limit takes 1-9 (prefix 1-9 reaches nine tabs), not '${limit}'${NC}"
        return 1
    fi
    if [[ -n "$session_name" ]] && ! _dev_validate_name "$session_name"; then
        return 1
    fi
    if ! repo="$(_dev_repo_root)"; then
        echo -e "${RED}Error: not a git repository: ${PWD}${NC}"
        return 1
    fi
    # A repo has one grid. Found by stamp, under whatever name it was built:
    # `dev` reaches a `--session` grid too, and a second one is refused.
    local -a stamped=(${(f)"$(_dev_grid_sessions "$repo")"})
    if (( ${#stamped} > 1 )); then
        _dev_grid_ambiguous "$repo" "${stamped[@]}"
        return 1
    fi
    if (( ${#stamped} == 1 )); then
        if [[ -n "$session_name" && "$session_name" != "${stamped[1]}" ]]; then
            echo -e "${RED}✗ ${repo} already has a grid: ${stamped[1]}${NC}"
            echo -e "  Open it with ${BLUE}dev grid${NC}, or close it first with ${BLUE}dev grid kill${NC}"
            return 1
        fi
        session_name="${stamped[1]}"
    fi
    [[ -n "$session_name" ]] || session_name="${DEV_SESSION_PREFIX}$(_dev_slug "${repo:t}")-grid"
    local display_name=$(_dev_display_name "$session_name")

    # The stamp, not the name, says a session is this repo's grid: `dev
    # myrepo-grid` makes a role session with exactly this name, and adopting it
    # would put `frontend` where the first workspace belongs.
    if tmux has-session -t "=${session_name}" 2>/dev/null; then
        stamp="$(_dev_text_get -t "=${session_name}:" @dev_grid)"
        if [[ "$stamp" == "$repo" ]]; then
            # Report drift, never act on it: a removed worktree's tab may hold
            # unsaved work, and new ones are added only when asked.
            local -a added removed
            local -A labels_of
            if ! _dev_grid_drift "$repo" "$session_name" 2>/dev/null; then
                echo -e "${YELLOW}⚠ Could not read the workspace list, so new or removed worktrees were not checked${NC}"
            elif (( ${#added} + ${#removed} )); then
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
            echo -e "  Or build under another name: ${BLUE}dev grid --session <name>${NC}"
        else
            echo -e "${RED}✗ '${session_name}' is the grid of ${stamp}${NC}"
            echo -e "  Remove it with ${BLUE}dev kill ${display_name}${NC}, or rename this repo's directory"
        fi
        return 1
    fi

    local entries
    entries="$(_dev_workspace_entries "$repo" "$filter" "$limit")" || return 1
    local -a picked=(${(f)entries})
    if (( ${#picked} == 0 )); then
        echo -e "${RED}Error: no usable worktrees in ${repo}${NC}"
        return 1
    fi
    # prefix 1-9 reaches nine tabs. A tenth would quietly need prefix w, and
    # building a subset nobody chose is worse than refusing — so on a terminal
    # the user chooses, and elsewhere it is an error.
    if (( ${#picked} > 9 )); then
        if [[ -t 0 ]]; then
            entries="$(_dev_grid_select "$repo" "${picked[@]}")" || return 1
            picked=(${(f)entries})
        else
            echo -e "${RED}Error: ${#picked} worktrees, but a grid holds 9 tabs (prefix 1-9)${NC}"
            echo -e "${YELLOW}Run 'dev grid' on a terminal to choose, or use --filter / --limit / a .dev-grid file${NC}"
            return 1
        fi
    fi
    local -a paths=() labels=()
    local entry
    for entry in "${picked[@]}"; do
        paths+=("${entry%%$'\t'*}")
        labels+=("${${entry#*$'\t'}:-${${entry%%$'\t'*}:t}}")
    done

    echo -e "${GREEN}Creating grid: ${display_name}${NC}"
    tmux new-session -d -s "$session_name" -n "$(_dev_tmux_literal "${labels[1]}")" -c "$(_dev_tmux_literal "${paths[1]}")"
    _dev_number_from_one "$session_name"
    _dev_text_set -t "=${session_name}:" @dev_grid "$repo"
    [[ -n "$filter" ]] && _dev_text_set -t "=${session_name}:" @dev_grid_filter "$filter"
    [[ -n "$limit" ]] && tmux set-option -t "=${session_name}:" @dev_grid_limit "$limit"
    _dev_stamp_workspace "=${session_name}:1" "${paths[1]}" "$repo" "${labels[1]}"
    local i
    for (( i = 2; i <= ${#paths}; i++ )); do
        tmux new-window -t "=${session_name}:${i}" -n "$(_dev_tmux_literal "${labels[i]}")" -c "$(_dev_tmux_literal "${paths[i]}")"
        _dev_stamp_workspace "=${session_name}:${i}" "${paths[i]}" "$repo" "${labels[i]}"
    done
    tmux select-window -t "=${session_name}:1"
    _dev_attach_session "$session_name" "Created $(_dev_plural ${#paths} tab), one per worktree"
}

# A session's windows as "id<US>index<US>workspace<US>ws id<US>agent started<US>
# name" rows. Built here rather than by one list-windows format: tmux 3.4
# rewrites control characters in format output (\x1f comes out as "\037"),
# and a printable separator can appear in a path or a name. So tmux is asked
# only for ids, numbers and the name — last, where any character is safe — and
# each option is read on its own.
# A tab's label as dev gave it, or its window name for a window dev did not
# label (made by an older dev, or by hand).
_dev_window_label() {
    local label="$(_dev_text_get -w -t "$1" @dev_label)"
    print -r -- "${label:-$2}"
}

_dev_window_table() {
    local window_id index name us=$'\x1f'
    tmux list-windows -t "=${1}:" -F '#{window_id}|#{window_index}|#{window_name}' 2>/dev/null |
        while IFS='|' read -r window_id index name; do
            print -r -- "${window_id}${us}${index}${us}$(_dev_text_get -w -t "$window_id" @dev_workspace)${us}$(tmux show-options -w -t "$window_id" -qv @dev_ws_id)${us}$(tmux show-options -w -t "$window_id" -qv @dev_agent_started)${us}$(_dev_window_label "$window_id" "$name")"
        done
}

# Every session stamped as a repo's grid — found by stamp, never by name.
_dev_grid_sessions() {
    local repo="$1" session_id name
    tmux list-sessions -F '#{session_id}|#{session_name}' 2>/dev/null |
        while IFS='|' read -r session_id name; do
            [[ "$(_dev_text_get -t "$session_id" @dev_grid)" == "$repo" ]] && print -r -- "$name"
        done
}

_dev_grid_ambiguous() {
    local repo="$1"
    shift
    echo -e "${RED}✗ More than one session is stamped as the grid of ${repo}: ${(j:, :)@}${NC}" >&2
    echo -e "${YELLOW}Close the extra one with 'dev kill <name>'${NC}" >&2
}

# The repo's one grid, or nothing; two is an error, never a guess (D15).
_dev_grid_session() {
    local -a stamped=(${(f)"$(_dev_grid_sessions "$1")"})
    if (( ${#stamped} > 1 )); then
        _dev_grid_ambiguous "$1" "${stamped[@]}"
        return 1
    fi
    print -r -- "${stamped[1]}"
}

# Sets repo and grid_session in the caller, or explains why it cannot.
_dev_grid_locate() {
    if ! repo="$(_dev_repo_root)"; then
        echo -e "${RED}Error: not a git repository: ${PWD}${NC}"
        return 1
    fi
    grid_session="$(_dev_grid_session "$repo")" || return 1
    if [[ -z "$grid_session" ]]; then
        echo -e "${RED}No grid for ${repo}${NC}"
        echo -e "${YELLOW}Run 'dev grid' to build one${NC}"
        return 1
    fi
}

_dev_grid_status() {
    local repo grid_session
    _dev_grid_locate || return 1
    local us=$'\x1f'
    local -a rows=(${(f)"$(_dev_window_table "$grid_session")"})
    local window_id index workspace ws_id started name branch changes row width=9 bwidth=6
    for row in "${rows[@]}"; do
        name="${row##*${us}}"
        (( ${#name} > width )) && width=${#name}
    done
    local -a out_rows
    for row in "${rows[@]}"; do
        IFS="$us" read -r window_id index workspace ws_id started name <<< "$row"
        if [[ -z "$workspace" ]]; then
            branch="-" changes="not a workspace"
        elif _dev_workspace_git "$workspace"; then
            (( changes )) && changes="${changes} changed" || changes="clean"
        fi
        (( ${#branch} > bwidth )) && bwidth=${#branch}
        out_rows+=("${index}${us}${name}${us}${branch}${us}${changes}")
    done
    printf "  %-3s %-${width}s  %-${bwidth}s  %s\n" "#" "workspace" "branch" "state"
    for row in "${out_rows[@]}"; do
        IFS="$us" read -r index name branch changes <<< "$row"
        printf "  %-3s %-${width}s  %-${bwidth}s  %s\n" "$index" "$name" "$branch" "$changes"
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
        local window_id ws_id started name us=$'\x1f'
        while IFS="$us" read -r window_id index workspace ws_id started name; do
            if [[ "$workspace" == "$wt_path" ]]; then
                _dev_grid_show_tab "$grid_session" "$index"
                echo -e "${BLUE}${branch} is already tab ${index}${NC}"
                return 0
            fi
        done < <(_dev_window_table "$grid_session")
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
        # It ran in the repo root, so a relative path is relative to that.
        [[ -z "$wt_path" || "$wt_path" == /* ]] || wt_path="${repo}/${wt_path}"
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
            # From the HEAD of the worktree you are in (prefix N: the current
            # tab), so a new branch starts from what you were looking at.
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
    local grid_session="$1" index="$2" wt_path="$3" repo="$4" label="${5:-${3:t}}"
    tmux new-window -d -t "=${grid_session}:${index}" -n "$(_dev_tmux_literal "$label")" -c "$(_dev_tmux_literal "$wt_path")"
    _dev_stamp_workspace "=${grid_session}:${index}" "$wt_path" "$repo" "$label"
}

# Worktrees with no tab (into `added`) and tabs whose directory is gone (into
# `removed`, as "window id<US>index<US>path"), for the caller's arrays. A tab
# outside the grid's --filter or --limit is not "removed": only a directory
# that no longer exists is. If the workspace list cannot be read, this fails
# rather than call every tab removed.
_dev_grid_drift() {
    local repo="$1" grid_session="$2" index workspace entry window_id entries us=$'\x1f'
    local filter="$(_dev_text_get -t "=${grid_session}:" @dev_grid_filter)"
    local limit="$(tmux show-options -t "=${grid_session}:" -qv @dev_grid_limit)"
    entries="$(_dev_workspace_entries "$repo" "$filter" "$limit")" || {
        echo -e "${RED}Error: could not read the workspace list; nothing changed${NC}" >&2
        return 1
    }
    local -a worktrees=() tabs=()
    labels_of=()
    for entry in ${(f)entries}; do
        worktrees+=("${entry%%$'\t'*}")
        labels_of[${entry%%$'\t'*}]="${entry#*$'\t'}"
    done
    local ws_id started name
    while IFS="$us" read -r window_id index workspace ws_id started name; do
        [[ -n "$workspace" ]] || continue
        tabs+=("$workspace")
        [[ -d "$workspace" ]] || removed+=("${window_id}${us}${index}${us}${workspace}")
    done < <(_dev_window_table "$grid_session")
    for workspace in "${worktrees[@]}"; do
        (( ${tabs[(Ie)$workspace]} )) || added+=("$workspace")
    done
}

_dev_grid_sync() {
    local dry_run=0 repo grid_session
    [[ "$1" == "--dry-run" ]] && dry_run=1
    _dev_grid_locate || return 1
    local -a added removed free=(${(f)"$(_dev_grid_free_indexes "$grid_session")"})
    local -A labels_of
    _dev_grid_drift "$repo" "$grid_session" || return 1
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
            _dev_grid_open_tab "$grid_session" "${free[i]}" "${added[i]}" "$repo" "${labels_of[${added[i]}]}"
            echo -e "${GREEN}✓ ${added[i]:t} is tab ${free[i]}${NC}"
        fi
    done
}

_dev_grid_prune() {
    local dry_run=0 repo grid_session us=$'\x1f'
    [[ "$1" == "--dry-run" ]] && dry_run=1
    _dev_grid_locate || return 1
    local -a added removed
    local -A labels_of
    _dev_grid_drift "$repo" "$grid_session" || return 1
    if (( ! ${#removed} )); then
        echo -e "${GREEN}✓ Nothing to prune${NC}"
        return 0
    fi
    local entry window_id index workspace rc=0
    for entry in "${removed[@]}"; do
        IFS="$us" read -r window_id index workspace <<< "$entry"
        if (( dry_run )); then
            echo "  would remove tab ${index} (${workspace:t})"
            continue
        fi
        if _dev_close_tab "$window_id"; then
            echo -e "${GREEN}✓ Removed tab ${index} (${workspace:t})${NC}"
        else
            echo -e "${RED}✗ Could not remove tab ${index} (${workspace:t})${NC}"
            rc=1
        fi
    done
    return $rc
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
    local popup_id
    for popup_id in "${popups[@]}"; do
        tmux kill-session -t "$popup_id" 2>/dev/null
    done
    tmux kill-session -t "$session_id"
    echo -e "${GREEN}✓ Killed ${grid_session} (and $(_dev_plural ${#popups} popup))${NC}"
}

# The popup sessions of a tab, by the workspace id its popups carry.
_dev_tab_popups() {
    local ws_id="$(tmux show-options -w -t "$1" -qv @dev_ws_id)" sid parent popup_ws
    [[ -n "$ws_id" ]] || return 0
    tmux list-windows -a -F '#{session_id}|#{@dev_parent}|#{@dev_ws_id}' |
        while IFS='|' read -r sid parent popup_ws; do
            [[ -n "$parent" && "$popup_ws" == "$ws_id" ]] && print -r -- "$sid"
        done | sort -u
}

# Closes a tab and its popups. By window id: with renumber-windows on, closing
# one tab renumbers the rest, and an index taken earlier would hit a live tab.
_dev_close_tab() {
    local window_id="$1" sid
    for sid in ${(f)"$(_dev_tab_popups "$window_id")"}; do
        tmux kill-session -t "$sid" 2>/dev/null
    done
    tmux kill-window -t "$window_id"
}

# Closes a tab and its popups but keeps its worktree, files and branch, so
# `dev grid sync` opens it again. An agent that is working, waiting for an
# answer, or whose screen dev cannot read could lose a turn, so its tab needs a
# "y" on a terminal or --force.
_dev_grid_close() {
    local ws="" dry_run=0 force=0 pane=""
    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --force) force=1; shift ;;
            --pane) _dev_need_value "$1" $# || return 1; pane="$2"; shift 2 ;;
            -*) echo -e "${RED}Error: unknown option $1${NC}"; return 1 ;;
            *) ws="$1"; shift ;;
        esac
    done
    local repo grid_session index
    if [[ -n "$pane" ]]; then
        _dev_grid_tab_of_pane "$pane" close || return 1
    else
        _dev_agent_grid || return 1
        index="$(_dev_grid_pick_tab "$ws" "close <tab|label|path> [--force] [--dry-run]")" || return 1
    fi
    local window_id="$(tmux display-message -p -t "=${grid_session}:${index}" '#{window_id}')"
    local label="$(_dev_window_label "$window_id" "$(tmux display-message -p -t "$window_id" '#{window_name}')")"
    local -a popups=(${(f)"$(_dev_tab_popups "$window_id")"})
    if (( dry_run )); then
        print -r -- "  would close tab ${index} (${label}) and $(_dev_plural ${#popups} popup); the worktree is kept"
        return 0
    fi
    local doing
    case "$(_dev_tab_agent_state "$window_id")" in
        working) doing="is working" ;;
        waiting) doing="is waiting for an answer" ;;
        # Only Claude's screen is read: another tool's agent may be mid-turn.
        unknown) doing="is running, and dev cannot tell whether it is busy" ;;
    esac
    if [[ -n "$doing" ]] && (( ! force )); then
        if [[ ! -t 0 ]]; then
            echo -e "${RED}Not closing tab ${index}: its agent ${doing}. Pass --force to stop it${NC}"
            return 1
        fi
        local answer
        print -r -- "Tab ${index} (${label}): its agent ${doing}, and closing stops it"
        print -n "Type y to close, anything else to keep it: "
        read -r answer
        if [[ "$answer" != (y|Y|yes) ]]; then
            print -r -- "Kept."
            return 0
        fi
    fi
    # Printed first: run in the tab it closes, dev goes with it.
    echo -e "${GREEN}✓ Closed tab ${index} (${label}); its worktree is kept, and 'dev grid sync' opens it again${NC}"
    _dev_close_tab "$window_id"
}

# What a tab's agent is doing, as dev agent status reads it, or none.
_dev_tab_agent_state() {
    local session
    if session="$(_dev_agent_session_of "$(tmux show-options -w -t "$1" -qv @dev_ws_id)")"; then
        tmux capture-pane -p -t "=${session}:" 2>/dev/null | _dev_agent_screen_state
    else
        print -r -- none
    fi
}

# For a key pressed in a tab: sets repo, grid_session and index in the caller,
# or refuses a pane that is not a grid tab (a popup's, for one).
_dev_grid_tab_of_pane() {
    local pane="$1" verb="$2"
    repo="$(_dev_grid_of_pane "$pane")"
    grid_session="$(_dev_grid_session "$repo")"
    if [[ -z "$repo" || -z "$grid_session" || "$(tmux display-message -p -t "$pane" '#{session_name}')" != "$grid_session" ]]; then
        echo -e "${RED}Error: not a grid tab — press it in the tab you want to ${verb}${NC}"
        return 1
    fi
    index="$(tmux display-message -p -t "$pane" '#{window_index}')"
}

# The tab a grid command acts on: the one named, or else the tab it is run in.
# Reads grid_session from the caller.
_dev_grid_pick_tab() {
    local ws="$1" usage="$2"
    if [[ -n "$ws" ]]; then
        _dev_agent_resolve "$ws"
    elif [[ -n "$TMUX_PANE" && "$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}')" == "$grid_session" ]]; then
        tmux display-message -p -t "$TMUX_PANE" '#{window_index}'
    else
        echo -e "${RED}Usage: dev grid ${usage}${NC}" >&2
        return 1
    fi
}

# Removes a workspace: its worktree (through worktree_remove_cmd if set, which
# can also drop a database), then its tab and popups. Never the main checkout,
# never a workspace with uncommitted changes without --force, never anything
# without a "y" on a terminal or --yes elsewhere. The branch is kept: deleting
# commits stays a deliberate `git branch -d`.
_dev_grid_remove() {
    local ws="" force=0 dry_run=0 yes=0 pane=""
    while (( $# )); do
        case "$1" in
            --force) force=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            --yes) yes=1; shift ;;
            --pane) _dev_need_value "$1" $# || return 1; pane="$2"; shift 2 ;;
            -*) echo -e "${RED}Error: unknown option $1${NC}"; return 1 ;;
            *) ws="$1"; shift ;;
        esac
    done
    local repo grid_session index
    if [[ -n "$pane" ]]; then
        # prefix X: the tab the key was pressed in.
        _dev_grid_tab_of_pane "$pane" remove || return 1
    else
        _dev_agent_grid || return 1
        index="$(_dev_grid_pick_tab "$ws" "remove <tab|label|path> [--force] [--dry-run] [--yes]")" || return 1
    fi

    local window_id="$(tmux display-message -p -t "=${grid_session}:${index}" '#{window_id}')"
    local workspace="$(_dev_text_get -w -t "$window_id" @dev_workspace)"
    local label="$(_dev_window_label "$window_id" "$(tmux display-message -p -t "$window_id" '#{window_name}')")"
    if [[ -z "$workspace" ]]; then
        echo -e "${RED}Error: tab ${index} is not a workspace${NC}"
        return 1
    fi
    if [[ "$workspace" == "$repo" ]]; then
        echo -e "${RED}Error: tab ${index} is the main checkout, which dev never removes${NC}"
        return 1
    fi

    local branch changes gone=0
    if [[ ! -d "$workspace" ]]; then
        gone=1
    elif ! _dev_workspace_git "$workspace"; then
        changes="unknown"
    fi
    local dirty=0
    [[ "$gone" == 0 && ( "$changes" != 0 ) ]] && dirty=1
    local remove_cmd="$(_dev_cfg worktree_remove_cmd)"

    print -r -- "Remove tab ${index} (${label})"
    if (( gone )); then
        print -r -- "  ${workspace} no longer exists; only the tab closes"
    else
        print -r -- "  worktree:  ${workspace}"
        print -r -- "  removed by: ${remove_cmd:-git worktree remove}"
        [[ "$branch" == "("* || -z "$branch" ]] || print -r -- "  branch ${branch} is kept"
        if (( dirty )); then
            print -r -- "  ${changes} uncommitted change(s) would be lost"
        fi
    fi
    print -r -- "  its tab, agent and popups close"
    if (( dirty && ! force )); then
        echo -e "${RED}Refusing: tab ${index} has uncommitted changes. Commit or stash them, or pass --force${NC}"
        return 1
    fi
    if (( dry_run )); then
        print -r -- "(dry run: would remove tab ${index}; nothing changed)"
        return 0
    fi
    if (( ! yes )); then
        if [[ ! -t 0 ]]; then
            echo -e "${RED}Not removing without confirmation: pass --yes${NC}"
            return 1
        fi
        local answer
        print -n "Type y to remove, anything else to keep it: "
        read -r answer
        if [[ "$answer" != (y|Y|yes) ]]; then
            print -r -- "Kept."
            return 0
        fi
    fi

    if (( gone )); then
        git -C "$repo" worktree prune 2>/dev/null
    elif [[ -n "$remove_cmd" ]]; then
        local cmd="${remove_cmd//\{path\}/${(qq)workspace}}"
        # A detached worktree has no branch; "(detached abc123)" is display text.
        local real_branch="$branch"
        [[ "$branch" == "("* ]] && real_branch=""
        cmd="${cmd//\{branch\}/${(qq)real_branch}}"
        cmd="${cmd//\{force\}/${${force:#0}:+--force}}"
        (cd "$repo" && sh -c "$cmd")
        local rc=$?
        if (( rc )); then
            echo -e "${RED}Error: the remove command exited ${rc}: ${remove_cmd}${NC}"
            echo -e "${YELLOW}Tab ${index} is kept${NC}"
            return 1
        fi
    else
        local -a git_force=()
        (( force )) && git_force=(--force)
        if ! git -C "$repo" worktree remove "${git_force[@]}" "$workspace"; then
            echo -e "${YELLOW}Tab ${index} is kept${NC}"
            return 1
        fi
    fi

    # The worktree is gone: its popups and tab go with it.
    _dev_close_tab "$window_id"
    echo -e "${GREEN}✓ Removed tab ${index} (${label})${NC}"
}

# What prefix X and W run in their popup (a grid command and its arguments): on
# failure it stays open long enough to read.
_dev_grid_key_prompt() {
    "$@"
    local rc=$?
    if (( rc )) && [[ -t 0 ]]; then
        print -n "Press Enter to close "
        read -r
    fi
    return $rc
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
            echo -e "  ${BLUE}dev config set <k> <v>${NC}  Change a setting (also: get <k>, unset <k>, path)"
            echo -e "  ${BLUE}dev agent status${NC}   Each grid tab's agent: working, idle, waiting, dead (--json)"
            echo -e "  ${BLUE}dev agent start <t>${NC} Start tab t's agent (the one prefix a opens)"
            echo -e "  ${BLUE}dev agent send <t>${NC}  Brief tab t's agent and confirm it arrived"
            echo -e "  ${BLUE}dev agent watch${NC}    One line per agent change (--notify --json --for <s>)"
            echo -e "  ${BLUE}dev agent reset <t>${NC} Tab t's next agent starts a new conversation (--force)"
            echo -e "  ${BLUE}dev agent dashboard${NC} The prefix O dashboard, in this terminal"
            echo -e "  ${BLUE}dev grid${NC}           One tab per git worktree of this repo"
            echo -e "                     (--filter <text>  --limit <1-9>  --session <name>)"
            echo -e "  ${BLUE}dev grid status${NC}    Each tab's branch and changes"
            echo -e "  ${BLUE}dev grid add <br>${NC}  New worktree for a branch, as a new tab"
            echo -e "  ${BLUE}dev grid close <t>${NC}  Close tab t and its popups; keep its worktree"
            echo -e "  ${BLUE}dev grid remove <t>${NC} Delete tab t's worktree, close the tab (asks first)"
            echo -e "  ${BLUE}dev grid sync${NC}      Add tabs for new worktrees (--dry-run)"
            echo -e "  ${BLUE}dev grid prune${NC}     Remove tabs of removed worktrees (--dry-run)"
            echo -e "  ${BLUE}dev grid kill${NC}      Close the grid and its popups (--dry-run)"
            echo -e "  ${BLUE}dev reload${NC}         Reload popup keybindings"
            echo -e "  ${BLUE}dev help${NC}           Show this help"
            echo -e "  ${BLUE}dev tmux${NC}           Show tmux commands reference"
            echo -e "  ${BLUE}dev version${NC}        Show version"
            echo ""
            echo -e "Reserved names (not usable as session names): ${DEV_RESERVED_NAMES[*]}"
            echo -e "${BLUE}Tip: 'dev attach <name>' reaches a session whose name is one of these${NC}"
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
            local conflicts="$(_dev_text_get -g @dev_key_conflicts)" setting k label held
            for setting label in key_agent "AI assistant ($(_dev_cfg ai_cmd))" key_kb "Kanban board (kb)" \
                    key_git "Git UI (lazygit)" key_term "Terminal (shell)" key_new "New branch as a grid tab" \
                    key_coordinator "Grid coordinator agent" key_overview "Dashboard: every tab, its agent's state" \
                    key_remove "Remove this tab's worktree (asks first)" \
                    key_close "Close this tab, keep its worktree"; do
                k="$(_dev_cfg "$setting")"
                held=""
                [[ ";${conflicts};" == *";${k}="* ]] && held="${${conflicts#*${k}=}%%;*}"
                if [[ -n "$held" ]]; then
                    printf "  ${BLUE}%-17s${NC} %s ${YELLOW}(not bound: taken by %s; dev config set %s <key>)${NC}\n" "Prefix ${k}" "$label" "$held" "$setting"
                else
                    printf "  ${BLUE}%-17s${NC} %s\n" "Prefix ${k}" "$label"
                fi
            done
            printf "  ${BLUE}%-17s${NC} %s\n" "Prefix 1-9" "Tab N; inside an agent or the coordinator, tab N's agent"
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
                ""|--*) shift; _dev_grid_build "$@" ;;
                status) _dev_grid_status ;;
                sync) _dev_grid_sync "$3" ;;
                prune) _dev_grid_prune "$3" ;;
                kill) _dev_grid_kill "$3" ;;
                close|remove)
                    local grid_fn="_dev_grid_$2"
                    shift 2
                    if [[ "$1" == --pane && "$#" -eq 2 ]]; then
                        _dev_grid_key_prompt "$grid_fn" "$@"
                    else
                        "$grid_fn" "$@"
                    fi
                    ;;
                add) _dev_grid_add "$3" ;;
                *)
                    echo -e "${RED}Unknown grid command: $2${NC}"
                    echo -e "${YELLOW}Usage: dev grid [status | add <branch> | close [<tab>] | remove [<tab>] | sync | prune | kill] [--dry-run]${NC}"
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
                reset) shift 2; _dev_agent_reset "$@" ;;
                send) shift 2; _dev_agent_send "$@" ;;
                status) _dev_agent_status "$3" ;;
                watch) shift 2; _dev_agent_watch "$@" ;;
                overview|dashboard)
                    local here="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}"
                    _dev_dashboard "$here" "$(tmux display-message -p '#{client_name}' 2>/dev/null)"
                    ;;
                *)
                    echo -e "${RED}Usage: dev agent start|send|status|watch|reset|dashboard ...${NC}"
                    return 1
                    ;;
            esac
            ;;

        # Keys run these through run-shell, and tmux shows a non-zero exit as
        # "... returned 1" over the user's window; the message already said why.
        __coordinator)
            _dev_coordinator "$2" "$3" || true
            ;;

        # __overview: what 3.0.0's prefix O ran, until the key is rebound.
        __dashboard|__overview)
            _dev_dashboard "$2" "$3" || true
            ;;

        __dialog) shift; _dev_dialog "$@" ;;

        # A popup key pressed inside another dev popup, and what opens after.
        __hop) _dev_hop "$2" "$3" "$4" || true ;;
        __popup) _dev_popup_open "$2" "$3" "$4" ;;

        # What prefix 1-9 runs inside an agent popup or the coordinator.
        __switch)
            _dev_switch_agent "$2" "$3" "$4" || true
            ;;

        __in)
            _dev_popup_in "$2" "$3"
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
                _dev_has_command kb || echo -e "${YELLOW}  kb is not installed, so prefix $(_dev_cfg key_kb) is not bound${NC}"
                _dev_has_command lazygit || echo -e "${YELLOW}  lazygit is not installed, so prefix $(_dev_cfg key_git) is not bound${NC}"
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
            echo -e "${YELLOW}Dev popups and grid keys (default keys; dev help shows yours):${NC}"
            echo -e "  ${BLUE}Prefix a${NC}          AI assistant popup (/exit stops it; prefix a resumes it)"
            echo -e "  ${BLUE}Prefix k${NC}          Kanban board popup"
            echo -e "  ${BLUE}Prefix g${NC}          Git UI popup"
            echo -e "  ${BLUE}Prefix j${NC}          Terminal popup"
            echo -e "  ${BLUE}Prefix 1-9${NC}        Tab N; inside an agent popup, tab N's agent"
            echo -e "  ${BLUE}Prefix N${NC}          New branch as a grid tab"
            echo -e "  ${BLUE}Prefix X${NC}          Remove this tab's worktree (asks first)"
            echo -e "  ${BLUE}Prefix W${NC}          Close this tab, keep its worktree"
            echo -e "  ${BLUE}Prefix S${NC}          The grid's coordinator agent"
            echo -e "  ${BLUE}Prefix O${NC}          Dashboard: the grid as a tree of its agents"
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

# The popup key's name for the pane it is pressed in: the tab's workspace id
# in a grid, else the session, window index and window name.
_dev_popup_key_format() {
    local slug='[^a-zA-Z0-9_-]/-/'
    print -r -- '#{?#{@dev_ws_id},#{@dev_ws_id},#{s/'"${slug}"':session_name}-#{window_index}-#{s/'"${slug}"':window_name}}'
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
# The popup starts through `dev __in <pane id>`, which reads the pane's
# directory from tmux as data and changes to it: a directory name never passes
# through sh (a repo can name one `x$(cmd)` via .dev-grid) or through tmux's
# format expansion (`#S` in a -c path became the session name).
_dev_popup_script() {
    local prefix="$1" cmd="$2" suffix="${3:+-$3}" display="${4:-display}"
    local key="$(_dev_popup_key_format)"
    local origin='#{?#{@dev_origin},#{@dev_origin},#{pane_id}}'
    local create='SESSION="'"${prefix}-${key}${suffix}"'"; tmux has-session -t "=$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" "zsh '"${(qq)DEV_SCRIPT}"' __in #{pane_id} '"${(qq)cmd}"'" \; set-option -t "=$SESSION:" @dev_parent '"'"'#{session_id}'"'"' \; set-option -w -t "=$SESSION:" @dev_ws_id "'"${key}"'" \; set-option -w -t "=$SESSION:" @dev_origin "'"${origin}"'" \; set-option -w -t "=$SESSION:" @dev_popup_kind "'"${prefix}"'"'
    # Pressed inside the very popup it would open: showing it again would nest
    # the session inside itself, one more detach to get out. q: makes the
    # session name a safe sh word whatever it contains.
    local show='; if [ #{q:session_name} = "$SESSION" ]; then tmux display-message "Already in this popup"; else tmux display-popup -w 90% -h 90% -b single -T " '"${key}"' " -E "tmux attach-session -t \"=$SESSION\""; fi'
    # Pressed inside another dev popup: dev closes that one and opens this one
    # in its place, never as a popup inside the popup.
    local hop='if [ -n "#{?#{@dev_parent},1,}" ]; then exec zsh '"${(qq)DEV_SCRIPT}"' __hop '"${prefix}"' '"'"'#{client_name}'"'"' '"'"'#{session_id}'"'"'; fi; '
    if [[ "$display" == nodisplay ]]; then
        print -r -- "$create"
    else
        print -r -- "${hop}${create}${show}"
    fi
}

# What each popup key runs: its command, then the suffix of its session name.
_dev_popup_spec() {
    case "$1" in
        term) print -rl -- "${SHELL:-zsh}" "" ;;
        ai) print -rl -- "zsh ${(qq)DEV_SCRIPT} __agent '#{pane_id}'" "$(_dev_agent_cfg ai_cmd)" ;;
        kb) print -rl -- kb "" ;;
        lg) print -rl -- lazygit "" ;;
        *) return 1 ;;
    esac
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
    (( ${#found} )) && print -rl -- "${found[@]}"
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
    local value="$(_dev_text_get -g "@dev_cfg_$1")"
    [[ -n "$value" ]] && print -r -- "$value" || _dev_cfg "$1"
}

_dev_publish_config() {
    local key value
    for key in ai_cmd ai_args ssh_key agent_launch_cmd; do
        value="$(_dev_cfg "$key")"
        if [[ -n "$value" ]]; then
            _dev_text_set -g "@dev_cfg_${key}" "$value"
        else
            tmux set-option -gu "@dev_cfg_${key}" 2>/dev/null
        fi
    done
}

# The shell command that starts a pane's agent, built here in zsh so every
# value is quoted once, properly. A popup's pane leads back to the pane its
# workspace started from.
_dev_agent_command() {
    local pane="$1" origin from_popup=0
    origin="$(_dev_agent_origin "$pane")"
    [[ "$origin" != "$pane" ]] && from_popup=1
    pane="$origin"

    local workspace ws_id sid ai_cmd
    workspace="$(_dev_text_get -w -t "$pane" @dev_workspace)"
    ws_id="$(tmux display-message -p -t "$pane" '#{@dev_ws_id}')"
    sid="$(tmux display-message -p -t "$pane" '#{@dev_agent_sid}')"
    # A popup opened from the coordinator is a separate agent: resuming the
    # coordinator's id would put two processes in one conversation.
    if (( from_popup )) && [[ "$(tmux display-message -p -t "$pane" '#{@dev_popup_kind}')" == coordinator ]]; then
        sid=""
    fi
    ai_cmd="$(tmux display-message -p -t "$pane" '#{@dev_ai_cmd}')"
    [[ -n "$ai_cmd" ]] || ai_cmd="$(_dev_agent_cfg ai_cmd)"
    local ai_args="$(_dev_agent_cfg ai_args)"
    [[ -z "$ai_args" && "$ai_cmd" == claude ]] && ai_args="--enable-auto-mode"
    # Flags given to `dev agent start <ws> -- ...` for this workspace.
    local extra="$(_dev_text_get -w -t "$pane" @dev_agent_args)"
    ai_args="${ai_args}${extra:+ $extra}"
    ai_args="${ai_args# }"
    local launch="$(_dev_agent_cfg agent_launch_cmd)" ssh_key="$(_dev_agent_cfg ssh_key)"

    local out=""
    [[ -n "$workspace" ]] && out+="cd ${(qq)workspace} || exit 1; "
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        local failed="dev: ssh-add failed for ${ssh_key}"
        out+="ssh-add ${(qq)ssh_key} || echo ${(qq)failed} >&2; "
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
            # The first time there is nothing to resume, and claude says so in
            # red above the new conversation; that is kept aside and shown only
            # if starting the conversation fails too.
            local err="${TMPDIR:-/tmp}/dev-resume-${sid}.err"
            out+="$base --resume ${(qq)sid} 2>${(qq)err} || $base --session-id ${(qq)sid} || cat ${(qq)err} >&2"
        else
            out+="$base"
        fi
    fi
    print -r -- "$out"
}

# display-message -t on a pane that is gone still exits 0 (tmux 3.7b), so ask
# which pane it resolved to.
_dev_pane_exists() {
    [[ -n "$1" && "$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null)" == "$1" ]]
}

# The pane a workspace's popups lead back to: the popup's @dev_origin while
# that pane lives, else the grid tab carrying the same workspace id (the tab
# was re-created), else the pane itself.
_dev_agent_origin() {
    local pane="$1" origin ws_id window_id id us=$'\x1f'
    origin="$(tmux display-message -p -t "$pane" '#{@dev_origin}' 2>/dev/null)"
    if [[ -n "$origin" ]] && _dev_pane_exists "$origin"; then
        print -r -- "$origin"
        return
    fi
    ws_id="$(tmux display-message -p -t "$pane" '#{@dev_ws_id}' 2>/dev/null)"
    if [[ -n "$origin" && -n "$ws_id" ]]; then
        while IFS='|' read -r window_id id; do
            if [[ "$id" == "$ws_id" ]] && [[ -n "$(_dev_text_get -w -t "$window_id" @dev_workspace)" ]]; then
                tmux display-message -p -t "$window_id" '#{pane_id}'
                return
            fi
        done < <(tmux list-windows -a -F '#{window_id}|#{@dev_ws_id}')
    fi
    print -r -- "$pane"
}

# What a popup runs: change directory, then run the popup's tool. In a grid
# tab that is the tab's workspace, as for its agent: the popup is named after
# the workspace, and a shell that cd'd into another project must not make this
# tab's lazygit that project's from then on. Elsewhere it is where the key was
# pressed. Both are read from tmux as data.
_dev_popup_in() {
    local pane="$1" cmd="$2" dir
    dir="$(_dev_text_get -w -t "$(_dev_agent_origin "$pane")" @dev_workspace)"
    [[ -n "$dir" && -d "$dir" ]] || dir="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
    [[ -n "$dir" ]] && cd -- "$dir" 2>/dev/null
    exec sh -c "$cmd"
}

_dev_agent_exec() {
    local cmd origin rc
    cmd="$(_dev_agent_command "$1")" || return 1
    # Marks the workspace as having had an agent, so status can tell a dead
    # one from one never started; and records which pane is the agent's, so a
    # brief never lands in a shell split beside it.
    origin="$(_dev_agent_origin "$1")"
    tmux set-option -w -t "$origin" @dev_agent_started 1 2>/dev/null
    [[ -n "$TMUX_PANE" ]] && tmux set-option -t "$TMUX_PANE" @dev_agent_pane "$TMUX_PANE" 2>/dev/null
    sh -c "$cmd"
    rc=$?
    # A popup closes the moment its command ends; a failed launch would flash
    # and vanish. Keep the error on screen, and leave a mark `dev agent start`
    # can read.
    if (( rc )); then
        [[ -n "$TMUX_PANE" ]] && tmux set-option -t "$TMUX_PANE" @dev_agent_exit "$rc" 2>/dev/null
        print -r -- "dev: the agent exited with status ${rc}. Press Enter to close."
        read -r
    fi
    return $rc
}

_dev_plural() {
    (( $1 == 1 )) && print -r -- "$1 $2" || print -r -- "$1 ${2}s"
}

# Text only dev's own bindings contain, the 2.3.x ones included: a key bound
# to anything else is the user's, and dev leaves it alone.
# Popup flags alone are not enough: a user's own popup keys can use the same
# ones, so dev's popup scripts are recognised by their SESSION= line as well.
_dev_is_dev_binding() {
    [[ ( "$1" == *"display-popup -w 90% -h 90% -b single"* && "$1" == *'SESSION='* ) ||
       "$1" == *"grid add --prompt"* || "$1" == *"grid remove --pane"* ||
       "$1" == *" __coordinator "* || "$1" == *" __overview "* || "$1" == *" __dashboard "* ||
       "$1" == *" __switch "* || "$1" == *" __dialog "* ]]
}

# tmux's own bindings that dev may replace, as tmux prints them: prefix 1-9
# (dev's digits still select the tab outside a popup), and tmux 3.8's prefix g,
# its floating-pane move menu, which came after dev's git popup had g.
_dev_is_stock_binding() {
    [[ ( "$1" == [1-9] && "$2" == *"select-window -t :=$1" ) ||
       ( "$1" == g && "$2" == *"switch-client -T move" ) ]]
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
    if [[ -n "$current" ]] && ! _dev_is_dev_binding "$current" && ! _dev_is_stock_binding "$key" "$current"; then
        local held="${current#*${key} }"
        held="${held##[[:space:]]#}"
        _dev_key_conflicts+=("${key}=${held}")
        echo -e "${YELLOW}⚠ prefix ${key} is already bound (${held}); ${label} is not bound. Set a free key with 'dev config set'.${NC}" >&2
        return 0
    fi
    tmux bind-key "$key" "$@"
}

_dev_bind_popup() {
    local key="$1" label="$2" prefix="$3"
    local -a spec=("${(@f)$(_dev_popup_spec "$prefix")}")
    _dev_bind_key "$key" "$label" run-shell "$(_dev_popup_script "$prefix" "${spec[1]}" "${spec[2]}")"
}

# Everything binding depends on. A new shell on an unchanged machine finds the
# same signature on the server and binds nothing; a brew upgrade, a newly
# installed lazygit or a changed setting changes it and rebinds.
# Bump when what a key runs or how it looks changes, so a running tmux server
# picks the change up on the next shell, not only after `dev reload`.
_DEV_BINDINGS_REV=9

_dev_binding_signature() {
    local key parts="${DEV_VERSION}|${_DEV_BINDINGS_REV}|${DEV_SCRIPT}|${SHELL}"
    _dev_has_command kb && parts+="|kb"
    _dev_has_command lazygit && parts+="|lazygit"
    for key in ai_cmd ai_args ssh_key agent_launch_cmd key_agent key_term key_kb key_git key_new key_coordinator key_overview key_remove key_close; do
        parts+="|$(_dev_cfg "$key")"
    done
    print -r -- "$parts"
}

# Pass "force" to bind even when nothing changed (dev reload, dev config set).
_dev_setup_popup_keybindings() {
    setopt localoptions extendedglob
    tmux list-sessions &>/dev/null || return 1
    # Hashed: the raw signature holds settings tmux 3.4 would rewrite on read.
    local signature="$(_dev_binding_signature | cksum | tr -d ' ')"
    if [[ "$1" != force && "$(tmux show-options -gqv @dev_bind_sig 2>/dev/null)" == "$signature" ]]; then
        return 0
    fi

    # A fixed index, not -ga: -ga would append another reaper on every
    # rebind. Index 0, where a user's own hook lands, is left alone.
    tmux set-hook -g 'session-closed[99]' "$(_dev_reaper_hook)"
    # A dev popup is one pane: a split or a window made in one, by any key or
    # command, is undone at once. Its own keys open other popups in its place.
    tmux set-hook -g 'after-split-window[98]' "if -F '#{@dev_parent}' 'kill-pane'"
    tmux set-hook -g 'after-new-window[98]' "if -F '#{@dev_parent}' 'kill-window'"
    _dev_publish_config

    local -A wanted=(
        key_term "$(_dev_cfg key_term)"
        key_agent "$(_dev_cfg key_agent)"
        key_new "$(_dev_cfg key_new)"
        key_kb "$(_dev_cfg key_kb)"
        key_git "$(_dev_cfg key_git)"
        key_coordinator "$(_dev_cfg key_coordinator)"
        key_overview "$(_dev_cfg key_overview)"
        key_remove "$(_dev_cfg key_remove)"
        key_close "$(_dev_cfg key_close)"
    )
    local -a _dev_key_conflicts
    local name seen=" " bind_status=0

    # Release keys dev bound before that are no longer configured.
    local line bound
    tmux list-keys -T prefix 2>/dev/null | while IFS= read -r line; do
        bound="$(_dev_prefix_binding_key "$line")"
        _dev_is_dev_binding "$line" || continue
        # The digits are always dev's once bound; unbinding one would lose the tab.
        [[ "$bound" == [1-9] ]] && continue
        [[ " ${(v)wanted} " == *" ${bound} "* ]] || tmux unbind-key -T prefix "$bound"
    done

    for name in key_term key_agent key_new key_kb key_git key_coordinator key_overview key_remove key_close; do
        if [[ "$seen" == *" ${wanted[$name]} "* ]]; then
            echo -e "${RED}Error: prefix ${wanted[$name]} is configured for two actions; ${name} is not bound${NC}" >&2
            wanted[$name]=""
            bind_status=1
        fi
        seen+="${wanted[$name]} "
    done

    [[ -n "${wanted[key_term]}" ]] && _dev_bind_popup "${wanted[key_term]}" Terminal term
    if [[ -n "${wanted[key_agent]}" ]]; then
        if _dev_validate_ai_cmd; then
            _dev_bind_popup "${wanted[key_agent]}" "AI assistant" ai
        else
            bind_status=1
        fi
    fi
    [[ -n "${wanted[key_new]}" ]] && _dev_bind_key "${wanted[key_new]}" "New branch tab" \
        run-shell "zsh ${(qq)DEV_SCRIPT} __dialog '#{client_name}' '#{pane_id}' 'New branch tab' 90% zsh ${(qq)DEV_SCRIPT} grid add --prompt"
    if [[ -n "${wanted[key_kb]}" ]] && _dev_has_command kb; then
        _dev_bind_popup "${wanted[key_kb]}" "Kanban board" kb
    fi
    [[ -n "${wanted[key_coordinator]}" ]] && _dev_bind_key "${wanted[key_coordinator]}" "Coordinator" \
        run-shell "zsh ${(qq)DEV_SCRIPT} __coordinator '#{pane_id}' '#{client_name}'"
    # Through run-shell: it expands #{pane_id} to the pane the key was pressed
    # in, which display-popup's own command arguments do not.
    [[ -n "${wanted[key_remove]}" ]] && _dev_bind_key "${wanted[key_remove]}" "Remove this tab" \
        run-shell "zsh ${(qq)DEV_SCRIPT} __dialog '#{client_name}' '#{pane_id}' 'Remove this tab' 90% zsh ${(qq)DEV_SCRIPT} grid remove --pane '#{pane_id}'"
    [[ -n "${wanted[key_close]}" ]] && _dev_bind_key "${wanted[key_close]}" "Close this tab" \
        run-shell "zsh ${(qq)DEV_SCRIPT} __dialog '#{client_name}' '#{pane_id}' 'Close this tab' 90% zsh ${(qq)DEV_SCRIPT} grid close --pane '#{pane_id}'"
    [[ -n "${wanted[key_overview]}" ]] && _dev_bind_key "${wanted[key_overview]}" "Dashboard" \
        run-shell "zsh ${(qq)DEV_SCRIPT} __dialog '#{client_name}' '#{pane_id}' dashboard 95% zsh ${(qq)DEV_SCRIPT} __dashboard '#{pane_id}' '#{client_name}'"
    if [[ -n "${wanted[key_git]}" ]] && _dev_has_command lazygit; then
        _dev_bind_popup "${wanted[key_git]}" "Git UI" lg
    fi
    # The digits follow context: in a tab they select a tab, as tmux's own do;
    # in an agent popup or the coordinator they open that tab's agent. The
    # branch is tmux's, so a press in a tab starts no shell.
    local digit in_agent='#{||:#{==:#{@dev_popup_kind},ai},#{==:#{@dev_popup_kind},coordinator}}'
    for digit in {1..9}; do
        [[ " ${(v)wanted} " == *" ${digit} "* ]] && continue
        _dev_bind_key "$digit" "Tab ${digit}" if-shell -F "$in_agent" \
            "run-shell \"zsh ${(qq)DEV_SCRIPT} __switch ${digit} '#{client_name}' '#{session_id}'\"" \
            "select-window -t :=${digit}"
    done

    _dev_text_set -g @dev_key_conflicts "${(j:;:)_dev_key_conflicts}"
    tmux set-option -g @dev_bind_sig "$signature"
    # Missing optional tools are not a failure: their keys are simply left
    # unbound, and `dev reload` says so. Only a binding error is.
    return $bind_status
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
    setopt localoptions extendedglob
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
    local us=$'\x1f'
    local -a rows=(${(f)"$(_dev_window_table "$grid_session")"})
    local row window_id ws_id started
    for row in "${rows[@]}"; do
        IFS="$us" read -r window_id index workspace ws_id started name <<< "$row"
        if [[ -n "$workspace" && ( "$ws" == "$index" || "$ws" == "$name" || "$want_path" == "$workspace" ) ]]; then
            print -r -- "$index"
            return 0
        fi
    done
    echo -e "${RED}Error: no workspace '${ws}' in ${grid_session}. Tabs:${NC}" >&2
    for row in "${rows[@]}"; do
        IFS="$us" read -r window_id index workspace ws_id started name <<< "$row"
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
            --brief) _dev_need_value "$1" $# || return 1; brief="$2"; shift 2 ;;
            --) shift; extra=("$@"); break ;;
            *) echo -e "${RED}Error: unknown option $1${NC}"; return 1 ;;
        esac
    done
    if [[ -z "$ws" ]]; then
        echo -e "${RED}Usage: dev agent start <tab|label|path> [--brief <file>] [-- <agent flags>]${NC}"
        return 1
    fi
    if [[ -n "$brief" && ! -r "$brief" ]]; then
        echo -e "${RED}Error: cannot read the brief ${brief}${NC}"
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
        [[ -z "$brief" ]] || _dev_agent_send "$index" --file "$brief"
        return
    fi
    if (( ${#extra} )); then
        _dev_text_set -w -t "$target" @dev_agent_args "${(j: :)${(qq)extra[@]}}"
    fi
    local pane="$(tmux display-message -p -t "$target" '#{pane_id}')"
    local -a spec=("${(@f)$(_dev_popup_spec ai)}")
    tmux run-shell -t "$pane" "$(_dev_popup_script ai "${spec[1]}" "${spec[2]}" nodisplay)"
    tmux set-option -w -t "$target" @dev_agent_started 1

    # A launcher that fails ends the session at once. Say so: a dead agent
    # that looks started is the silent failure this command exists to stop.
    local i
    local code
    for i in 1 2 3 4 5 6 7 8; do
        sleep 0.2
        running="$(_dev_agent_session_of "$ws_id")" &&
            code="$(tmux show-options -t "=${running}:" -qv @dev_agent_exit 2>/dev/null)"
        if [[ -z "$running" || -n "$code" ]]; then
            echo -e "${RED}Error: the agent for tab ${index} exited as soon as it started${code:+ (status ${code})}${NC}"
            echo -e "${YELLOW}Check ai_cmd / agent_launch_cmd with 'dev config list'${NC}"
            [[ -n "$running" ]] && tmux kill-session -t "=${running}" 2>/dev/null
            return 1
        fi
    done
    echo -e "${GREEN}✓ Agent for tab ${index} started (${running})${NC}"
    [[ -z "$brief" ]] || _dev_agent_send "$index" --file "$brief"
}

# The tab's next agent starts a new conversation. The old one stays in the
# agent's own history. A running agent is stopped only with --force: a reset
# must never end work in progress by accident.
_dev_agent_reset() {
    local ws="" force=0
    while (( $# )); do
        case "$1" in
            --force) force=1; shift ;;
            -*) echo -e "${RED}Error: unknown option $1${NC}"; return 1 ;;
            *) ws="$1"; shift ;;
        esac
    done
    if [[ -z "$ws" ]]; then
        echo -e "${RED}Usage: dev agent reset <tab|label|path> [--force]${NC}"
        return 1
    fi
    local repo grid_session index
    _dev_agent_grid || return 1
    index="$(_dev_agent_resolve "$ws")" || return 1
    local target="=${grid_session}:${index}"
    local ws_id="$(tmux show-options -w -t "$target" -qv @dev_ws_id)"
    local key="$(_dev_text_get -w -t "$target" @dev_agent_key)"
    if [[ -z "$key" ]]; then
        echo -e "${RED}Error: tab ${index} has no conversation to reset; reopen the grid with 'dev grid'${NC}"
        return 1
    fi
    local running old="$(tmux show-options -w -t "$target" -qv @dev_agent_sid)"
    if running="$(_dev_agent_session_of "$ws_id")"; then
        if (( ! force )); then
            echo -e "${RED}Error: the agent for tab ${index} is running; /exit it first, or pass --force to stop it${NC}"
            return 1
        fi
        tmux kill-session -t "=${running}" 2>/dev/null
    fi
    local file="$(_dev_agent_generation_file "$key")"
    mkdir -p "${file:h}" || return 1
    print -r -- "$(( $(_dev_agent_generation "$key") + 1 ))" > "$file" || return 1
    tmux set-option -w -t "$target" @dev_agent_sid "$(_dev_agent_sid "$key")"
    tmux set-option -w -t "$target" -u @dev_agent_started 2>/dev/null
    echo -e "${GREEN}✓ Tab ${index}'s next agent starts a new conversation${NC}"
    [[ -n "$old" ]] && echo -e "  The old one is kept: ${BLUE}claude --resume ${old}${NC}"
    return 0
}

# Whether a message reached the agent: its first characters are on screen,
# and not only in the input box. claude (and agents like it) moves a submitted
# line into the transcript and empties the prompt; text still on the last
# `❯` line was typed but not taken. Agents without a ❯ prompt only need the
# text to appear.
_dev_agent_receipt_count() {
    local screen="$1" snippet="$2" line n=0
    for line in "${(@f)screen}"; do
        [[ "$line" == *"$snippet"* ]] && (( n++ ))
    done
    print -r -- "$n"
}

_dev_agent_receipt() {
    local screen="$1" snippet="$2" before="${3:-0}" line last_prompt=""
    (( $(_dev_agent_receipt_count "$screen" "$snippet") > before )) || return 1
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
            --file) _dev_need_value "$1" $# || return 1; file="$2"; shift 2 ;;
            --no-confirm) confirm=0; shift ;;
            --timeout) _dev_need_value "$1" $# || return 1; timeout="$2"; shift 2 ;;
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

    # The agent's own pane, recorded when it started: the active pane may be
    # a shell split beside it, where a brief would run as a command.
    local pane="$(tmux show-options -t "=${session}:" -qv @dev_agent_pane)"
    _dev_pane_exists "$pane" || pane="$(tmux display-message -p -t "=${session}:" '#{pane_id}')"
    # The end of the line is what is unique to it — every pointer starts
    # "Read and follow the instructions in" — and only a new occurrence counts:
    # an earlier brief still on screen must not confirm this one.
    local snippet="${line[-40,-1]}"
    local before="$(_dev_agent_receipt_count "$(tmux capture-pane -p -J -t "$pane")" "$snippet")"
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
    local i
    for (( i = 0; i < timeout * 4; i++ )); do
        if _dev_agent_receipt "$(tmux capture-pane -p -J -t "$pane")" "$snippet" "$before"; then
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

# One row per workspace tab, "index|label|path|branch|changes|agent|ctx|detail",
# shared by status and watch so they can never disagree.
_dev_agent_rows() {
    # Each tab's git status and agent screen are read at once rather than in
    # turn: on a large repo each git status alone is a tenth of a second.
    # Pipes rather than temp files, so a dashboard closed mid-read leaves
    # nothing behind.
    local -a table=(${(f)"$(_dev_window_table "$grid_session")"}) fds=()
    local row fd
    for row in "${table[@]}"; do
        exec {fd}< <(_dev_agent_row "$row")
        fds+=($fd)
    done
    for fd in "${fds[@]}"; do
        cat <&$fd
        exec {fd}<&-
    done
}

_dev_agent_row() {
    local window_id index name workspace ws_id started branch changes agent detail ctx session screen us=$'\x1f'
    IFS="$us" read -r window_id index workspace ws_id started name <<< "$1"
    [[ -n "$workspace" ]] || return 0
    _dev_workspace_git "$workspace"
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
    print -r -- "${index}${us}${name}${us}${workspace}${us}${branch}${us}${changes}${us}${agent}${us}${ctx}${us}${detail}"
}

_dev_agent_status() {
    local json=0
    [[ "$1" == "--json" ]] && json=1
    local repo grid_session
    _dev_agent_grid || return 1
    local us=$'\x1f'
    local -a rows=(${(f)"$(_dev_agent_rows)"})
    local row index name workspace branch changes agent ctx detail width=9 bwidth=6 state
    for row in "${rows[@]}"; do
        IFS="$us" read -r index name workspace branch changes agent ctx detail <<< "$row"
        (( ${#name} > width )) && width=${#name}
        (( ${#branch} > bwidth )) && bwidth=${#branch}
    done
    (( json )) || printf "  %-3s %-${width}s  %-${bwidth}s  %-10s %-8s %s\n" "#" "workspace" "branch" "state" "agent" "detail"
    for row in "${rows[@]}"; do
        IFS="$us" read -r index name workspace branch changes agent ctx detail <<< "$row"
        if (( json )); then
            # dirty is a count, or null when git could not say.
            [[ "$changes" == <-> ]] && state="$changes" || state=null
            print -r -- "{\"tab\":${index},\"label\":$(_dev_json_str "$name"),\"path\":$(_dev_json_str "$workspace"),\"branch\":$(_dev_json_str "$branch"),\"dirty\":${state},\"agent\":\"${agent}\",\"detail\":$(_dev_json_str "$detail"),\"ctx\":${ctx:-null}}"
        else
            if [[ "$changes" == <-> ]]; then
                (( changes )) && state="${changes} changed" || state="clean"
            else
                state="$changes"
            fi
            printf "  %-3s %-${width}s  %-${bwidth}s  %-10s %-8s %s\n" "$index" "$name" "$branch" "$state" "$agent" "${detail}${ctx:+ (ctx ${ctx}%)}"
        fi
    done
}

# Status, compared over time. Edge-triggered: one event per change, never one
# per poll. A heartbeat lists every workspace even when nothing changed, and a
# final line says the watch stopped and why, so silence never means all clear.
# Read-only, except --notify's attention marker on a tab.
_dev_agent_watch() {
    # Local traps: on a sourced install the watch runs in the user's own
    # shell, and an INT trap left behind would hijack every later Ctrl-C.
    setopt localoptions localtraps
    zmodload zsh/datetime
    local interval=10 every=1800 for_secs=0 json=0 notify=0 ctx_limit=90
    while (( $# )); do
        case "$1" in
            --interval) _dev_need_value "$1" $# || return 1; interval="$2"; shift 2 ;;
            --every) _dev_need_value "$1" $# || return 1; every="$2"; shift 2 ;;
            --for) _dev_need_value "$1" $# || return 1; for_secs="$2"; shift 2 ;;
            --ctx) _dev_need_value "$1" $# || return 1; ctx_limit="$2"; shift 2 ;;
            --json) json=1; shift ;;
            --notify) notify=1; shift ;;
            *) echo -e "${RED}Error: unknown option $1${NC}"; return 1 ;;
        esac
    done
    local repo grid_session
    _dev_agent_grid || return 1
    local watch_cmd="$(_dev_cfg watch_cmd)"
    local started_at=$EPOCHSECONDS last_beat=$EPOCHSECONDS reason="ended"

    _dev_watch_emit() {
        local event="$1" ws="$2" from="$3" to="$4" detail="$5" ts="$(strftime '%Y-%m-%dT%H:%M:%S' $EPOCHSECONDS)"
        if (( json )); then
            print -r -- "{\"ts\":\"${ts}\",\"event\":\"${event}\",\"ws\":$(_dev_json_str "$ws"),\"from\":$(_dev_json_str "$from"),\"to\":$(_dev_json_str "$to"),\"detail\":$(_dev_json_str "$detail")}"
        else
            case "$event" in
                change) print -r -- "${ts}  tab ${ws}: ${from} → ${to}${detail:+  ${detail}}" ;;
                *) print -r -- "${ts}  ${event}: ${detail}" ;;
            esac
        fi
    }

    _dev_watch_beat() {
        local -a parts
        local key
        for key in ${(on)${(k)prev_state}}; do
            parts+=("${key} ${prev_label[$key]} ${prev_state[$key]}")
        done
        _dev_watch_emit heartbeat "*" "" "" "${(j:, :)parts}"
        if [[ -n "$watch_cmd" ]]; then
            local out rc line
            out="$(cd "$repo" && sh -c "$watch_cmd" 2>&1)"
            rc=$?
            for line in ${(f)out}; do
                _dev_watch_emit repo "*" "" "" "$line"
            done
            (( rc )) && _dev_watch_emit repo "*" "" "" "watch_cmd failed (exit ${rc})"
        fi
    }

    typeset -A prev_state prev_label prev_over
    local row index name workspace branch changes agent ctx detail us=$'\x1f'
    for row in ${(f)"$(_dev_agent_rows)"}; do
        IFS="$us" read -r index name workspace branch changes agent ctx detail <<< "$row"
        prev_state[$index]="$agent" prev_label[$index]="$name"
        [[ -n "$ctx" ]] && (( ctx >= ctx_limit )) && prev_over[$index]=1
    done
    trap 'reason="terminated"; return 143' TERM
    trap 'reason="interrupted"; return 130' INT
    {
        _dev_watch_beat
        while true; do
            if (( for_secs && EPOCHSECONDS - started_at >= for_secs )); then
                reason="--for elapsed"
                break
            fi
            sleep "$interval"
            # The heartbeat lists prev_state, so it follows tabs added and
            # removed while the watch runs.
            local -A seen=()
            for row in ${(f)"$(_dev_agent_rows)"}; do
                IFS="$us" read -r index name workspace branch changes agent ctx detail <<< "$row"
                seen[$index]=1
                prev_label[$index]="$name"
                : ${prev_state[$index]:=none}
                if [[ "${prev_state[$index]:-none}" != "$agent" ]]; then
                    _dev_watch_emit change "$index" "${prev_state[$index]:-none}" "$agent" "$detail"
                    if (( notify )) && [[ "$agent" == (waiting|idle|dead|unknown) ]]; then
                        tmux set-option -w -t "=${grid_session}:${index}" @dev_attention "$agent"
                        tmux display-message "dev: tab ${index} (${name}) is ${agent}" 2>/dev/null
                    fi
                    prev_state[$index]="$agent"
                fi
                if [[ -n "$ctx" ]] && (( ctx >= ctx_limit )); then
                    if [[ -z "${prev_over[$index]}" ]]; then
                        _dev_watch_emit context "$index" "" "" "tab ${index} context ${ctx}% (≥ ${ctx_limit}%)"
                        prev_over[$index]=1
                    fi
                else
                    prev_over[$index]=""
                fi
            done
            for index in ${(k)prev_state}; do
                (( ${+seen[$index]} )) || unset "prev_state[$index]" "prev_label[$index]" "prev_over[$index]"
            done
            if (( EPOCHSECONDS - last_beat >= every )); then
                _dev_watch_beat
                last_beat=$EPOCHSECONDS
            fi
        done
    } always {
        _dev_watch_emit stopped "*" "" "" "watch stopped: ${reason}"
    }
}

# ─── prefix S (the coordinator) and prefix O (the overview) ───

# The repo of the grid a pane belongs to: its own session's stamp, the
# coordinator's, or — inside a popup — that of the pane its workspace started
# from. Empty outside a grid.
_dev_grid_of_pane() {
    local pane="$1" repo origin
    repo="$(_dev_text_get -t "$pane" @dev_grid)"
    [[ -n "$repo" ]] || repo="$(_dev_text_get -t "$pane" @dev_coordinator_of)"
    if [[ -z "$repo" ]]; then
        origin="$(tmux display-message -p -t "$pane" '#{@dev_origin}' 2>/dev/null)"
        [[ -n "$origin" ]] && repo="$(_dev_text_get -t "$origin" @dev_grid)"
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
    # From a key in another popup (a client to move); a call with no client
    # has no popup to close and just finds the grid's coordinator.
    local here="$(tmux display-message -p -t "$pane" '#{session_id}')"
    if [[ -n "$client" && -n "$(tmux show-options -t "$here" -qv @dev_parent)" ]]; then
        _dev_reopen "$client" "$here" "$pane" __coordinator "$pane" "$client"
        return
    fi
    # new-session is the lock: of two presses at once, one fails as a
    # duplicate and simply opens what the other made.
    if tmux new-session -d -s "$name" -c "$repo" -e "DEV_GRID=${repo}" 2>/dev/null; then
        tmux set-option -t "=${name}:" @dev_parent "$(tmux display-message -p -t "=${grid_session}:" '#{session_id}')"
        _dev_text_set -t "=${name}:" @dev_coordinator_of "$repo"
        _dev_text_set -w -t "=${name}:" @dev_workspace "$repo"
        tmux set-option -w -t "=${name}:" @dev_ws_id "$name"
        tmux set-option -w -t "=${name}:" @dev_popup_kind coordinator
        tmux set-option -w -t "=${name}:" @dev_agent_sid "$(_dev_sid_for "dev-grid:${repo}:coordinator")"
        local coord_pane="$(tmux display-message -p -t "=${name}:" '#{pane_id}')"
        tmux respawn-pane -k -t "$coord_pane" "zsh ${(qq)DEV_SCRIPT} __agent ${(qq)coord_pane}"
    elif ! tmux has-session -t "=${name}" 2>/dev/null; then
        # Not the race (the other press made it): creating it failed.
        _dev_tell "$client" "Could not start the coordinator for ${grid_session}"
        return 1
    fi
    [[ -n "$client" ]] && tmux display-popup -c "$client" -w 90% -h 90% -b single \
        -T " coordinator · ${grid_session} " -E "tmux attach-session -t '=${name}'"
    return 0
}

# ─── prefix O: the dashboard ───

# Box drawing needs a UTF-8 locale to be measured in characters, not bytes
# (CI and many servers run in C). Picks one if the current locale is not.
_dev_utf8_locale() {
    [[ "${#${:-─}}" == 1 ]] && return 0
    local candidate
    for candidate in C.UTF-8 en_US.UTF-8 UTF-8; do
        LC_ALL="$candidate" 2>/dev/null
        [[ "${#${:-─}}" == 1 ]] && return 0
    done
    return 1
}

# Text cut to exactly n columns: padded, or shortened with an ellipsis.
_dev_fit() {
    local text="$1" n="$2"
    (( n <= 0 )) && return
    if (( ${#text} > n )); then
        print -rn -- "${text[1,n-1]}…"
    else
        print -rn -- "${(r:n:: :)text}"
    fi
}

# One frame of the dashboard: a header, the grid drawn as a tree (the
# coordinator at the root, a branch per tab with its agent under it), and the
# keys. Colour only on the state word, added after the text is cut, so it
# never changes a line's width.
_dev_dashboard_frame() {
    setopt localoptions
    local LC_ALL="$LC_ALL"
    _dev_utf8_locale
    local grid_session="$1" width="${2:-100}" selected="${3:-0}" us=$'\x1f'
    # Rows the caller already read, so a key press redraws without reading
    # every worktree again.
    local -a rows
    if (( $# >= 4 )); then
        rows=(${(f)4})
    else
        rows=(${(f)"$(_dev_agent_rows)"})
    fi
    local row index name workspace branch changes agent ctx detail running=0 name_w=0
    for row in "${rows[@]}"; do
        IFS="$us" read -r index name workspace branch changes agent ctx detail <<< "$row"
        [[ "$agent" != (none|dead) ]] && (( running++ ))
        (( ${#name} > name_w )) && name_w=${#name}
    done
    (( name_w > width / 3 )) && name_w=$(( width / 3 ))
    local header="${grid_session} · $(_dev_plural ${#rows} tab) · $(_dev_plural $running "agent") running · $(date +%H:%M)"
    print -r -- "$(_dev_fit " $header" "$width")"
    print

    local reset=$'\e[0m'
    local -A colour=(
        working $'\e[32m' waiting $'\e[1;33m' idle $'\e[37m'
        dead $'\e[31m' none $'\e[2m' unknown $'\e[35m'
    )
    local -A icon=(working ● waiting ● idle ◐ dead ✕ none ○ unknown '?')

    # The root: the grid's coordinator, if prefix S has started one.
    local coord="coord-${grid_session#${DEV_SESSION_PREFIX}}" coord_state root="◇" root_text
    if tmux has-session -t "=${coord}" 2>/dev/null; then
        root="◆"
        coord_state="$(tmux capture-pane -p -t "=${coord}:" 2>/dev/null | _dev_agent_screen_state)"
        root_text="${icon[$coord_state]:-?} ${(U)coord_state}"
    else
        coord_state=none
        root_text="${icon[none]} not started (prefix $(_dev_cfg key_coordinator))"
    fi
    local root_prefix=" ${root} coordinator · "
    print -r -- "${root_prefix}${colour[$coord_state]:-}$(_dev_fit "$root_text" $(( width - ${#root_prefix} )))${reset}"
    (( ${#rows} )) && print -r -- " │"

    local k branch_mark stem changes_text state_plain
    for (( k = 1; k <= ${#rows}; k++ )); do
        IFS="$us" read -r index name workspace branch changes agent ctx detail <<< "${rows[k]}"
        if (( k == ${#rows} )); then
            branch_mark="└─" stem="      "
        else
            branch_mark="├─" stem=" │    "
        fi
        [[ "$index" == "$selected" ]] && branch_mark+="▶" || branch_mark+=" "
        if [[ "$changes" == <-> ]]; then
            (( changes )) && changes_text="${changes} changed" || changes_text="clean"
        else
            changes_text="$changes"
        fi
        print -r -- " ${branch_mark}$(_dev_fit "${index} $(_dev_fit "$name" $name_w)  ${branch} · ${changes_text}" $(( width - 4 )))"
        case "$agent" in
            none) state_plain="${icon[none]} no agent" ;;
            *) state_plain="${icon[$agent]:-?} ${(U)agent}${ctx:+ · ctx ${ctx}%}" ;;
        esac
        print -r -- "${stem}${colour[$agent]:-}$(_dev_fit "$state_plain" $(( width - 6 )))${reset}"
        [[ -n "$detail" ]] && print -r -- "${stem}$(_dev_fit "\"${detail}\"" $(( width - 6 )))"
    done
    print
    print -r -- "$(_dev_fit " 1-9 select · Enter go to tab · a open its agent · s start its agent · q close" "$width")"
}

# What a key does, given the selected tab: select N, go N, agent N, start N,
# quit or none.
_dev_dashboard_key() {
    local key="$1" selected="$2"
    case "$key" in
        [1-9]) print -r -- "select $key" ;;
        $'\n'|$'\r') print -r -- "go $selected" ;;
        a) print -r -- "agent $selected" ;;
        s) print -r -- "start $selected" ;;
        q|$'\e') print -r -- "quit" ;;
        *) print -r -- "none" ;;
    esac
}

# The dashboard loop, in prefix O's popup: redraw every 2 seconds or on a
# key. It never types into an agent; going to a tab or opening its agent ends
# it, and the popup closes.
_dev_dashboard() {
    local pane="$1" client="$2" repo grid_session
    repo="$(_dev_grid_of_pane "$pane")"
    grid_session="$(_dev_grid_session "$repo")" 2>/dev/null
    if [[ -z "$repo" || -z "$grid_session" ]]; then
        _dev_tell "$client" "No grid here — run 'dev grid' in a repo first"
        return 0
    fi
    local selected="$(tmux display-message -p -t "$pane" '#{window_index}' 2>/dev/null)"
    local key action n size width rows screen fetched=-1 nl=$'\n' eol=$'\e[K\n'
    # Each frame is drawn over the last one, never after clearing the screen:
    # reading the grid takes long enough that a cleared screen shows as a
    # blank flash on every refresh.
    print -rn -- $'\e[?25l\e[H\e[J Reading the grid…'
    {
        while true; do
            size="$(stty size </dev/tty 2>/dev/null)"
            width="${size##* }"
            [[ "$width" == <-> ]] || width=100
            if (( fetched < 0 || SECONDS - fetched >= 2 )); then
                rows="$(_dev_agent_rows)"
                fetched=$SECONDS
            fi
            screen="$(_dev_dashboard_frame "$grid_session" "$width" "$selected" "$rows")"
            print -rn -- $'\e[H'"${screen//$nl/$eol}"$'\e[K\e[J'
            key=""
            read -s -k 1 -t 2 key </dev/tty 2>/dev/null || fetched=-1
            action="$(_dev_dashboard_key "$key" "$selected")"
            n="${action##* }"
            case "$action" in
                select\ *)
                    _dev_tab_exists "$grid_session" "$n" && selected="$n"
                    ;;
                go\ *)
                    tmux select-window -t "=${grid_session}:${n}" 2>/dev/null
                    return 0
                    ;;
                agent\ *)
                    _dev_open_tab_agent "$grid_session" "$n" "$client"
                    return 0
                    ;;
                start\ *)
                    (cd "$repo" && DEV_GRID="$repo" _dev_agent_start "$n") &>/dev/null
                    fetched=-1
                    ;;
                quit) return 0 ;;
            esac
        done
    } always {
        print -n $'\e[?25h'
    }
}

# A popup for a command rather than a session: the dashboard and the N and X
# prompts. A command popup has no client of its own for prefix d to detach,
# so the command runs in a throwaway session that the popup attaches: prefix
# d detaches it and the hook ends the session, command and all. Ctrl-C ends
# the command, which ends the session too.
_dev_dialog() {
    local client="$1" pane="$2" title="$3" size="$4"
    shift 4
    local here="$(tmux display-message -p -t "$pane" '#{session_id}' 2>/dev/null)"
    if [[ -n "$client" && -n "$(tmux show-options -t "$here" -qv @dev_parent 2>/dev/null)" ]]; then
        if [[ "$(_dev_text_get -w -t "${here}:" @dev_dialog)" == "$title" ]]; then
            _dev_tell "$client" "Already in this popup"
            return 0
        fi
        _dev_reopen "$client" "$here" "$pane" __dialog "$client" "$pane" "$title" "$size" "$@"
        return
    fi
    local name="dlg-$$" dir
    dir="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
    tmux new-session -d -s "$name" -c "${dir:-$HOME}" "$@" || return 1
    # Marked as a popup of the tab's session, like the others: the reaper
    # closes it with the session, and a popup key pressed in it hops out.
    tmux set-option -t "=${name}:" @dev_parent "$here"
    tmux set-option -w -t "=${name}:" @dev_popup_kind dialog
    tmux set-option -w -t "=${name}:" @dev_origin "$pane"
    _dev_text_set -w -t "=${name}:" @dev_dialog "$title"
    tmux set-option -t "=${name}:" status off
    tmux set-hook -t "=${name}:" client-detached "kill-session -t '=${name}'"
    tmux display-popup -c "$client" -w "$size" -h "$size" -b single -T " ${title} " \
        -E "tmux attach-session -t '=${name}'" || tmux kill-session -t "=${name}" 2>/dev/null
}

# Goes to a tab and opens its agent, as prefix a there would. The agent's
# popup is opened just after this one closes: one popup cannot open another.
_dev_open_tab_agent() {
    local grid_session="$1" index="$2" client="$3" target_pane ws_id session
    tmux select-window -t "=${grid_session}:${index}" 2>/dev/null || return 1
    target_pane="$(tmux display-message -p -t "=${grid_session}:${index}" '#{pane_id}')"
    ws_id="$(tmux show-options -w -t "=${grid_session}:${index}" -qv @dev_ws_id)"
    local -a spec=("${(@f)$(_dev_popup_spec ai)}")
    tmux run-shell -t "$target_pane" "$(_dev_popup_script ai "${spec[1]}" "${spec[2]}" nodisplay)"
    session="$(_dev_agent_session_of "$ws_id")" || return 1
    [[ -n "$client" ]] && tmux run-shell -b "sleep 0.3; tmux display-popup -c ${(qq)client} -w 90% -h 90% -b single -T ' ${ws_id} ' -E \"tmux attach-session -t '=${session}'\""
    return 0
}

# Read from the window list: `display-message -t =session:7` exits 0 even
# when the session has no window 7.
_dev_tab_exists() {
    tmux list-windows -t "=$1:" -F '#{window_index}' 2>/dev/null | grep -qx -- "$2"
}

# prefix 1-9 inside an agent popup or the coordinator: close it and open tab
# N's agent in the client that showed it. That client is not named anywhere,
# so it is the parent session's client with the latest activity: the keys
# typed into a popup arrive through it.
_dev_switch_agent() {
    local index="$1" inner="$2" popup_session="$3" parent parent_name ws_id outer
    parent="$(tmux show-options -t "$popup_session" -qv @dev_parent)"
    parent_name="$(tmux display-message -p -t "$parent" '#{session_name}' 2>/dev/null)"
    if [[ -z "$parent" || -z "$parent_name" ]]; then
        _dev_tell "$inner" "This popup's tabs are gone"
        return 1
    fi
    if ! _dev_tab_exists "$parent_name" "$index"; then
        _dev_tell "$inner" "No tab ${index}"
        return 0
    fi
    ws_id="$(tmux show-options -w -t "=${parent_name}:${index}" -qv @dev_ws_id)"
    if [[ -n "$ws_id" && "$(tmux show-options -w -t "$popup_session" -qv @dev_ws_id)" == "$ws_id" ]]; then
        _dev_tell "$inner" "Already in this popup"
        return 0
    fi
    outer="$(tmux list-clients -t "$parent" -F '#{client_activity} #{client_name}' | sort -rn | head -1)"
    outer="${outer#* }"
    if [[ -z "$outer" ]]; then
        _dev_tell "$inner" "No client shows ${parent_name}"
        return 1
    fi
    tmux detach-client -t "$inner"
    _dev_open_tab_agent "$parent_name" "$index" "$outer"
}

# The client showing a popup and the tab pane it belongs to, as "client pane".
# The client is the parent session's with the latest activity: the keys typed
# into a popup arrive through it. The pane is the one the popup was opened
# from, or the parent's current pane when that is gone or was never recorded.
_dev_popup_host() {
    local popup_session="$1" parent origin outer target
    parent="$(tmux show-options -t "$popup_session" -qv @dev_parent)"
    [[ -n "$parent" ]] && tmux has-session -t "$parent" 2>/dev/null || return 1
    outer="$(tmux list-clients -t "$parent" -F '#{client_activity} #{client_name}' | sort -rn | head -1)"
    outer="${outer#* }"
    [[ -n "$outer" ]] || return 1
    origin="$(tmux show-options -w -t "${popup_session}:" -qv @dev_origin)"
    if _dev_pane_exists "$origin"; then
        target="$origin"
    else
        target="$(tmux display-message -p -t "$parent" '#{pane_id}')"
    fi
    print -r -- "${outer} ${target}"
}

# Closes the popup a key was pressed in and runs `dev <args>` once it has
# gone, for the client that showed it and the tab it belonged to: the inner
# client and pane in the args are swapped for those. One popup cannot open
# another, and a popup inside a popup takes a detach per level to leave.
_dev_reopen() {
    local inner="$1" popup_session="$2" pane="$3" host outer target arg
    shift 3
    if ! host="$(_dev_popup_host "$popup_session")"; then
        _dev_tell "$inner" "This popup's tab is gone"
        return 1
    fi
    outer="${host% *}" target="${host#* }"
    local -a args=()
    for arg in "$@"; do
        case "$arg" in
            "$inner") args+=("$outer") ;;
            "$pane") args+=("$target") ;;
            *) args+=("$arg") ;;
        esac
    done
    tmux detach-client -t "$inner"
    tmux run-shell -b "sleep 0.3; zsh ${(qq)DEV_SCRIPT} ${(j: :)${(@qq)args}}"
}

# A popup key (terminal, agent, git, kb) pressed inside another dev popup.
_dev_hop() {
    local prefix="$1" inner="$2" popup_session="$3"
    if [[ "$(tmux show-options -w -t "${popup_session}:" -qv @dev_popup_kind)" == "$prefix" ]]; then
        _dev_tell "$inner" "Already in this popup"
        return 0
    fi
    _dev_reopen "$inner" "$popup_session" "{pane}" __popup "$prefix" "$inner" "{pane}"
}

# Opens a popup key's popup for a pane, in a given client: what the key does
# in that pane, without a key press to carry the client.
_dev_popup_open() {
    local prefix="$1" client="$2" pane="$3" key session
    local -a spec=("${(@f)$(_dev_popup_spec "$prefix")}")
    (( ${#spec} )) || return 1
    tmux run-shell -t "$pane" "$(_dev_popup_script "$prefix" "${spec[1]}" "${spec[2]}" nodisplay)"
    key="$(tmux display-message -p -t "$pane" "$(_dev_popup_key_format)")"
    session="${prefix}-${key}${spec[2]:+-${spec[2]}}"
    tmux display-popup -c "$client" -w 90% -h 90% -b single -T " ${key} " \
        -E "tmux attach-session -t '=${session}'"
}

# Run directly if executed (not sourced), set up keybindings if sourced
if [[ "${zsh_eval_context[-1]}" != "file" ]]; then
    dev "$@"
else
    # Loading dev never fails a shell's startup: with no tmux server yet there
    # is simply nothing to bind.
    _dev_setup_popup_keybindings || true
fi
