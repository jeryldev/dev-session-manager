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

### Homebrew (recommended)

```bash
brew tap jeryldev/tap
brew install dev-session-manager
```

### Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/jeryldev/dev-session-manager/main/install.sh | bash
source ~/.zshrc
```

### Manual install

```bash
git clone https://github.com/jeryldev/dev-session-manager.git
cd dev-session-manager
./install.sh
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

## AI coding popup (v2.0)

Open a persistent AI coding assistant in a tmux popup. The session stays alive when the popup is closed, so you can resume your conversation anytime.

### Setup

Add to your `.tmux.conf`:

```bash
# AI coding popup (dev-session-manager)
# Runs in a persistent detached session. Popup attaches to it.
# Close with prefix+d (detach). Reopen with prefix+a (session stays alive).
bind a run-shell '\
  SESSION="ai-$(echo #{pane_current_path} | md5 -q | cut -c1-8)"; \
  tmux has-session -t "$SESSION" 2>/dev/null || \
  tmux new-session -d -s "$SESSION" -c "#{pane_current_path}" "claude"; \
  tmux display-popup -w 80% -h 80% -b single -E \
  "tmux attach-session -t $SESSION"'
```

Then reload tmux config (`prefix + r` or `tmux source-file ~/.tmux.conf`).

### Usage

- **Open**: `prefix + a` opens an 80% x 80% popup with your AI assistant
- **Close**: `prefix + d` (detach) closes the popup, session stays alive
- **Reopen**: `prefix + a` resumes exactly where you left off

Each directory gets its own persistent session (named by directory hash).

### Customization

The keybinding uses `claude` by default. To use a different AI coding tool, replace `"claude"` in the keybinding with your preferred command:

| Tool | Command |
|------|---------|
| [Claude Code](https://github.com/anthropics/claude-code) | `"claude"` |
| [OpenAI Codex](https://github.com/openai/codex) | `"codex"` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `"gemini"` |
| [Aider](https://github.com/paul-gauthier/aider) | `"aider"` |

You can also customize the popup appearance:

| Option | Default | Description |
|--------|---------|-------------|
| `-w` | `80%` | Popup width |
| `-h` | `80%` | Popup height |
| `-b` | `single` | Border style (`single`, `double`, `rounded`, `padded`, `none`) |

## Configuration

Set `DEV_HOME_DIR` in your `.zshrc` before the source line to change the default directory:

```bash
export DEV_HOME_DIR="$HOME/projects"

# Dev session manager
[[ -f ~/.config/zsh/dev.zsh ]] && source ~/.config/zsh/dev.zsh
```

## Uninstall

### Homebrew

```bash
brew uninstall dev-session-manager
brew untap jeryldev/tap
```

### Manual

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
