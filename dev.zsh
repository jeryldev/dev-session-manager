#!/usr/bin/env zsh
# Dev Session Manager
# Quick development session bootstrapping with tmux
#
# Copyright (c) 2026 Jeryl Estopace
# GitHub: https://github.com/jeryldev
# LinkedIn: https://www.linkedin.com/in/jeryldev/
# Repository: https://github.com/jeryldev/dev-session-manager

# Version
DEV_VERSION="2.1.0"

# Configuration
DEV_SESSION_PREFIX="dev-"
DEV_DEFAULT_DIR="${DEV_HOME_DIR:-$HOME/code}"
DEV_AI_CMD="${DEV_AI_CMD:-claude}"

# Colors (use existing shell colors or define defaults)
: ${RED:='\033[0;31m'}
: ${GREEN:='\033[0;32m'}
: ${YELLOW:='\033[0;33m'}
: ${BLUE:='\033[0;34m'}
: ${NC:='\033[0m'}

# Check if a command is available
_dev_has_command() {
    command -v "$1" &> /dev/null
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
    _dev_setup_ai_keybinding
    local cmd="$1"
    local box_width=56

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
            echo -e "  ${BLUE}dev kill <name>${NC}    Kill a dev session"
            echo -e "  ${BLUE}dev reload${NC}         Reload AI popup keybinding"
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
            echo -e "${YELLOW}Session layout (7 windows, all start at ${DEV_DEFAULT_DIR}):${NC}"
            echo -e "  1. frontend   2. backend    3. database   4. testing"
            echo -e "  5. ${GREEN}editor${NC}     6. scratch    7. extra"
            echo ""
            echo -e "${BLUE}Starts at window 5 (editor)${NC}"
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
            if [ -z "$sessions" ]; then
                echo -e "  ${YELLOW}No dev sessions found${NC}"
            else
                while IFS= read -r line; do
                    echo "  ${line#${DEV_SESSION_PREFIX}}"
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

            if tmux has-session -t "$session_name" 2>/dev/null; then
                echo -e "${BLUE}Attaching to: ${display_name}${NC}"
                tmux attach -t "$session_name"
            else
                echo -e "${RED}✗ Session '${display_name}' not found${NC}"
                echo -e "${YELLOW}Tip: Run 'dev ls' to see active sessions${NC}"
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

            if tmux has-session -t "$session_name" 2>/dev/null; then
                tmux kill-session -t "$session_name"
                echo -e "${GREEN}✓ Killed session: $display_name${NC}"
            else
                echo -e "${RED}✗ Session '$display_name' not found${NC}"
                echo -e "${YELLOW}Tip: Run 'dev ls' to see active sessions${NC}"
            fi
            ;;

        reload)
            echo -e "${BLUE}Reloading dev configuration...${NC}"
            _dev_setup_ai_keybinding
            echo -e "${GREEN}✓ AI popup keybinding updated${NC}"
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
            echo -e "${GREEN}Quick reference:${NC}"
            echo -e "  ${BLUE}Detach${NC} = Prefix d (session stays alive, can reattach)"
            echo -e "  ${BLUE}Exit${NC}   = type 'exit' (closes current pane/window)"
            echo -e "  ${BLUE}Kill${NC}   = dev kill <name> (destroys entire session)"
            echo ""
            ;;

        "")
            echo -e "${RED}Usage: dev <command> [args]${NC}"
            echo -e "${YELLOW}Run 'dev help' for more information${NC}"
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

            local session_name=$(_dev_normalize_session_name "$1")
            local display_name=$(_dev_display_name "$session_name")

            # Check if session already exists
            if tmux has-session -t "$session_name" 2>/dev/null; then
                echo -e "${YELLOW}⚠ Session '${display_name}' already exists!${NC}"
                echo -ne "${GREEN}Attach to it? (y/n) ${NC}"
                read choice
                case "$choice" in
                    y|Y)
                        echo -e "${BLUE}Attaching to: ${display_name}${NC}"
                        tmux attach -t "$session_name"
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

            tmux new-session -d -s "$session_name" -n "frontend" -c "$DEV_DEFAULT_DIR"
            tmux new-window -t "$session_name:2" -n "backend" -c "$DEV_DEFAULT_DIR"
            tmux new-window -t "$session_name:3" -n "database" -c "$DEV_DEFAULT_DIR"
            tmux new-window -t "$session_name:4" -n "testing" -c "$DEV_DEFAULT_DIR"
            tmux new-window -t "$session_name:5" -n "editor" -c "$DEV_DEFAULT_DIR"
            tmux new-window -t "$session_name:6" -n "scratch" -c "$DEV_DEFAULT_DIR"
            tmux new-window -t "$session_name:7" -n "extra" -c "$DEV_DEFAULT_DIR"

            # Select the editor window (window 5)
            tmux select-window -t "$session_name:5"

            # Attach to the session
            echo -e "${BLUE}Created 7 windows, starting at editor${NC}"
            tmux attach -t "$session_name"
            ;;
    esac
}

# AI popup keybinding: prefix+a opens a persistent AI session per tmux window
_dev_setup_ai_keybinding() {
    [[ -z "$TMUX" ]] && return
    tmux bind-key a run-shell "\
      SESSION=\"ai-#{session_name}-#{window_index}-#{window_name}-${DEV_AI_CMD}\"; \
      tmux has-session -t \"\$SESSION\" 2>/dev/null || \
      tmux new-session -d -s \"\$SESSION\" -c \"#{pane_current_path}\" \"${DEV_AI_CMD}\"; \
      tmux display-popup -w 80% -h 80% -b single -E \
      \"tmux attach-session -t \$SESSION\""
}

# Run directly if executed (not sourced), set up keybinding if sourced
if [[ "${zsh_eval_context[-1]}" != "file" ]]; then
    dev "$@"
else
    _dev_setup_ai_keybinding
fi
