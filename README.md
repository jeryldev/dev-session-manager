# Dev Session Manager

A lightweight zsh utility for quickly bootstrapping tmux development sessions with pre-configured windows.

## Features

- **Quick session creation** - `dev myproject` creates a full 7-window tmux session
- **Pre-configured windows** - frontend, backend, database, testing, editor, scratch, extra
- **Session management** - list, attach, kill sessions easily
- **Built-in references** - tmux keybindings and dev tools cheatsheets

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/jeryldev/dev-session-manager/main/install.sh | bash
```

### Manual Install

```bash
git clone https://github.com/jeryldev/dev-session-manager.git
cd dev-session-manager
./install.sh
```

### Requirements

- **zsh** - Your shell
- **tmux** - Terminal multiplexer (`brew install tmux` on macOS)

## Usage

```bash
# Create or attach to a dev session
dev myproject

# List all dev sessions
dev ls

# Attach to existing session
dev attach myproject

# Kill a session
dev kill myproject

# Show help
dev help

# Tmux keybindings reference
dev tmux

# Development tools quick reference
dev ref

# Reload configuration
dev reload
```

## Session Layout

When you create a session with `dev <name>`, it creates 7 windows:

| Window | Name      | Purpose                    |
|--------|-----------|----------------------------|
| 1      | frontend  | Frontend dev server        |
| 2      | backend   | Backend/API server         |
| 3      | database  | Database connections       |
| 4      | testing   | Running tests              |
| 5      | editor    | Code editor (starts here)  |
| 6      | scratch   | Scratch/notes              |
| 7      | extra     | Extra terminal             |

All windows start in your `$DEV_HOME_DIR` (defaults to `~/code`).

## Configuration

Edit `~/.config/zsh/dev.zsh` to customize:

```bash
# Session name prefix (default: "dev-")
DEV_SESSION_PREFIX="dev-"

# Default starting directory (default: ~/code)
DEV_DEFAULT_DIR="${DEV_HOME_DIR:-~/code}"
```

You can also set `DEV_HOME_DIR` in your `.zshrc` before the dev.zsh source line.

## Tmux Prefix

The `dev tmux` reference assumes `Ctrl+p` as the tmux prefix. If you use a different prefix (like `Ctrl+b`), adjust accordingly.

## Uninstall

```bash
rm ~/.config/zsh/dev.zsh
# Remove the source line from ~/.zshrc:
# [[ -f ~/.config/zsh/dev.zsh ]] && source ~/.config/zsh/dev.zsh
```

## License

MIT License - see [LICENSE](LICENSE) for details.
