#!/usr/bin/env bats
# A dev popup is one pane: a split or a new window made inside one, by any key
# or command, is undone. Sessions that are not dev popups are left alone.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    start_isolated_server
    tmux new-session -d -s tab -x 100 -y 30 "sleep 600"
    # A popup's session, marked as dev marks it: by the session it belongs to.
    tmux new-session -d -s popup -x 100 -y 30 "sleep 600"
    tmux set-option -t '=popup:' @dev_parent "$(tmux display-message -p -t '=tab:' '#{session_id}')"
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
}

teardown() {
    teardown_tmux
}

count_panes() { tmux list-panes -s -t "=$1" | wc -l | tr -d ' '; }
count_windows() { tmux list-windows -t "=$1" | wc -l | tr -d ' '; }

@test "a split inside a dev popup is undone" {
    local pane; pane="$(tmux display-message -p -t '=popup:' '#{pane_id}')"
    tmux split-window -t '=popup:' "sleep 600"
    [ "$(count_panes popup)" = 1 ]
    [ "$(tmux display-message -p -t '=popup:' '#{pane_id}')" = "$pane" ]
}

@test "a new window inside a dev popup is undone" {
    tmux new-window -t '=popup:' "sleep 600"
    [ "$(count_windows popup)" = 1 ]
}

@test "a split and a new window outside a dev popup are kept" {
    tmux split-window -t '=tab:' "sleep 600"
    tmux new-window -t '=tab:' "sleep 600"
    [ "$(count_panes tab)" = 3 ]
    [ "$(count_windows tab)" = 2 ]
}
