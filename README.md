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

### Optional tools (for popup features)

| Tool | Popup keybinding | Install |
|------|-----------------|---------|
| [Claude Code](https://github.com/anthropics/claude-code) | `prefix + a` | `brew install claude-code` |
| [kb](https://github.com/jeryldev/kb) | `prefix + k` | `brew install jeryldev/tap/kb` |
| [lazygit](https://github.com/jesseduffield/lazygit) | `prefix + g` | `brew install lazygit` |

These are detected automatically. Run `dev help` to see which are installed.

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

## Popup windows (v2.1)

Persistent popup windows for AI coding, kanban boards, git management, and a scratch terminal. Each tmux window gets its own popup session, so you can have separate contexts per window.

### Keybindings

| Keybinding | Popup | Tool |
|------------|-------|------|
| `prefix + a` | AI coding assistant | claude (configurable) |
| `prefix + k` | Kanban board | kb |
| `prefix + g` | Git UI | lazygit |
| `prefix + j` | Terminal | `$SHELL` (zsh fallback) |

All popups open at 90% x 90% with a single border.

### Setup

No extra configuration needed. Keybindings are set up automatically when `dev.zsh` is sourced inside a tmux session. Optional tools (kb, lazygit) are only bound if installed.

If you previously added the AI popup keybinding to your `.tmux.conf` (v2.0), you can safely remove it. The keybinding is now managed by `dev.zsh`.

Use `dev reload` to refresh keybindings after installing a new tool.

### Usage

- **Open**: `prefix + a/k/g/j` opens the popup
- **Close**: `prefix + d` (detach) closes the popup, session stays alive
- **Reopen**: same keybinding resumes exactly where you left off

### Session identity

Each tmux window gets its own persistent session. The session name is derived from your tmux session, window number, and window name:

| Popup | Window | Session name |
|-------|--------|-------------|
| AI | `dev-myproject` window 5 (editor) | `ai-dev-myproject-5-editor-claude` |
| AI | `dev-myproject` window 4 (testing) | `ai-dev-myproject-4-testing-claude` |
| Kanban | `dev-myproject` window 5 (editor) | `kb-dev-myproject-5-editor` |
| Git | `dev-myproject` window 5 (editor) | `lg-dev-myproject-5-editor` |
| Terminal | `dev-myproject` window 5 (editor) | `term-dev-myproject-5-editor` |

### Behavior

- **Detach** (`prefix + d`): closes the popup. The session stays alive in the background. Pressing the keybinding again resumes exactly where you left off.
- **Exit** (type `/exit` or `exit`): terminates the process. Since the tool is the only process in the session, the session is destroyed. The next keybinding press starts a fresh session.

Changing directories with `cd` does not affect which session you get. The session is tied to the tmux window, not the filesystem path.

### AI tool customization

The AI popup uses `claude` by default. Set `DEV_AI_CMD` to use a different tool — see [Configuration](#configuration) for where, which depends on how you installed.

Supported tools:

| Tool | DEV_AI_CMD |
|------|------------|
| [Claude Code](https://github.com/anthropics/claude-code) | `claude` (default) |
| [OpenAI Codex](https://github.com/openai/codex) | `codex` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` |
| [Aider](https://github.com/paul-gauthier/aider) | `aider` |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DEV_HOME_DIR` | `~/code` | Base directory for new session windows |
| `DEV_AI_CMD` | `claude` | AI coding tool for the popup (`prefix + a`) |

Where you set them depends on how you installed.

### Homebrew

`dev` is a command, so it only sees variables that are **exported** in your shell. Add them anywhere in `.zshrc`:

```bash
export DEV_HOME_DIR="$HOME/projects"
export DEV_AI_CMD="aider"
```

Open a new shell, then run `dev reload` inside tmux (or create or attach to a session) so the popup keys pick up the change.

### Quick install or manual install

`dev.zsh` is sourced from `.zshrc` and binds the popup keys as it loads, so set the variables **before the source line**:

```bash
export DEV_HOME_DIR="$HOME/projects"
export DEV_AI_CMD="aider"

# Dev session manager
[[ -f ~/.config/zsh/dev.zsh ]] && source ~/.config/zsh/dev.zsh
```

A value set after the source line is not used by the popup keys until the next `dev reload`, `dev <name>` or `dev attach`.

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

[Jeryl Donato Estopace](https://www.linkedin.com/in/jeryldev/) ([@jeryldev](https://github.com/jeryldev))
