#!/usr/bin/env bats
# prefix S, the grid's coordinator, and prefix O, the overview of its agents
# (plan Phase 4b, US-33, D16, D14).

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS DEV_KEY_COORDINATOR DEV_KEY_OVERVIEW
    # Agents that stay up without calling a model.
    export DEV_AGENT_LAUNCH_CMD="exec sleep 600"
}

teardown() {
    teardown_tmux
}

grid_with_feat() {
    REPO="$(make_repo "${1:-myrepo}")"
    git -C "$REPO" worktree add -q -b feat "$CODE/${1:-myrepo}-feat"
    run_grid "$REPO"
}

pane_of() { tmux display-message -p -t "$1" '#{pane_id}'; }

# What prefix S runs; no client in tests, so only the popup step is skipped.
press_coordinator() {
    run zsh "$DEV_ZSH" __coordinator "$1" "" </dev/null
}

coordinators() {
    local id name
    tmux list-sessions -F '#{session_id}|#{session_name}' | while IFS='|' read -r id name; do
        [ -n "$(text_opt -t "$id" @dev_coordinator_of)" ] && echo "${id}|${name}|$(text_opt -t "$id" @dev_coordinator_of)"
    done
    return 0
}

@test "prefix S from any tab reaches the same coordinator" {
    # US-33.1/33.2
    grid_with_feat
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    local first; first="$(coordinators)"
    press_coordinator "$(pane_of '=dev-myrepo-grid:2')"
    [ "$(coordinators)" = "$first" ]
    [ "$(coordinators | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the coordinator works from the repo root and knows its grid" {
    # US-33.10
    grid_with_feat
    press_coordinator "$(pane_of '=dev-myrepo-grid:2')"
    local name; name="$(coordinators | cut -d'|' -f2)"
    [ "$(tmux show-environment -t "=$name" DEV_GRID)" = "DEV_GRID=$REPO" ]
    [ "$(text_opt -w -t "=$name:" @dev_workspace)" = "$REPO" ]
}

@test "the coordinator resumes the same conversation after a rebuild" {
    # US-33.8: a session id derived from the grid, never stored.
    grid_with_feat
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    local name sid; name="$(coordinators | cut -d'|' -f2)"
    sid="$(tmux show-options -w -t "=$name:" -v @dev_agent_sid)"
    [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-5 ]]
    tmux kill-server
    run_grid "$REPO"
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    [ "$(tmux show-options -w -t "=$name:" -v @dev_agent_sid)" = "$sid" ]
}

@test "prefix S outside a grid creates nothing" {
    # US-33.6
    start_isolated_server dev-plain
    press_coordinator "$(pane_of '=dev-plain:')"
    [ -z "$(coordinators)" ]
}

@test "prefix S inside a worker's popup reaches the same grid's coordinator" {
    # US-33.5
    grid_with_feat
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    local script; script="$(zsh -c 'source "$1" 2>/dev/null; _dev_popup_script term sh' _ "$DEV_ZSH" </dev/null)"
    tmux run-shell -t "$(pane_of '=dev-myrepo-grid:2')" "$script" 2>/dev/null || true
    local popup; popup="$(tmux list-sessions -F '#{session_name}' | grep '^term-')"
    press_coordinator "$(pane_of "=${popup}:")"
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    [ "$(coordinators | wc -l | tr -d ' ')" -eq 1 ]
}

@test "prefix S inside the coordinator stays there" {
    # US-33.4
    grid_with_feat
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    local name; name="$(coordinators | cut -d'|' -f2)"
    press_coordinator "$(pane_of "=${name}:")"
    [ "$(coordinators | wc -l | tr -d ' ')" -eq 1 ]
}

@test "two grids have two coordinators" {
    # US-33.7
    grid_with_feat myrepo
    grid_with_feat other
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    press_coordinator "$(pane_of '=dev-other-grid:1')"
    [ "$(coordinators | wc -l | tr -d ' ')" -eq 2 ]
}

@test "two presses at once still make one coordinator" {
    # US-33.3: the loser's new-session fails as a duplicate and attaches.
    grid_with_feat
    local p1 p2; p1="$(pane_of '=dev-myrepo-grid:1')"; p2="$(pane_of '=dev-myrepo-grid:2')"
    # Wait on these two only: a bare `wait` also waits on bats' own timeout
    # watchdog, which runs in the background, and so never returns first.
    local a b
    zsh "$DEV_ZSH" __coordinator "$p1" "" </dev/null &>/dev/null & a=$!
    zsh "$DEV_ZSH" __coordinator "$p2" "" </dev/null &>/dev/null & b=$!
    wait "$a" "$b"
    [ "$(coordinators | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the grid's own lookups never mistake the coordinator for the grid" {
    grid_with_feat
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid status' _ "$REPO" "$DEV_ZSH" </dev/null
    [[ "$output" == *"myrepo-feat"* ]]
}

@test "dev grid kill takes the coordinator with it" {
    grid_with_feat
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid kill' _ "$REPO" "$DEV_ZSH" </dev/null
    [ -z "$(coordinators)" ]
}

@test "prefix S and prefix O are bound, and stay off a user's keys" {
    start_isolated_server
    tmux bind-key O display-message mine
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    [[ "$(tmux list-keys -T prefix | awk '$4 == "S"')" == *"__coordinator"* ]]
    [[ "$(tmux list-keys -T prefix | awk '$4 == "O"')" == *"display-message mine"* ]]
}

# ─── prefix O: the overview (US-23 retargeted, D14, D16) ───

start_agent() {
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev agent start "$3"' _ "$REPO" "$DEV_ZSH" "$2" </dev/null
}

build_overview() {
    run zsh -c 'source "$1" 2>/dev/null; _dev_overview_build "$2"' _ "$DEV_ZSH" "$1" </dev/null
}

@test "the overview has one read-only pane per running workspace agent" {
    # US-23.1/23.2/33.12: the agents the tabs use, not copies; no coordinator.
    grid_with_feat
    start_agent "$REPO" 1
    start_agent "$REPO" 2
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    build_overview "$(pane_of '=dev-myrepo-grid:1')"
    [ "$status" -eq 0 ]
    local name="$output"
    [ "$(tmux list-panes -t "=${name}:" | wc -l | tr -d ' ')" -eq 2 ]
    local commands; commands="$(tmux list-panes -t "=${name}:" -F '#{pane_start_command}')"
    [[ "$commands" == *"attach-session -r -t '=ai-myrepo-"* ]]
    [[ "$commands" != *"coord-"* ]]
}

@test "no agents running means no overview" {
    grid_with_feat
    build_overview "$(pane_of '=dev-myrepo-grid:1')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No workspace agents"* ]]
    [ -z "$(tmux list-sessions -F '#{session_name}' | grep '^overview-')" ]
}

@test "dismissing the overview popup kills the overview" {
    # US-23.3: left alive, it keeps every agent clamped to its pane size.
    run zsh -c 'source "$1" 2>/dev/null; _dev_overview_popup_command overview-x' _ "$DEV_ZSH" </dev/null
    [ "$output" = "tmux attach-session -t '=overview-x'; tmux kill-session -t '=overview-x'" ]
}

@test "dev grid kill closes the overview first" {
    # D14 / US-21.4
    grid_with_feat
    start_agent "$REPO" 2
    build_overview "$(pane_of '=dev-myrepo-grid:1')"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid kill' _ "$REPO" "$DEV_ZSH" </dev/null
    [ -z "$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^overview-')" ]
}

@test "prefix a inside the coordinator does not open its conversation twice" {
    grid_with_feat
    press_coordinator "$(pane_of '=dev-myrepo-grid:1')"
    local name sid; name="$(coordinators | cut -d'|' -f2)"
    sid="$(tmux show-options -w -t "=${name}:" -v @dev_agent_sid)"
    tmux new-session -d -s "ai-${name}-claude"
    tmux set-option -w -t "=ai-${name}-claude:" @dev_origin "$(pane_of "=${name}:")"
    # Without the fake launcher, so the claude command (and any sid) shows.
    run env DEV_AGENT_LAUNCH_CMD= zsh -c 'source "$1" 2>/dev/null; _dev_agent_command "$2"' _ "$DEV_ZSH" "$(pane_of "=ai-${name}-claude:")" </dev/null
    [[ "$output" == *claude* ]]
    [[ "$output" != *"$sid"* ]]
}

@test "prefix O and prefix S say why they did nothing, and exit cleanly" {
    # A non-zero exit from a key's run-shell makes tmux dump "... returned 1"
    # over the user's window; the display-message is the whole answer.
    grid_with_feat
    run zsh "$DEV_ZSH" __overview "$(pane_of '=dev-myrepo-grid:1')" "" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"No workspace agents"* ]]
    start_isolated_server dev-plain
    run zsh "$DEV_ZSH" __coordinator "$(pane_of '=dev-plain:')" "" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"No grid here"* ]]
}
