# Per-window AI popup sessions

Date: 2026-02-22

## Problem

The v2.0 AI popup keybinding uses `hash(pane_current_path)` for session identity.
This means:

- All windows sharing the same directory (e.g., all 7 `dev` windows starting in `$DEV_HOME_DIR`) get the same AI session
- Changing directory with `cd` silently changes which AI session you get
- `md5 -q` spawns 3 subprocesses per keypress and is macOS-only

## Decision

Change session identity from `hash(pane_current_path)` to `#{session_name}-#{window_index}-#{window_name}-claude`.

## Keybinding

```bash
bind a run-shell '\
  SESSION="ai-#{session_name}-#{window_index}-#{window_name}-claude"; \
  tmux has-session -t "$SESSION" 2>/dev/null || \
  tmux new-session -d -s "$SESSION" -c "#{pane_current_path}" "claude"; \
  tmux display-popup -w 80% -h 80% -b single -E \
  "tmux attach-session -t $SESSION"'
```

## Session naming examples

| Context | Session name |
|---------|-------------|
| dev-myproject, window 5 (editor) | ai-dev-myproject-5-editor-claude |
| dev-myproject, window 4 (testing) | ai-dev-myproject-4-testing-claude |
| dev-other, window 5 (editor) | ai-dev-other-5-editor-claude |

## Performance

| Metric | Before (v2.0) | After |
|--------|---------------|-------|
| Subprocesses per keypress | 3 (echo, md5, cut) | 0 |
| Pipes | 2 | 0 |
| Cross-platform | No (md5 -q macOS-only) | Yes |
| Session names | Opaque hash ai-a1b2c3d4 | Readable ai-dev-myproject-5-editor-claude |

## Lifecycle

- `prefix + d` (detach): closes popup, session stays alive, reopen resumes
- `/exit` in AI tool: destroys the process, session destroyed, next open starts fresh

## Alternatives considered

1. **hash(session_name + window_name)** - Dropped: loses window index, less descriptive
2. **window_name + command only** - Dropped: collides across projects with same window names
3. **hash(session + window + directory)** - Dropped: `cd` changes session identity again
