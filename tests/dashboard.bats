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
    # Exported for the rest of the test: loading dev publishes its settings
    # again, and a frame loaded without it would take the launcher back
    # before a slow machine has started the coordinator.
    export DEV_AGENT_LAUNCH_CMD="$(show claude-2.1.286-working.txt)"
    zsh -c 'source "$1" 2>/dev/null; _dev_publish_config' _ "$DEV_ZSH" </dev/null
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

@test "keys: t switches the selected tab's AI tool, and the frame shows a non-default tool" {
    run zsh -c 'source "$1" 2>/dev/null; _dev_dashboard_key t 2' _ "$DEV_ZSH" </dev/null
    [ "$output" = "tool 2" ]
    tmux set-option -w -t '=dev-myrepo-grid:2' @dev_ai_cmd agy
    frame 120
    [[ "$output" == *"├─ 2 myrepo-feat"*$'\n'" │    ○ no agent · agy"* ]]
}

@test "prefix O opens the dashboard for the pane it was pressed in" {
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    local binding; binding="$(tmux list-keys -T prefix | awk '$4 == "O"')"
    [[ "$binding" == *"run-shell"* && "$binding" == *"__dashboard"* && "$binding" == *"#{pane_id}"* ]]
}

# Clearing the screen before a frame left the popup blank for as long as the
# frame took to gather (a second or more with real worktrees), every refresh.
@test "a refresh draws over the last frame instead of clearing the screen" {
    local raw="$BATS_TEST_TMPDIR/raw" pane
    pane="$(tmux new-window -d -P -F '#{pane_id}' -t '=dev-myrepo-grid:' \
        "sleep 1; exec zsh $DEV_ZSH __dashboard $(pane_of '=dev-myrepo-grid:1') ''")"
    tmux pipe-pane -O -t "$pane" "cat >> $raw"
    local i
    for i in $(seq 1 75); do
        [ "$(grep -o 'dev-myrepo-grid ·' "$raw" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
        sleep 0.2
    done
    [ "$(grep -o 'dev-myrepo-grid ·' "$raw" | wc -l | tr -d ' ')" -ge 2 ]
    run grep -c $'\e\\[2J' "$raw"
    [ "$output" = 0 ]
    grep -q $'\e\\[H' "$raw"
    grep -q $'\e\\[J' "$raw"
    # And what it draws is the frame, line for line from the left edge.
    tmux capture-pane -p -t "$pane" > "$BATS_TEST_TMPDIR/screen"
    [[ "$(sed -n 1p "$BATS_TEST_TMPDIR/screen")" == " dev-myrepo-grid · "* ]]
    [[ "$(sed -n 3p "$BATS_TEST_TMPDIR/screen")" == " ◇ coordinator · "* ]]
    run grep -F "\$'" "$BATS_TEST_TMPDIR/screen"
    [ "$status" -eq 1 ]
}

# A git that takes a second for every call, so reading the grid is slow
# enough to tell apart from drawing it.
slow_git() {
    local real; real="$(command -v git)"
    mkdir -p "$BATS_TEST_TMPDIR/slow-bin"
    printf '#!/bin/sh\nsleep 1\nexec %s "$@"\n' "$real" > "$BATS_TEST_TMPDIR/slow-bin/git"
    chmod +x "$BATS_TEST_TMPDIR/slow-bin/git"
    echo "$BATS_TEST_TMPDIR/slow-bin:$PATH"
}

@test "the tabs are read at the same time, not one after another" {
    local path; path="$(slow_git)"
    local start=$SECONDS
    run env PATH="$path" zsh -c 'source "$1" 2>/dev/null; grid_session=dev-myrepo-grid; _dev_agent_rows' _ "$DEV_ZSH" </dev/null
    # Three tabs, two git calls each: six seconds in turn, two at once.
    (( SECONDS - start < 4 ))
    [ "$(printf '%s\n' "$output" | cut -d$'\x1f' -f1 | tr '\n' ' ')" = "1 2 3 " ]
}

@test "a digit redraws at once, without reading the grid again" {
    local path pane; path="$(slow_git)"
    pane="$(tmux new-window -d -P -F '#{pane_id}' -t '=dev-myrepo-grid:' \
        "exec env PATH='$path' zsh $DEV_ZSH __dashboard $(pane_of '=dev-myrepo-grid:1') ''")"
    local i
    for i in $(seq 1 75); do
        tmux capture-pane -p -t "$pane" | grep -q '▶1' && break
        sleep 0.2
    done
    tmux capture-pane -p -t "$pane" | grep -q '▶1'
    tmux send-keys -t "$pane" 3
    # Reading the grid takes two seconds here; the new selection must not.
    for i in $(seq 1 6); do
        tmux capture-pane -p -t "$pane" | grep -q '▶3' && break
        sleep 0.2
    done
    tmux capture-pane -p -t "$pane" | grep -q '▶3'
}
