# Dev session manager

A lightweight zsh utility for quickly bootstrapping tmux development sessions with pre-configured windows.

## Features

- **Workspace grid**: `dev` inside a git repo opens one tab per worktree, so each branch gets its own window and its own AI popup
- **Quick session creation**: `dev myproject` creates a 4-window tmux session
- **Configurable windows**: editor, server, test, shell by default; set `DEV_WINDOWS` to change them
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

This creates a tmux session named `dev-myproject` with 4 windows and attaches to it.

### Work on several branches at once

```bash
cd ~/code/myrepo
dev                     # or: dev grid
```

Inside a git repo, `dev` on its own opens that repo's grid: a tmux session named `dev-myrepo-grid`
with one tab per git worktree, the main checkout first. Each tab starts in its worktree, and
`prefix + a` in a tab opens that tab's own AI session. Run it from any worktree of the repo and it
finds the same grid; run it in another repo and you get that repo's grid.

```bash
dev grid add fix-login  # new worktree for the branch, opened as the next tab
dev grid status         # each tab's branch and uncommitted changes
```

When you add or remove worktrees outside dev, re-entering the grid tells you; nothing changes until
you ask:

```bash
dev grid sync           # a tab for each new worktree; existing tab numbers never change
dev grid prune          # close the tabs (and popups) of worktrees that were removed
dev grid kill           # close the whole grid; each takes --dry-run
```

### Agents in a grid

Each tab's `prefix + a` agent can also be driven from the command line — by you, or by another agent:

```bash
dev agent status              # every tab: branch, changes, and whether its agent is working, idle,
                              # waiting for an answer, dead, or not started (--json for scripts)
dev agent start 2             # start tab 2's agent: the same one prefix + a opens
dev agent send 2 "run the tests"         # typed, submitted, and confirmed to have arrived
dev agent send 2 --file brief.md         # long briefs go by file; one short line points at it
dev agent watch --notify      # one line per change (working → waiting, idle, dead, unknown), a
                              # heartbeat every 30 min, and a last line when it stops; --json too
```

`watch` runs `watch_cmd` (or `DEV_WATCH_CMD`) at each heartbeat and passes its output through, so a
repo can add its own checks — CI or review status, say.

`prefix + S` opens the grid's **coordinator**: one agent per grid, started in the repo root, whose job
is to brief and check on the tab agents with `dev agent ...` (it finds its grid through `DEV_GRID`).
`prefix + O` opens a read-only **overview** of every running tab agent, tiled; closing it closes it,
so the agents go back to their full size.

### Choosing the workspaces

By default the grid has a tab for every git worktree. A grid holds 9 tabs; with more, `dev grid` on a
terminal asks which to open and saves the choice in `.dev-grid` (added to `.git/info/exclude`, so it
stays yours). You can also:

```bash
dev grid --filter io --limit 4     # matching workspaces, then the first 4
dev grid --session mygrid          # build under another session name
```

`.dev-grid` lists one workspace per line, `path` or `path<TAB>label`; relative paths are from the repo
root, and `#` lines are comments. It is only ever read, never run. To compute the list instead, set
`grid_cmd` (`DEV_GRID_CMD`) to a command that prints those lines; if it fails, `dev grid` stops rather
than falling back to git.

`prefix + N` does the same as `dev grid add`, asking for the branch in a small popup. A grid holds up to
9 tabs, so `prefix + 1`-`9` always reaches them.

To create workspaces with your own tool instead of `git worktree add` — one that also sets up a
database or ports, for example — export a command; `{branch}` is replaced (quoted) with the branch name,
and the command's last line of output must be the new worktree's path:

```bash
export DEV_WORKTREE_CREATE_CMD='bin/agent-grid slot create {branch}'
```

If that command fails, no tab is added and dev does not fall back to `git worktree add`.

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

When you create a session with `dev <name>`, it creates 4 windows:

| Window | Name   | Purpose                   |
|--------|--------|---------------------------|
| 1      | editor | Code editor (starts here) |
| 2      | server | Dev server                |
| 3      | test   | Running tests             |
| 4      | shell  | Anything else             |

All windows start in your `$DEV_HOME_DIR` (defaults to `~/code`). To use your own list, set
`DEV_WINDOWS` to comma-separated names (letters, numbers, `-` and `_`; at most 9):

```bash
export DEV_WINDOWS=code,logs,shell
```

Versions before 2.4 created 7 windows (frontend, backend, database, testing, editor, scratch, extra);
`export DEV_WINDOWS=frontend,backend,database,testing,editor,scratch,extra` brings that back, opening
on frontend.

