# Dev Session Manager
# Quick development session bootstrapping with tmux

# Configuration
DEV_SESSION_PREFIX="dev-"
DEV_DEFAULT_DIR="${DEV_HOME_DIR:-~/code}"
DEV_CONFIG_FILE="${HOME}/.config/zsh/dev.zsh"

# Helper function to normalize session names
_dev_normalize_session_name() {
    local name="$1"
    if [[ ! "$name" =~ ^${DEV_SESSION_PREFIX} ]]; then
        echo "${DEV_SESSION_PREFIX}${name}"
    else
        echo "$name"
    fi
}

# Helper function to get display name (without prefix)
_dev_display_name() {
    local session_name="$1"
    echo "${session_name#${DEV_SESSION_PREFIX}}"
}

# Helper function to validate session name
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
    if ! command -v tmux &> /dev/null; then
        echo -e "${RED}Error: tmux is not installed${NC}"
        echo -e "${YELLOW}Install with: brew install tmux${NC}"
        return 1
    fi
    return 0
}

# Dev session manager
# Usage: dev <command> [args]
dev() {
    # Check tmux availability first
    if ! _dev_check_tmux; then
        return 1
    fi

    local cmd="$1"

    case "$cmd" in
        help|h|-h|--help)
            echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║              Dev Session Manager                       ║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Commands:${NC}"
            echo -e "  ${BLUE}dev <name>${NC}         Create/attach to dev session"
            echo -e "  ${BLUE}dev attach <name>${NC} Attach to existing dev session"
            echo -e "  ${BLUE}dev ls${NC}            List all dev sessions"
            echo -e "  ${BLUE}dev kill <name>${NC}   Kill a dev session"
            echo -e "  ${BLUE}dev reload${NC}        Reload dev.zsh configuration"
            echo -e "  ${BLUE}dev help${NC}          Show this help"
            echo -e "  ${BLUE}dev tmux${NC}          Show tmux commands reference"
            echo -e "  ${BLUE}dev ref${NC}           Show dev tools quick reference"
            echo ""
            echo -e "${YELLOW}Examples:${NC}"
            echo -e "  ${BLUE}dev 1${NC}             Create 'dev-1'"
            echo -e "  ${BLUE}dev testing${NC}       Create 'dev-testing'"
            echo -e "  ${BLUE}dev attach 1${NC}      Attach to 'dev-1'"
            echo -e "  ${BLUE}dev kill 1${NC}        Kill 'dev-1'"
            echo ""
            echo -e "${GREEN}Session Layout (7 windows, all start at ${DEV_DEFAULT_DIR}):${NC}"
            echo -e "  1. frontend   2. backend    3. database   4. testing"
            echo -e "  5. ${YELLOW}editor${NC}     6. scratch    7. extra"
            echo -e ""
            echo -e "${BLUE}→ Starts at window 5 (editor)${NC}"
            ;;

        ls|list)
            echo -e "${GREEN}Active dev sessions:${NC}"
            local sessions=$(tmux list-sessions 2>/dev/null | grep "^${DEV_SESSION_PREFIX}")
            if [ -z "$sessions" ]; then
                echo -e "${YELLOW}No dev sessions found${NC}"
            else
                # Strip prefix from session names for cleaner display
                while IFS= read -r line; do
                    echo "  ${line#${DEV_SESSION_PREFIX}}"
                done <<< "$sessions"
                echo ""
                echo -e "${BLUE}Tip: Use 'dev attach <name>' to attach or 'dev kill <name>' to kill${NC}"
            fi
            ;;

        attach|a)
            if [ -z "$2" ]; then
                echo -e "${RED}Usage: dev attach <name>${NC}"
                echo -e "${YELLOW}Example: dev attach sample${NC}"
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
            if [ -z "$2" ]; then
                echo -e "${RED}Usage: dev kill <name>${NC}"
                echo -e "${YELLOW}Example: dev kill sample${NC}"
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
            echo -e "${BLUE}Reloading dev.zsh configuration...${NC}"
            if [[ ! -f "$DEV_CONFIG_FILE" ]]; then
                echo -e "${RED}✗ Config file not found: $DEV_CONFIG_FILE${NC}"
                return 1
            fi
            if source "$DEV_CONFIG_FILE" 2>/dev/null; then
                echo -e "${GREEN}✓ Successfully reloaded dev.zsh${NC}"
            else
                echo -e "${RED}✗ Failed to reload dev.zsh${NC}"
                echo -e "${YELLOW}Check $DEV_CONFIG_FILE for syntax errors${NC}"
                return 1
            fi
            ;;

        tmux|t)
            echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║          Tmux Commands Reference (Prefix: Ctrl+p)      ║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Exit / Detach:${NC}"
            echo -e "  ${BLUE}Ctrl+p d${NC}          ${GREEN}Detach${NC} from session (keeps running in background)"
            echo -e "  ${BLUE}exit${NC}              ${RED}Exit${NC} shell (closes pane/window, kills if last one)"
            echo -e "  ${BLUE}dev kill <name>${NC}   ${RED}Kill${NC} entire session (destroys all windows)"
            echo ""
            echo -e "${YELLOW}Window Navigation:${NC}"
            echo -e "  ${BLUE}Ctrl+[${NC}            Previous window"
            echo -e "  ${BLUE}Ctrl+]${NC}            Next window"
            echo -e "  ${BLUE}Ctrl+p 0-9${NC}        Jump to window number (0-9)"
            echo -e "  ${BLUE}Ctrl+p w${NC}          Show window list (interactive)"
            echo ""
            echo -e "${YELLOW}Window Management:${NC}"
            echo -e "  ${BLUE}Ctrl+p c${NC}          Create new window"
            echo -e "  ${BLUE}Ctrl+p ,${NC}          Rename current window"
            echo -e "  ${BLUE}Ctrl+p &${NC}          Kill current window (with confirmation)"
            echo ""
            echo -e "${YELLOW}Pane Splits:${NC}"
            echo -e "  ${BLUE}Ctrl+p v${NC}          Split vertically (side by side)"
            echo -e "  ${BLUE}Ctrl+p s${NC}          Split horizontally (top/bottom)"
            echo -e "  ${BLUE}Ctrl+p z${NC}          Toggle pane zoom (fullscreen)"
            echo -e "  ${BLUE}Ctrl+p X${NC}          Close current pane (with confirmation)"
            echo ""
            echo -e "${YELLOW}Pane Navigation:${NC}"
            echo -e "  ${BLUE}Ctrl+h/j/k/l${NC}      Navigate between panes (vim-tmux-navigator)"
            echo -e "  ${BLUE}Ctrl+p arrow${NC}      Navigate with arrow keys"
            echo ""
            echo -e "${YELLOW}Pane Resizing:${NC}"
            echo -e "  ${BLUE}Ctrl+p H${NC}          Resize pane left (hold and repeat)"
            echo -e "  ${BLUE}Ctrl+p J${NC}          Resize pane down"
            echo -e "  ${BLUE}Ctrl+p K${NC}          Resize pane up"
            echo -e "  ${BLUE}Ctrl+p L${NC}          Resize pane right"
            echo ""
            echo -e "${YELLOW}Copy Mode (Scrollback):${NC}"
            echo -e "  ${BLUE}Ctrl+p Enter${NC}      Enter copy mode (scroll/search)"
            echo -e "  ${BLUE}v${NC}                 Start selection (in copy mode)"
            echo -e "  ${BLUE}y${NC}                 Copy selection (in copy mode)"
            echo -e "  ${BLUE}q${NC} or ${BLUE}Esc${NC}         Exit copy mode"
            echo ""
            echo -e "${YELLOW}Session Management:${NC}"
            echo -e "  ${BLUE}Ctrl+p R${NC}          Rename session"
            echo -e "  ${BLUE}Ctrl+p s${NC}          Show all sessions (switch)"
            echo -e "  ${BLUE}Ctrl+p (${NC}          Switch to previous session"
            echo -e "  ${BLUE}Ctrl+p )${NC}          Switch to next session"
            echo ""
            echo -e "${YELLOW}Other:${NC}"
            echo -e "  ${BLUE}Ctrl+p r${NC}          Reload tmux config"
            echo -e "  ${BLUE}Ctrl+p ?${NC}          Show all keybindings"
            echo ""
            echo -e "${GREEN}Quick Reference:${NC}"
            echo -e "  ${BLUE}Detach${NC}    = Ctrl+p d   (session stays alive, can reattach)"
            echo -e "  ${BLUE}Exit${NC}      = type 'exit' (closes current pane/window)"
            echo -e "  ${BLUE}Kill${NC}      = dev kill <name> (destroys entire session)"
            echo ""
            ;;

        ref|reference)
            echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║          Development Tools Quick Reference            ║${NC}"
            echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""

            echo -e "${YELLOW}═══ PostgreSQL ═══${NC}"
            echo -e "  ${BLUE}psql${NC}                   Connect to default database"
            echo -e "  ${BLUE}psql -d <db>${NC}          Connect to specific database"
            echo -e "  ${BLUE}psql -U postgres${NC}      Connect as postgres user"
            echo -e "  ${BLUE}\\l${NC}                    List all databases"
            echo -e "  ${BLUE}\\c <database>${NC}        Switch to database"
            echo -e "  ${BLUE}\\dt${NC}                   List tables in current database"
            echo -e "  ${BLUE}\\d <table>${NC}           Describe table structure"
            echo -e "  ${BLUE}\\du${NC}                   List all users/roles"
            echo -e "  ${BLUE}\\q${NC}                    Quit psql"
            echo -e "  ${BLUE}CREATE USER <name> WITH PASSWORD '<pwd>';${NC}"
            echo -e "  ${BLUE}ALTER USER <name> WITH PASSWORD '<new_pwd>';${NC}"
            echo -e "  ${BLUE}DROP USER <name>;${NC}"
            echo -e "  ${BLUE}GRANT ALL ON DATABASE <db> TO <user>;${NC}"
            echo ""
            echo -e "  ${GREEN}Aliases:${NC}"
            echo -e "  ${BLUE}pgstart${NC}              Start PostgreSQL service"
            echo -e "  ${BLUE}pgstop${NC}               Stop PostgreSQL service"
            echo -e "  ${BLUE}pgrestart${NC}            Restart PostgreSQL service"
            echo -e "  ${BLUE}pgstatus${NC}             Check PostgreSQL status"
            echo ""

            echo -e "${YELLOW}═══ Mix/Elixir (Phoenix/Ash) ═══${NC}"
            echo -e "  ${BLUE}mix deps.get${NC}         Install dependencies"
            echo -e "  ${BLUE}mix compile${NC}          Compile project"
            echo -e "  ${BLUE}mix test${NC}             Run all tests"
            echo -e "  ${BLUE}mix test <file>${NC}      Run specific test file"
            echo -e "  ${BLUE}iex -S mix${NC}           Start interactive shell"
            echo -e "  ${BLUE}mix phx.server${NC}       Start Phoenix server"
            echo -e "  ${BLUE}iex -S mix phx.server${NC}  Start Phoenix with IEx"
            echo ""
            echo -e "  ${GREEN}Database:${NC}"
            echo -e "  ${BLUE}mix ecto.create${NC}      Create database"
            echo -e "  ${BLUE}mix ecto.migrate${NC}     Run migrations"
            echo -e "  ${BLUE}mix ecto.rollback${NC}    Rollback last migration"
            echo -e "  ${BLUE}mix ecto.reset${NC}       Drop, create, migrate"
            echo -e "  ${BLUE}mix ecto.gen.migration <name>${NC}  Generate migration"
            echo ""
            echo -e "  ${GREEN}Ash Framework:${NC}"
            echo -e "  ${BLUE}mix ash.setup${NC}        Setup Ash resources"
            echo -e "  ${BLUE}mix ash.reset${NC}        Reset Ash resources"
            echo -e "  ${BLUE}mix ash_postgres.create${NC}  Create Ash databases"
            echo -e "  ${BLUE}mix ash_postgres.migrate${NC}  Run Ash migrations"
            echo ""
            echo -e "  ${GREEN}Aliases:${NC}"
            echo -e "  ${BLUE}iex.server${NC}           Start Phoenix with auto-MCP setup"
            echo -e "  ${BLUE}iex.allocator${NC}        Start allocator-one with Tidewave"
            echo ""

            echo -e "${YELLOW}═══ asdf (Version Manager) ═══${NC}"
            echo -e "  ${BLUE}asdf list${NC}            List installed versions (all plugins)"
            echo -e "  ${BLUE}asdf list elixir${NC}     List installed Elixir versions"
            echo -e "  ${BLUE}asdf list-all elixir${NC} List all available Elixir versions"
            echo -e "  ${BLUE}asdf install elixir <ver>${NC}  Install Elixir version"
            echo -e "  ${BLUE}asdf global elixir <ver>${NC}   Set global Elixir version"
            echo -e "  ${BLUE}asdf local elixir <ver>${NC}    Set local Elixir version (.tool-versions)"
            echo -e "  ${BLUE}asdf current${NC}         Show current versions"
            echo -e "  ${BLUE}asdf plugin list${NC}     List installed plugins"
            echo -e "  ${BLUE}asdf plugin add <name>${NC}  Add new plugin"
            echo ""

            echo -e "${YELLOW}═══ Node.js/npm (via nvm) ═══${NC}"
            echo -e "  ${BLUE}node --version${NC}       Show Node.js version"
            echo -e "  ${BLUE}npm --version${NC}        Show npm version"
            echo -e "  ${BLUE}node <file>${NC}          Run JavaScript file"
            echo -e "  ${BLUE}npm init${NC}             Initialize new npm project"
            echo -e "  ${BLUE}npm install${NC}          Install dependencies from package.json"
            echo -e "  ${BLUE}npm install <pkg>${NC}    Install package"
            echo -e "  ${BLUE}npm install -g <pkg>${NC} Install package globally"
            echo -e "  ${BLUE}npm uninstall <pkg>${NC}  Uninstall package"
            echo -e "  ${BLUE}npm run <script>${NC}     Run script from package.json"
            echo -e "  ${BLUE}npm start${NC}            Run start script"
            echo -e "  ${BLUE}npm test${NC}             Run test script"
            echo -e "  ${BLUE}npx <cmd>${NC}            Execute package binary"
            echo ""
            echo -e "  ${GREEN}nvm (Node Version Manager):${NC}"
            echo -e "  ${BLUE}nvm ls${NC}               List installed Node versions"
            echo -e "  ${BLUE}nvm ls-remote${NC}        List available Node versions"
            echo -e "  ${BLUE}nvm install <ver>${NC}    Install Node version"
            echo -e "  ${BLUE}nvm use <ver>${NC}        Switch to Node version"
            echo -e "  ${BLUE}nvm current${NC}          Show current Node version"
            echo -e "  ${BLUE}nvm alias default <ver>${NC}  Set default Node version"
            echo ""

            echo -e "${YELLOW}═══ Git ═══${NC}"
            echo -e "  ${BLUE}git status${NC}           Check working tree status"
            echo -e "  ${BLUE}git add <file>${NC}       Stage file"
            echo -e "  ${BLUE}git commit -m \"msg\"${NC}  Commit staged changes"
            echo -e "  ${BLUE}git push${NC}             Push to remote"
            echo -e "  ${BLUE}git pull${NC}             Pull from remote"
            echo -e "  ${BLUE}git branch${NC}           List branches"
            echo -e "  ${BLUE}git checkout -b <name>${NC}  Create and switch to branch"
            echo -e "  ${BLUE}git log --oneline${NC}    Show commit history"
            echo -e "  ${BLUE}git diff${NC}             Show unstaged changes"
            echo -e "  ${BLUE}git diff --staged${NC}    Show staged changes"
            echo ""
            echo -e "  ${GREEN}Aliases:${NC}"
            echo -e "  ${BLUE}gs${NC}                   git status"
            echo -e "  ${BLUE}gd${NC}                   git diff"
            echo -e "  ${BLUE}gds${NC}                  git diff --staged"
            echo -e "  ${BLUE}ga${NC}                   git add"
            echo -e "  ${BLUE}gaa${NC}                  git add --all"
            echo -e "  ${BLUE}gcm \"msg\"${NC}            git commit -m \"msg\""
            echo -e "  ${BLUE}gps${NC}                  git push -u origin current-branch"
            echo -e "  ${BLUE}gpl${NC}                  git pull"
            echo -e "  ${BLUE}gcob <name>${NC}          Create branch and push to remote"
            echo ""

            echo -e "${YELLOW}═══ Docker ═══${NC}"
            echo -e "  ${BLUE}docker ps${NC}            List running containers"
            echo -e "  ${BLUE}docker ps -a${NC}         List all containers"
            echo -e "  ${BLUE}docker images${NC}        List images"
            echo -e "  ${BLUE}docker build -t <name> .${NC}  Build image"
            echo -e "  ${BLUE}docker run <image>${NC}   Run container"
            echo -e "  ${BLUE}docker exec -it <id> bash${NC}  Enter container shell"
            echo -e "  ${BLUE}docker logs <id>${NC}     View container logs"
            echo -e "  ${BLUE}docker stop <id>${NC}     Stop container"
            echo -e "  ${BLUE}docker rm <id>${NC}       Remove container"
            echo ""
            echo -e "  ${GREEN}Aliases:${NC}"
            echo -e "  ${BLUE}dps${NC}                  docker ps"
            echo -e "  ${BLUE}dc${NC}                   docker-compose"
            echo -e "  ${BLUE}dcu${NC}                  docker-compose up"
            echo -e "  ${BLUE}dcd${NC}                  docker-compose down"
            echo ""

            echo -e "${YELLOW}═══ TigerBeetle (Financial Database) ═══${NC}"
            echo -e "  ${BLUE}tigerbeetle version${NC}  Show TigerBeetle version"
            echo -e "  ${BLUE}tigerbeetle format --cluster=<id> --replica=<id> <file>${NC}"
            echo -e "                       Format data file for new replica"
            echo -e "  ${BLUE}tigerbeetle start --addresses=<addr> <file>${NC}"
            echo -e "                       Start TigerBeetle server"
            echo ""
            echo -e "  ${GREEN}Common Usage:${NC}"
            echo -e "  ${BLUE}# Format replica${NC}"
            echo -e "  ${BLUE}tigerbeetle format --cluster=0 --replica=0 --replica-count=1 0_0.tigerbeetle${NC}"
            echo ""
            echo -e "  ${BLUE}# Start server${NC}"
            echo -e "  ${BLUE}tigerbeetle start --addresses=3000 0_0.tigerbeetle${NC}"
            echo ""
            echo -e "  ${GREEN}Projects:${NC}"
            echo -e "  ${BLUE}~/code/allocator-one-tigerbeetle${NC}"
            echo -e "  ${BLUE}~/code/tigerbeetle-poc${NC}"
            echo -e "  ${BLUE}~/code/tigerbeetle-infrastructure${NC}"
            echo ""

            echo -e "${YELLOW}═══ Claude Code ═══${NC}"
            echo -e "  ${BLUE}claude${NC}               Start Claude Code session"
            echo -e "  ${BLUE}claude --continue${NC}    Resume last conversation"
            echo -e "  ${BLUE}claude --resume${NC}      Choose conversation to resume"
            echo -e "  ${BLUE}claude mcp list${NC}      List MCP servers"
            echo -e "  ${BLUE}claude mcp add${NC}       Add MCP server (wizard)"
            echo -e "  ${BLUE}claude mcp remove <name>${NC}  Remove MCP server"
            echo -e "  ${BLUE}/help${NC}                Show Claude Code help (inside session)"
            echo -e "  ${BLUE}/model${NC}               Switch model (inside session)"
            echo -e "  ${BLUE}/resume${NC}              Resume conversation (inside session)"
            echo ""
            echo -e "  ${GREEN}MCP Management Scripts:${NC}"
            echo -e "  ${BLUE}claude-mcps on/off${NC}   Manage global MCPs"
            echo -e "  ${BLUE}claude-tidewave auto${NC} Auto-configure Tidewave MCP"
            echo ""

            echo -e "${YELLOW}═══ Python/Conda/uv ═══${NC}"
            echo -e "  ${GREEN}Conda:${NC}"
            echo -e "  ${BLUE}conda env list${NC}       List all environments"
            echo -e "  ${BLUE}conda create -n <name>${NC}  Create environment"
            echo -e "  ${BLUE}conda activate <name>${NC}   Activate environment"
            echo -e "  ${BLUE}conda deactivate${NC}     Deactivate environment"
            echo -e "  ${BLUE}conda install <pkg>${NC}  Install package"
            echo ""
            echo -e "  ${GREEN}uv (Fast Python Package Manager):${NC}"
            echo -e "  ${BLUE}uv init${NC}              Initialize new Python project"
            echo -e "  ${BLUE}uv venv${NC}              Create virtual environment"
            echo -e "  ${BLUE}uv pip install <pkg>${NC} Install package (10-100x faster than pip)"
            echo -e "  ${BLUE}uv pip compile requirements.in${NC}  Generate locked dependencies"
            echo -e "  ${BLUE}uv pip sync requirements.txt${NC}    Install exact versions"
            echo -e "  ${BLUE}uv run <cmd>${NC}         Run command in project environment"
            echo -e "  ${BLUE}uv tool install <pkg>${NC}  Install CLI tool globally"
            echo ""
            echo -e "  ${GREEN}Traditional pip/venv Aliases:${NC}"
            echo -e "  ${BLUE}venv${NC}                 Create venv in current dir"
            echo -e "  ${BLUE}va${NC}                   Activate venv"
            echo -e "  ${BLUE}vd${NC}                   Deactivate venv"
            echo -e "  ${BLUE}pip install <pkg>${NC}    Install package with pip"
            echo -e "  ${BLUE}pip freeze > requirements.txt${NC}  Export dependencies"
            echo ""

            echo -e "${YELLOW}═══ Fly.io ═══${NC}"
            echo -e "  ${BLUE}fly launch${NC}           Create new Fly app"
            echo -e "  ${BLUE}fly deploy${NC}           Deploy app"
            echo -e "  ${BLUE}fly logs${NC}             Tail app logs"
            echo -e "  ${BLUE}fly ssh console${NC}      SSH into app"
            echo -e "  ${BLUE}fly status${NC}           Check app status"
            echo -e "  ${BLUE}fly apps list${NC}        List all apps"
            echo -e "  ${BLUE}fly postgres create${NC}  Create Postgres database"
            echo ""

            echo -e "${YELLOW}═══ Dev Session Manager ═══${NC}"
            echo -e "  ${BLUE}dev <name>${NC}           Create new dev session"
            echo -e "  ${BLUE}dev attach <name>${NC}    Attach to existing session"
            echo -e "  ${BLUE}dev ls${NC}               List all dev sessions"
            echo -e "  ${BLUE}dev kill <name>${NC}      Kill a dev session"
            echo -e "  ${BLUE}dev reload${NC}           Reload dev.zsh configuration"
            echo -e "  ${BLUE}dev help${NC}             Show dev commands"
            echo -e "  ${BLUE}dev tmux${NC}             Tmux reference"
            echo -e "  ${BLUE}dev ref${NC}              This reference"
            echo ""
            echo -e "${YELLOW}═══ Tmuxifier (Project Sessions) ═══${NC}"
            echo -e "  ${BLUE}aos${NC}                  Load allocator-one session"
            echo -e "  ${BLUE}aoa${NC}                  Load allocator-one-accounting session"
            echo -e "  ${BLUE}aot${NC}                  Load allocator-one-tigerbeetle session"
            echo ""
            echo -e "${YELLOW}═══ Tmux (General) ═══${NC}"
            echo -e "  ${BLUE}tma${NC}                  Attach to last tmux session"
            echo -e "  ${BLUE}tmls${NC}                 List all tmux sessions"
            echo -e "  ${BLUE}tks <name>${NC}           Kill specific session"
            echo ""

            echo -e "${YELLOW}═══ Neovim ═══${NC}"
            echo -e "  ${BLUE}nvim <file>${NC}          Open file"
            echo -e "  ${BLUE}nvim .${NC}               Open current directory"
            echo -e "  ${BLUE}v <file>${NC}             Alias for nvim"
            echo -e "  ${BLUE}nvid${NC}                 Navigate to nvim config"
            echo ""

            echo -e "${GREEN}Tip: Run 'dev tmux' for tmux commands${NC}"
            echo ""
            ;;

        "")
            echo -e "${RED}Usage: dev <command> [args]${NC}"
            echo -e "${YELLOW}Run 'dev help' for more information${NC}"
            return 1
            ;;

        *)
            # Create/attach to session
            if ! _dev_validate_name "$1"; then
                return 1
            fi

            local session_name=$(_dev_normalize_session_name "$1")
            local display_name=$(_dev_display_name "$session_name")

            # Check if session already exists
            if tmux has-session -t "$session_name" 2>/dev/null; then
                echo -e "${YELLOW}⚠ Session '${display_name}' already exists!${NC}"
                read -p "$(echo -e ${GREEN}"Attach to it? (y/n) "${NC})" choice
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

            # No welcome message - keep the editor window clean
            # Users can type 'dev help' if they need assistance

            # Attach to the session
            echo -e "${BLUE}→${NC} Created 7 windows, starting at editor"
            tmux attach -t "$session_name"
            ;;
    esac
}
