#!/usr/bin/env bats
# `dev agent reset`: a tab's next agent starts a new conversation. A tab's
# conversation id is derived from its path, so /exit and a reboot resume it;
# reset moves the tab to a new id that a rebuilt grid derives again.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS
    export DEV_AGENT_LAUNCH_CMD="exec sleep 600"
    REPO="$(make_repo)"
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$REPO"
}

teardown() {
    teardown_tmux
}

agent_cmd() {
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev agent "$@"' _ "$REPO" "$DEV_ZSH" "$@" </dev/null
}

sid() { tmux show-options -w -t "=dev-myrepo-grid:$1" -qv @dev_agent_sid; }

running() {
    local ws; ws="$(tmux show-options -w -t "=dev-myrepo-grid:$1" -qv @dev_ws_id)"
    tmux list-windows -a -F '#{@dev_popup_kind}|#{@dev_ws_id}' | grep -qx "ai|${ws}"
}

@test "reset gives the tab a new conversation, and a rebuilt grid keeps it" {
    local before; before="$(sid 2)"
    agent_cmd reset 2
    [ "$status" -eq 0 ]
    local after; after="$(sid 2)"
    [ -n "$after" ]
    [ "$after" != "$before" ]
    tmux kill-session -t '=dev-myrepo-grid'
    run_grid "$REPO"
    [ "$(sid 2)" = "$after" ]
}

@test "reset leaves the other tabs' conversations alone" {
    local one; one="$(sid 1)"
    agent_cmd reset 2
    [ "$(sid 1)" = "$one" ]
}

@test "each reset is a new conversation, never an earlier one" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    local second; second="$(sid 2)"
    agent_cmd reset 2
    [ "$(sid 2)" != "$second" ]
    [ "$(sid 2)" != "$first" ]
}

@test "a running agent is not reset without --force" {
    agent_cmd start 2
    local before; before="$(sid 2)"
    agent_cmd reset 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"--force"* ]]
    [ "$(sid 2)" = "$before" ]
    running 2
}

@test "--force stops the running agent and resets it" {
    agent_cmd start 2
    local before; before="$(sid 2)"
    agent_cmd reset 2 --force
    [ "$status" -eq 0 ]
    [ "$(sid 2)" != "$before" ]
    ! running 2
}

@test "the new conversation reaches the agent's command line" {
    local original; original="$(sid 2)"
    agent_cmd reset 2
    local fresh; fresh="$(sid 2)"
    [ "$fresh" != "$original" ]
    export DEV_AGENT_LAUNCH_CMD="echo sid={sid}; exec sleep 600"
    agent_cmd start 2
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -qv @dev_ws_id)"
    local i
    for i in $(seq 1 25); do
        tmux capture-pane -p -t "=ai-${ws}-claude:" | grep -q "sid=${fresh}" && return 0
        sleep 0.2
    done
    return 1
}

@test "reset says how to go back to the old conversation" {
    local old; old="$(sid 2)"
    agent_cmd reset 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude --resume ${old}"* ]]
}

@test "a tab whose agent was stopped by reset has no agent, not a dead one" {
    agent_cmd start 2
    agent_cmd reset 2 --force
    [ "$status" -eq 0 ]
    agent_cmd status
    [[ "$output" =~ 2\ +myrepo-feat\ +feat\ +clean\ +none ]]
}

@test "reset --cmd agy switches the tab to agy, and plain reset returns it to default" {
    agent_cmd reset 2 --cmd agy
    [ "$status" -eq 0 ]
    [ "$(tmux show-options -w -t '=dev-myrepo-grid:2' -qv @dev_ai_cmd)" = "agy" ]
    [[ "$output" == *"agy"* ]]
    agent_cmd reset 2
    [ "$status" -eq 0 ]
    [ -z "$(tmux show-options -w -t '=dev-myrepo-grid:2' -qv @dev_ai_cmd)" ]
}

@test "after reset, an agy tab starts fresh without --continue once, then resumes with --continue" {
    unset DEV_AGENT_LAUNCH_CMD
    agent_cmd reset 2 --cmd agy
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_command "$2"' _ "$DEV_ZSH" "$pane" </dev/null
    [[ "$output" == *"agy --mode auto"* ]]
    [[ "$output" != *"--continue"* ]]
    # Once _dev_agent_exec marks the start, @dev_agent_fresh is cleared so later starts resume.
    tmux set-option -w -t '=dev-myrepo-grid:2' -u @dev_agent_fresh
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_command "$2"' _ "$DEV_ZSH" "$pane" </dev/null
    [[ "$output" == *"agy --mode auto --continue"* ]]
}
