# Dev session manager

A lightweight zsh utility for quickly bootstrapping tmux development sessions with pre-configured windows.

## Features

- **Quick session creation**: `dev myproject` creates a full 7-window tmux session
- **Pre-configured windows**: frontend, backend, database, testing, editor, scratch, extra
- **Session management**: list, attach, and kill sessions easily
- **Prerequisite checking**: shows checkmarks for installed dependencies
- **Built-in references**: tmux keybindings cheatsheet

## Requirements

- **zsh**: your shell (comes with macOS, install on Linux with your package manager)
- **tmux**: terminal multiplexer

```bash
# macOS
brew install tmux

# Ubuntu/Debian
sudo apt install tmux

# Fedora
sudo dnf install tmux
```

## Installation

### Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/jeryldev/dev-session-manager/main/install.sh | bash
```

### Manual install

```bash
git clone https://github.com/jeryldev/dev-session-manager.git
cd dev-session-manager
./install.sh
```

After installation, restart your terminal or run:

```bash
source ~/.zshrc
```

## Usage

### Create a session

```bash
dev myproject
```

This creates a tmux session named `dev-myproject` with 7 windows and attaches to it.

### List sessions

```bash
dev ls
```

### Attach to an existing session

```bash
dev attach myproject
```

### Kill a session

```bash
dev kill myproject
```

### Show help with prerequisite status

```bash
dev help
```

Output shows checkmarks for installed prerequisites:

```
╔════════════════════════════════════════════════════════╗
║                  Dev session manager                   ║
╚════════════════════════════════════════════════════════╝

Prerequisites:
  ✓ zsh (5.9)
  ✓ tmux (3.4)

Commands:
  dev <name>          Create or attach to a dev session
  ...
```

### Show tmux reference

```bash
dev tmux
```

### Show version

```bash
dev version
```

## Session layout

When you create a session with `dev <name>`, it creates 7 windows:

| Window | Name     | Purpose                   |
|--------|----------|---------------------------|
| 1      | frontend | Frontend dev server       |
| 2      | backend  | Backend/API server        |
| 3      | database | Database connections      |
| 4      | testing  | Running tests             |
| 5      | editor   | Code editor (starts here) |
| 6      | scratch  | Scratch/notes             |
| 7      | extra    | Extra terminal            |

All windows start in your `$DEV_HOME_DIR` (defaults to `~/code`).

## Configuration

Set `DEV_HOME_DIR` in your `.zshrc` before the source line to change the default directory:

```bash
export DEV_HOME_DIR="$HOME/projects"

# Dev session manager
[[ -f ~/.config/zsh/dev.zsh ]] && source ~/.config/zsh/dev.zsh
```

## Uninstall

```bash
rm ~/.config/zsh/dev.zsh
```

Then remove this line from `~/.zshrc`:

```bash
[[ -f ~/.config/zsh/dev.zsh ]] && source ~/.config/zsh/dev.zsh
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

Jeryl Estopace ([@jeryldev](https://github.com/jeryldev))
