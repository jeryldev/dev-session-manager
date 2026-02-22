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

## AI coding popup (v2.1)

Open a persistent AI coding assistant in a tmux popup. Each tmux window gets its own session, so you can have separate conversations for frontend, testing, editing, etc.

### Setup

No extra configuration needed. The `prefix + a` keybinding is set up automatically when `dev.zsh` is sourced inside a tmux session.

If you previously added the AI popup keybinding to your `.tmux.conf` (v2.0), you can safely remove it. The keybinding is now managed by `dev.zsh`.

### Usage

- **Open**: `prefix + a` opens an 80% x 80% popup with your AI assistant
- **Close**: `prefix + d` (detach) closes the popup, session stays alive
- **Reopen**: `prefix + a` resumes exactly where you left off

Each tmux window gets its own persistent session. The session name is derived from your tmux session, window number, window name, and AI tool:

| Window | Session name |
|--------|-------------|
| `dev-myproject` window 5 (editor) | `ai-dev-myproject-5-editor-claude` |
| `dev-myproject` window 4 (testing) | `ai-dev-myproject-4-testing-claude` |
| `dev-other` window 5 (editor) | `ai-dev-other-5-editor-claude` |

### Behavior

- **Detach** (`prefix + d`): closes the popup. The AI session stays alive in the background. Pressing `prefix + a` again resumes exactly where you left off.
- **Exit** (type `/exit` in the AI tool): terminates the AI process. Since the AI tool is the only process in the session, the session is destroyed. The next `prefix + a` starts a fresh session.

Changing directories with `cd` does not affect which session you get. The session is tied to the tmux window, not the filesystem path.

### Customization

The keybinding uses `claude` by default. Set `DEV_AI_CMD` in your `.zshrc` before the source line to use a different AI tool:

```bash
export DEV_AI_CMD="aider"

# Dev session manager
[[ -f ~/.config/zsh/dev.zsh ]] && source ~/.config/zsh/dev.zsh
```

Supported tools:

| Tool | DEV_AI_CMD |
|------|------------|
| [Claude Code](https://github.com/anthropics/claude-code) | `claude` (default) |
| [OpenAI Codex](https://github.com/openai/codex) | `codex` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` |
| [Aider](https://github.com/paul-gauthier/aider) | `aider` |

## Configuration

Set these variables in your `.zshrc` before the source line:

| Variable | Default | Description |
|----------|---------|-------------|
| `DEV_HOME_DIR` | `~/code` | Base directory for new session windows |
| `DEV_AI_CMD` | `claude` | AI coding tool for the popup (`prefix + a`) |

```bash
export DEV_HOME_DIR="$HOME/projects"
export DEV_AI_CMD="claude"

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
