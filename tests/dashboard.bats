#!/usr/bin/env bats
# prefix O: a dashboard of the grid, drawn as a tree: the coordinator at the
# root and a branch per tab with its agent. Read-only: it never types into an
# agent.

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

pane_of() { tmux display-message -p -t "$1" '#{pane_id}'; }

# One frame, as text without colour, at a given width.
frame() {
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; repo="$(_dev_repo_root)"; _dev_dashboard_frame "$(_dev_grid_session "$repo")" "$3" "${4:-0}"' _ "$REPO" "$DEV_ZSH" "$1" "$2" </dev/null
    output="$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')"
}

@test "the header counts tabs and running agents" {
    start_agent 2 claude-2.1.286-working.txt
    frame 120
    [[ "$output" == *"dev-myrepo-grid"*"3 tabs"*"1 agent running"* ]]
}

@test "every tab is a branch of the tree, with its branch name, agent or not" {
    frame 120
    [ "$status" -eq 0 ]
    [[ "$output" == *"├─ 1 myrepo "*"main · clean"* ]]
    [[ "$output" == *"├─ 2 myrepo-feat "*"feat · clean"* ]]
    # The last tab closes the tree.
    [[ "$output" == *"└─ 3 myrepo-fix "*"fix · clean"* ]]
    [ "$(grep -c 'no agent' <<< "$output")" -eq 3 ]
}

@test "the coordinator is the root, and says when it has not been started" {
    frame 120
    [[ "$(grep -m1 coordinator <<< "$output")" == *"◇ coordinator · ○ not started (prefix S)"* ]]
    # The coordinator's agent reads its launcher from the server, as published.
    DEV_AGENT_LAUNCH_CMD="$(show claude-2.1.286-working.txt)" zsh -c 'source "$1" 2>/dev/null; _dev_publish_config' _ "$DEV_ZSH" </dev/null
    zsh "$DEV_ZSH" __coordinator "$(pane_of '=dev-myrepo-grid:1')" "" </dev/null 2>/dev/null
    local i
    for i in $(seq 1 50); do
        frame 120
        [[ "$output" == *"◆ coordinator · ● WORKING"* ]] && break
        sleep 0.2
    done
    [[ "$output" == *"◆ coordinator · ● WORKING"* ]]
}

@test "each tab shows its agent's state, and a waiting agent's question" {
    start_agent 2 claude-2.1.286-working.txt
    start_agent 3 claude-2.1.286-waiting-trust.txt
    frame 120
    # The state sits under its own tab, on the tree's stem.
    [[ "$output" == *"├─ 2 myrepo-feat"*$'\n'" │    ● WORKING"* ]]
    [[ "$output" == *"└─ 3 myrepo-fix"*$'\n'"      ● WAITING"*$'\n'"      \"Quick safety check"* ]]
}

@test "the selected tab is marked" {
    frame 120 2
    [[ "$output" == *"├─▶2 myrepo-feat"* ]]
    [[ "$output" != *"▶1 myrepo"* ]]
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

@test "in a C locale the frame still fits the width" {
    # CI and servers run in C, where a byte count would misjudge every
    # multi-byte box character.
    git -C "$REPO" worktree add -q -b "a-very-long-branch-name-that-cannot-possibly-fit" "$CODE/myrepo-long"
    zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid sync' _ "$REPO" "$DEV_ZSH" </dev/null >/dev/null
    LC_ALL=C LANG=C frame 70
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | python3 -c '
import sys
for line in sys.stdin.buffer.read().decode("utf-8").splitlines():
    assert len(line) <= 70, (len(line), line)'
    [[ "$output" == *"├─ 1 myrepo"* ]]
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
