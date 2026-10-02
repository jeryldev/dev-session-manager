#!/usr/bin/env bats
# Workspace identity (plan Phase 4): each grid tab's popups and agent follow
# the workspace, not the window's name, its directory, or the tmux server.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    isolate_git
}

teardown() {
    teardown_tmux
}

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

grid_with_feat() {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    REPO="$repo"
}

tab_option() { tmux show-options -w -t "=dev-myrepo-grid:$1" -v "$2"; }

pane_of() { tmux display-message -p -t "$1" '#{pane_id}'; }

# Press a popup key the way tmux does: run-shell expands the formats in the
# context of the pane it targets. display-popup then fails for want of a
# client, after the popup session exists.
# The script comes from the function the binding is made with, not parsed
# back out of list-keys: tmux versions escape that listing differently.
press() {
    local target="$1" key="$2" script
    case "$key" in
        j) script="$(zsh -c 'source "$1" 2>/dev/null; _dev_popup_script term "${SHELL:-zsh}"' _ "$DEV_ZSH" </dev/null)" ;;
        *) echo "press: no script for key $key" >&2; return 1 ;;
    esac
    [ -n "$script" ]
    tmux run-shell -t "$target" "$script" 2>/dev/null || true
}

ai_sessions() { tmux list-sessions -F '#{session_name}' | grep '^ai-' | sort; }

agent_command() {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_agent_command '$1'" </dev/null
}

# ─── Stamps (US-13, R2) ───

@test "each grid tab gets a short workspace id" {
    grid_with_feat
    [[ "$(tab_option 1 @dev_ws_id)" =~ ^myrepo-[0-9a-f]{4}$ ]]
    [[ "$(tab_option 2 @dev_ws_id)" =~ ^myrepo-feat-[0-9a-f]{4}$ ]]
}

@test "each grid tab gets an agent session id, a UUID" {
    grid_with_feat
    [[ "$(tab_option 1 @dev_agent_sid)" =~ $UUID_RE ]]
    [[ "$(tab_option 2 @dev_agent_sid)" =~ $UUID_RE ]]
    [ "$(tab_option 1 @dev_agent_sid)" != "$(tab_option 2 @dev_agent_sid)" ]
}

@test "the ids are derived, so a rebuilt grid gets the same ones" {
    # US-29.1: after a reboot the grid is rebuilt from disk and the agent
    # resumes — there is no save file to go stale.
    grid_with_feat
    local id sid; id="$(tab_option 2 @dev_ws_id)"; sid="$(tab_option 2 @dev_agent_sid)"
    tmux kill-server
    run_grid "$REPO"
    [ "$(tab_option 2 @dev_ws_id)" = "$id" ]
    [ "$(tab_option 2 @dev_agent_sid)" = "$sid" ]
}

@test "a tab added later is stamped too" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    run zsh -c "cd '$repo' && source '$DEV_ZSH' 2>/dev/null; dev grid add fix-1" </dev/null
    [[ "$(tab_option 2 @dev_ws_id)" =~ ^myrepo-fix-1-[0-9a-f]{4}$ ]]
    [[ "$(tab_option 2 @dev_agent_sid)" =~ $UUID_RE ]]
}

# ─── Popups follow the workspace (US-13) ───

@test "a grid tab's popup is named by its workspace id" {
    grid_with_feat
    press '=dev-myrepo-grid:2' j
    [ "$(tmux list-sessions -F '#{session_name}' | grep '^term-')" = "term-$(tab_option 2 @dev_ws_id)" ]
}

@test "renaming the tab or changing directory reaches the same popup" {
    # US-13.1/13.2
    grid_with_feat
    press '=dev-myrepo-grid:2' j
    tmux rename-window -t '=dev-myrepo-grid:2' renamed
    # The pane's shell restarted in / stands in for a cd: on tmux 3.7b the
    # first send-keys after a popup press fails with "no current client".
    local pane; pane="$(pane_of '=dev-myrepo-grid:2')"
    tmux respawn-pane -k -t "$pane" -c /
    [ "$(tmux display-message -p -t "$pane" '#{pane_current_path}')" = "/" ]
    press '=dev-myrepo-grid:2' j
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^term-')" -eq 1 ]
}

@test "a popup opened inside a popup belongs to the same workspace" {
    # US-13.3: before, this nested into term-term-dev-...
    grid_with_feat
    press '=dev-myrepo-grid:2' j
    local popup; popup="$(tmux list-sessions -F '#{session_name}' | grep '^term-')"
    press "=${popup}:" j
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^term-')" -eq 1 ]
}

