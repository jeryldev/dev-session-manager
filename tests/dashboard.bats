#!/usr/bin/env bats
# prefix O: a dashboard of the grid's tabs, one box each (replaces the tiled
# live view, which showed only running agents, clipped, under nested status
# bars). Read-only: it never types into an agent.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    FIXTURES="$PROJECT_ROOT/tests/fixtures/agent-screens"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS DEV_AGENT_LAUNCH_CMD
    REPO="$(make_repo)"
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    git -C "$REPO" worktree add -q -b fix "$CODE/myrepo-fix"
    run_grid "$REPO"
}

teardown() {
    teardown_tmux
}

show() {
    printf "awk 'NF { last = NR } { line[NR] = \$0 } END { for (i = 1; i <= last; i++) print line[i] }' '%s'; exec sleep 600" "$FIXTURES/$1"
}

start_agent() {
    DEV_AGENT_LAUNCH_CMD="$(show "$2")" zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev agent start "$3"' _ "$REPO" "$DEV_ZSH" "$1" </dev/null >/dev/null
}

# One frame, as text without colour, at a given width.
frame() {
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; repo="$(_dev_repo_root)"; _dev_dashboard_frame "$(_dev_grid_session "$repo")" "$3" "${4:-0}"' _ "$REPO" "$DEV_ZSH" "$1" "$2" </dev/null
    output="$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')"
}

@test "every tab gets a box, with its branch, agent or not" {
    frame 120
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 myrepo"* && "$output" == *"2 myrepo-feat"* && "$output" == *"3 myrepo-fix"* ]]
    [[ "$output" == *"main"* && "$output" == *"feat"* && "$output" == *"fix"* ]]
    # Matches, not lines: boxes in one row share their lines.
    [ "$(grep -o 'no agent' <<< "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "the header counts tabs and running agents" {
    start_agent 2 claude-2.1.286-working.txt
    frame 120
    [[ "$output" == *"dev-myrepo-grid"*"3 tabs"*"1 agent running"* ]]
}

@test "each box shows its agent's state, and a waiting agent's question" {
    start_agent 2 claude-2.1.286-working.txt
    start_agent 3 claude-2.1.286-waiting-trust.txt
    frame 120
    [[ "$output" == *"WORKING"* ]]
    [[ "$output" == *"WAITING"* ]]
    [[ "$output" == *"Quick safety check"* ]]
}

@test "boxes fill the width and wrap to the next row" {
    frame 120
    local first; first="$(grep -m1 '┌' <<< "$output")"
    [[ "$first" == *"1 myrepo"*"2 myrepo-feat"*"3 myrepo-fix"* ]]
    frame 70
    first="$(grep -m1 '┌' <<< "$output")"
    [[ "$first" == *"1 myrepo"*"2 myrepo-feat"* && "$first" != *"3 myrepo-fix"* ]]
}

@test "no line is wider than the screen; long text is cut with an ellipsis" {
    git -C "$REPO" worktree add -q -b "a-very-long-branch-name-that-cannot-possibly-fit" "$CODE/myrepo-long"
    zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid sync' _ "$REPO" "$DEV_ZSH" </dev/null >/dev/null
    frame 70
    # Width in characters, decoded as UTF-8: bash's ${#line} counts bytes in
    # a C locale, and "·" and the box lines are more than one byte.
    printf '%s\n' "$output" | python3 -c '
import sys
for line in sys.stdin.buffer.read().decode("utf-8").splitlines():
    assert len(line) <= 70, (len(line), line)'
    [[ "$output" == *"…"* ]]
}

@test "the selected box is marked" {
    frame 120 2
    [[ "$output" == *"▶ 2 myrepo-feat"* ]]
    # The top border is drawn through after the title.
    [[ "$(grep -m1 '┌' <<< "$output")" == *"─ ▶ 2 myrepo-feat ─"* ]]
    [[ "$output" != *"▶ 1 myrepo"* ]]
}

@test "keys: a digit selects, Enter goes, a opens the agent, s starts it, q closes" {
    run zsh -c 'source "$1" 2>/dev/null; for k in 3 $'"'"'\n'"'"' a s q x; do _dev_dashboard_key "$k" 3; done' _ "$DEV_ZSH" </dev/null
    [ "$output" = $'select 3\ngo 3\nagent 3\nstart 3\nquit\nnone' ]
}

@test "prefix O opens the dashboard for the pane it was pressed in" {
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    local binding; binding="$(tmux list-keys -T prefix | awk '$4 == "O"')"
    [[ "$binding" == *"run-shell"* && "$binding" == *"__dashboard"* && "$binding" == *"#{pane_id}"* ]]
}

@test "the dashboard outside a grid says so" {
    start_isolated_server dev-plain
    run zsh "$DEV_ZSH" __dashboard "$(tmux display-message -p -t '=dev-plain:' '#{pane_id}')" "" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"No grid here"* ]]
}