## Popup windows (v2.1)

Persistent popup windows for AI coding, kanban boards, git management, and a scratch terminal. Each tmux window gets its own popup session, so you can have separate contexts per window.

### Keybindings

| Keybinding | Popup | Tool |
|------------|-------|------|
| `prefix + a` | AI coding assistant | claude (configurable) |
| `prefix + k` | Kanban board | kb |
| `prefix + g` | Git UI | lazygit |
| `prefix + j` | Terminal | `$SHELL` (zsh fallback) |
| `prefix + N` | New branch tab in the grid | `dev grid add` (skipped if you bound `N` yourself) |
| `prefix + S` | The grid's coordinator agent | one per grid |
| `prefix + O` | Overview of the grid's agents | read-only, closed when dismissed |

All popups open at 90% x 90% with a single border.

Every key is configurable (`dev config set key_agent V`; also `key_term`, `key_git`, `key_kb`,
`key_new`, `key_coordinator`, `key_overview`). dev never takes a key you bound yourself: it leaves your binding alone, says which of its
keys it skipped, and `dev help` marks them `not bound`.

### Setup

No extra configuration needed. Keybindings are set up automatically when `dev.zsh` is sourced inside a tmux session. Optional tools (kb, lazygit) are only bound if installed.

If you previously added the AI popup keybinding to your `.tmux.conf` (v2.0), you can safely remove it. The keybinding is now managed by `dev.zsh`.

Use `dev reload` to refresh keybindings after installing a new tool.

### Usage

- **Open**: `prefix + a/k/g/j` opens the popup
- **Close**: `prefix + d` (detach) closes the popup, session stays alive
- **Reopen**: same keybinding resumes exactly where you left off

### Session identity

In a grid, each tab's popups belong to its worktree: renaming the tab, `cd`-ing elsewhere, or pressing
the key inside another popup all reach the same popup, and the AI popup resumes the same Claude
conversation even after the tmux server restarts and the grid is rebuilt.

Outside a grid, each tmux window gets its own persistent session. The session name is derived from your tmux session, window number, and window name:

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

The AI popup uses `claude` by default. Use `dev config set ai_cmd <tool>` (or `DEV_AI_CMD`) for a
different one; `--enable-auto-mode` is only added for claude. Earlier versions also ran
`ssh-add ~/.ssh/id_ed25519` silently before the tool; set `ssh_key` if you relied on that.

Supported tools:

| Tool | DEV_AI_CMD |
|------|------------|
| [Claude Code](https://github.com/anthropics/claude-code) | `claude` (default) |
| [OpenAI Codex](https://github.com/openai/codex) | `codex` |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gemini` |
| [Aider](https://github.com/paul-gauthier/aider) | `aider` |

## Configuration

The simplest way, the same for every install:

```bash
dev config set ai_cmd aider
dev config list          # every setting, its value, and where it came from
dev config unset ai_cmd
```

Settings live in `~/.config/dev-session-manager/config` (`key = value` lines). An exported environment
variable overrides the file for as long as it is set.

| Setting | Variable | Default | Description |
|---------|----------|---------|-------------|
| `home_dir` | `DEV_HOME_DIR` | `~/code` | Base directory for `dev <name>` windows |
| `windows` | `DEV_WINDOWS` | `editor,server,test,shell` | Windows `dev <name>` creates |
| `ai_cmd` | `DEV_AI_CMD` | `claude` | AI tool for `prefix + a` (one word) |
| `ai_args` | `DEV_AI_ARGS` | `--enable-auto-mode` for claude, none otherwise | Flags for the AI tool |
| `ssh_key` | `DEV_SSH_KEY` | unset | Key to `ssh-add` before the AI tool starts |
| `key_agent`, `key_term`, `key_git`, `key_kb`, `key_new` | `DEV_KEY_AGENT`, … | `a`, `j`, `g`, `k`, `N` | Popup keys (after `prefix`) |
| `agent_launch_cmd` | `DEV_AGENT_LAUNCH_CMD` | unset | Start grid agents with your own command; `{ws}`, `{path}`, `{sid}` are filled in |
| `worktree_create_cmd` | `DEV_WORKTREE_CREATE_CMD` | unset | Create `dev grid add` worktrees with your own command; `{branch}` is filled in |
| `watch_cmd` | `DEV_WATCH_CMD` | unset | Run at each `dev agent watch` heartbeat; its output becomes events |
| `grid_cmd` | `DEV_GRID_CMD` | unset | Print the grid's workspaces (`path<TAB>label` lines) instead of `.dev-grid` or git |

To use environment variables instead, where you set them depends on how you installed.

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