@test "a popup inside a non-grid window's popup does not nest either" {
    start_isolated_server dev-plain
    # A fixed name: tmux's automatic one follows the running command, and can
    # change between the key press and the check under load.
    tmux rename-window -t '=dev-plain:' plain
    zsh -c "source '$DEV_ZSH'" </dev/null
    press '=dev-plain:' j
    local popup; popup="$(tmux list-sessions -F '#{session_name}' | grep '^term-')"
    [ "$popup" = "term-dev-plain-0-plain" ]
    press "=${popup}:" j
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^term-')" -eq 1 ]
}

@test "a popup is not mistaken for another whose name starts the same" {
    # B9 again, one level down: has-session prefix-matched popup names.
    start_isolated_server dev-plain
    zsh -c "source '$DEV_ZSH'" </dev/null
    # Same window index, so the two popup names differ only in their tail:
    # term-dev-plain-0-edit is a prefix of term-dev-plain-0-edit2.
    tmux rename-window -t '=dev-plain:' edit2
    press '=dev-plain:' j
    tmux rename-window -t '=dev-plain:' edit
    press '=dev-plain:' j
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^term-')" -eq 2 ]
}

# ─── The agent command (US-12, US-24, D18, R2) ───

@test "a grid tab's claude resumes its own session, or starts it" {
    # US-24.8 / R2: --resume first, because --session-id refuses an id
    # that already exists.
    grid_with_feat
    local sid; sid="$(tab_option 2 @dev_agent_sid)"
    agent_command "$(pane_of '=dev-myrepo-grid:2')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude --enable-auto-mode --resume '$sid' 2>"*"|| claude --enable-auto-mode --session-id '$sid' || cat "* ]]
}

@test "the agent starts in its workspace, wherever the pane has wandered" {
    grid_with_feat
    agent_command "$(pane_of '=dev-myrepo-grid:2')"
    # `|| exit 1`, not `&&`: an agent started in the wrong directory is
    # worse than none.
    [[ "$output" == "cd '$CODE/myrepo-feat' || exit 1; "* ]]
}

@test "outside a grid the agent is plain claude, as before" {
    start_isolated_server dev-plain
    agent_command "$(pane_of '=dev-plain:')"
    [[ "$output" == *"claude --enable-auto-mode"* ]]
    [[ "$output" != *"--resume"* ]]
}

@test "another agent is not handed claude's flags" {
    # US-12.1 (B3)
    grid_with_feat
    export DEV_AI_CMD=codex
    agent_command "$(pane_of '=dev-myrepo-grid:2')"
    [[ "$output" == *"codex"* ]]
    [[ "$output" != *"--enable-auto-mode"* ]]
    [[ "$output" != *"--resume"* ]]
}

@test "DEV_AI_ARGS replaces the default flags" {
    # US-12.3
    start_isolated_server dev-plain
    export DEV_AI_ARGS="--model opus"
    agent_command "$(pane_of '=dev-plain:')"
    [[ "$output" == *"claude --model opus"* ]]
    [[ "$output" != *"--enable-auto-mode"* ]]
}

@test "no ssh-add runs unless a key is configured" {
    # US-12.4 (B4): it used to run behind the user's back.
    start_isolated_server dev-plain
    agent_command "$(pane_of '=dev-plain:')"
    [[ "$output" != *"ssh-add"* ]]
}

@test "a configured ssh key is added first" {
    start_isolated_server dev-plain
    touch "$HOME/key"
    export DEV_SSH_KEY="$HOME/key"
    agent_command "$(pane_of '=dev-plain:')"
    [[ "$output" == "ssh-add '$HOME/key' "* ]]
}

@test "a configured ssh key that does not exist warns and is skipped" {
    # US-12.5
    start_isolated_server dev-plain
    export DEV_SSH_KEY="$HOME/missing"
    agent_command "$(pane_of '=dev-plain:')"
    [[ "$output" != *"ssh-add"* ]]
    [[ "$output" == *"echo"*"missing"* ]]
}

@test "a session's own agent command wins over the default" {
    # US-13.5 (D5): one global key, per-session answers.
    start_isolated_server dev-plain
    tmux set-option -t '=dev-plain:' @dev_ai_cmd aider
    agent_command "$(pane_of '=dev-plain:')"
    [[ "$output" == *"aider"* ]]
}

