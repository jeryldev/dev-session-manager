#!/usr/bin/env bats
# `dev agent resume`: a tab goes back to one of its earlier conversations, and
# keeps it. Every later start, a reboot and a rebuilt grid resume that one,
# until a reset or `dev grid kill --fresh` starts a new conversation.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS CLAUDE_CONFIG_DIR
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

@test "resume goes back to the conversation before the current one" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    agent_cmd resume 2
    [ "$status" -eq 0 ]
    [ "$(sid 2)" = "$first" ]
}

@test "a resumed conversation survives a rebuilt grid" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    agent_cmd resume 2
    tmux kill-session -t '=dev-myrepo-grid'
    run_grid "$REPO"
    [ "$(sid 2)" = "$first" ]
}

@test "resume takes an id from history" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    agent_cmd reset 2
    agent_cmd resume 2 "$first"
    [ "$status" -eq 0 ]
    [ "$(sid 2)" = "$first" ]
}

@test "an id that is not one of the tab's conversations is refused" {
    local other; other="$(sid 1)"
    agent_cmd reset 2
    local current; current="$(sid 2)"
    agent_cmd resume 2 "$other"
    [ "$status" -ne 0 ]
    [[ "$output" == *"dev agent history 2"* ]]
    [ "$(sid 2)" = "$current" ]
}

@test "a tab with no earlier conversation has nothing to resume" {
    local current; current="$(sid 2)"
    agent_cmd resume 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"no earlier conversation"* ]]
    [ "$(sid 2)" = "$current" ]
}

@test "resuming the current conversation changes nothing and says so" {
    agent_cmd reset 2
    local current; current="$(sid 2)"
    agent_cmd resume 2 "$current"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already"* ]]
    [ "$(sid 2)" = "$current" ]
}

@test "a running agent is not switched without --force" {
    agent_cmd reset 2
    agent_cmd start 2
    local current; current="$(sid 2)"
    agent_cmd resume 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"--force"* ]]
    [ "$(sid 2)" = "$current" ]
    running 2
}

@test "--force stops the running agent and switches it" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    agent_cmd start 2
    agent_cmd resume 2 --force
    [ "$status" -eq 0 ]
    [ "$(sid 2)" = "$first" ]
    ! running 2
}

@test "the resumed conversation reaches the agent's command line" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    agent_cmd resume 2
    export DEV_AGENT_LAUNCH_CMD="echo sid={sid}; exec sleep 600"
    agent_cmd start 2
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -qv @dev_ws_id)"
    local i
    for i in $(seq 1 25); do
        tmux capture-pane -p -t "=ai-${ws}-claude:" | grep -q "sid=${first}" && return 0
        sleep 0.2
    done
    return 1
}

@test "a reset after resume starts a new conversation, never a later one" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    local second; second="$(sid 2)"
    agent_cmd resume 2 "$first"
    agent_cmd reset 2
    [ "$(sid 2)" != "$first" ]
    [ "$(sid 2)" != "$second" ]
}

@test "grid kill --fresh after resume starts a new conversation, never a later one" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    local second; second="$(sid 2)"
    agent_cmd resume 2 "$first"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid kill --fresh' _ "$REPO" "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude --resume ${first}"* ]]
    run_grid "$REPO"
    [ "$(sid 2)" != "$first" ]
    [ "$(sid 2)" != "$second" ]
}

@test "history marks the resumed conversation current and the newer one later" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    local second; second="$(sid 2)"
    agent_cmd resume 2
    agent_cmd history 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"later"*"claude --resume ${second}"*"current"*"claude --resume ${first}"* ]]
}

@test "resume says what the tab will open and how to start it" {
    local first; first="$(sid 2)"
    agent_cmd reset 2
    agent_cmd resume 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"${first}"* ]]
    [[ "$output" == *"dev agent start 2"* ]]
}

@test "an agy tab is refused: agy keeps no conversation ids" {
    agent_cmd reset 2 --cmd agy
    agent_cmd reset 2 --cmd agy
    local current; current="$(sid 2)"
    agent_cmd resume 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"agy"* ]]
    [ "$(sid 2)" = "$current" ]
}

@test "resume leaves the other tabs alone" {
    local one; one="$(sid 1)"
    agent_cmd reset 2
    agent_cmd resume 2
    [ "$(sid 1)" = "$one" ]
}

@test "resume needs a tab" {
    agent_cmd resume
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: dev agent resume"* ]]
}

@test "grid kill --fresh says how to go back for good" {
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid kill --fresh' _ "$REPO" "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"dev agent resume <tab>"* ]]
}

@test "reset says how to go back for good" {
    agent_cmd reset 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"dev agent resume 2"* ]]
}