@test "a configured launcher starts the agent, with the workspace filled in" {
    # US-24.4 / D18: e.g. bin/agent-grid launch claude {ws}.
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="bin/launch {ws} {path} {sid}"
    agent_command "$(pane_of '=dev-myrepo-grid:2')"
    [[ "$output" == *"bin/launch '$(tab_option 2 @dev_ws_id)' '$CODE/myrepo-feat' '$(tab_option 2 @dev_agent_sid)'"* ]]
    [[ "$output" != *"claude"* ]]
}

@test "launcher values are quoted, so a path cannot run code" {
    local repo; repo="$(make_repo "my'repo")"
    run_grid "$repo"
    export DEV_AGENT_LAUNCH_CMD="printf %s {path}"
    agent_command "$(pane_of '=dev-my-repo-grid:1')"
    run sh -c "$output"
    [ "$output" = "$repo" ]
}

@test "the agent key runs the agent entry point, not a baked-in command" {
    # The popup's shell script carries no per-workspace values, so nothing
    # typed, named or configured is ever spliced into it.
    start_isolated_server dev-plain
    zsh -c "source '$DEV_ZSH'" </dev/null
    local binding; binding="$(tmux list-keys -T prefix | awk '$4 == "a"')"
    [[ "$binding" == *"__agent"* ]]
    [[ "$binding" != *"--enable-auto-mode"* ]]
}

# ─── Review fixes (2026-10-01) ───

@test "a directory name cannot run code through a popup key" {
    # The popup script handed #{pane_current_path} to sh in double quotes, so
    # a repo could name a directory that runs a command (via .dev-grid).
    local repo; repo="$(make_repo)"
    local evil="$CODE/x\$(true>$BATS_TEST_TMPDIR/pwned)"
    mkdir -p "$evil"
    printf '%s\n%s\n' "$repo" "$evil" > "$repo/.dev-grid"
    run_grid "$repo"
    press '=dev-myrepo-grid:2' j
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^term-')" -eq 1 ]
}

@test "an agent popup whose tab pane is gone still finds its workspace" {
    grid_with_feat
    local ws sid; ws="$(tab_option 2 @dev_ws_id)"; sid="$(tab_option 2 @dev_agent_sid)"
    tmux new-session -d -s "term-${ws}"
    tmux set-option -w -t "=term-${ws}:" @dev_ws_id "$ws"
    tmux set-option -w -t "=term-${ws}:" @dev_origin '%999'
    agent_command "$(pane_of "=term-${ws}:")"
    [[ "$output" == "cd '$CODE/myrepo-feat' || exit 1; "*"--resume '$sid'"* ]]
}

@test "a failing ssh-add is reported, not hidden" {
    start_isolated_server dev-plain
    touch "$HOME/key"
    export DEV_SSH_KEY="$HOME/key"
    agent_command "$(pane_of '=dev-plain:')"
    [[ "$output" == "ssh-add '$HOME/key' || echo "* ]]
}

@test "a session name cannot run code through a popup key either" {
    start_isolated_server "s\$(true>$BATS_TEST_TMPDIR/pwned)"
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    press "$(tmux list-panes -a -F '#{pane_id}' | head -1)" j
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "a grid tab's popups start in its workspace, wherever its shell has gone" {
    # Like its agent: a popup is named after the tab's workspace, so it must
    # open there; a cd into another project must not make tab 2's lazygit
    # that project's lazygit from then on.
    grid_with_feat
    local pane; pane="$(pane_of '=dev-myrepo-grid:2')"
    tmux respawn-pane -k -t "$pane" -c /
    press '=dev-myrepo-grid:2' j
    local popup; popup="$(tmux list-sessions -F '#{session_name}' | grep '^term-')"
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(tmux display-message -p -t "=${popup}:" '#{pane_current_path}')" = "$CODE/myrepo-feat" ] && break
        sleep 0.2
    done
    [ "$(tmux display-message -p -t "=${popup}:" '#{pane_current_path}')" = "$CODE/myrepo-feat" ]
}

@test "outside a grid a popup still starts where the shell is" {
    start_isolated_server dev-plain
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    tmux respawn-pane -k -t "$(pane_of '=dev-plain:')" -c /tmp
    press '=dev-plain:' j
    local popup; popup="$(tmux list-sessions -F '#{session_name}' | grep '^term-')"
    local i real; real="$(cd /tmp && pwd -P)"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(tmux display-message -p -t "=${popup}:" '#{pane_current_path}')" = "$real" ] && break
        sleep 0.2
    done
    [ "$(tmux display-message -p -t "=${popup}:" '#{pane_current_path}')" = "$real" ]
}
