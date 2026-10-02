#!/usr/bin/env bats
# End to end: a real tmux client on a pseudo-terminal, with keys pressed the
# way a person presses them. This is where popups actually open and nested
# clients actually attach — the part no headless test can show. Stock tmux
# config, so the prefix is C-b.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-90}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS
    export SHELL=/bin/sh
    # Agents that stay up without calling a model.
    export DEV_AGENT_LAUNCH_CMD="exec sleep 600"
    REPO="$(make_repo)"
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$REPO"
    KEYS="$BATS_TEST_TMPDIR/keys"
    SCREEN="$BATS_TEST_TMPDIR/screen.log"
    mkfifo "$KEYS"
    python3 "$PROJECT_ROOT/tests/pty_client.py" "$KEYS" "$SCREEN" 160 48 -- tmux attach-session -t '=dev-myrepo-grid' &
    CLIENT=$!
    until_true '[ "$(tmux list-clients 2>/dev/null | wc -l | tr -d " ")" -ge 1 ]'
}

teardown() {
    kill "$CLIENT" 2>/dev/null || true
    teardown_tmux
}

PREFIX=$'\x02'

press() { printf '%s' "$@" > "$KEYS"; }

# Poll a condition for up to ~15s (headroom for a loaded machine); fail with
# the condition if it never holds.
until_true() {
    local i
    for i in $(seq 1 75); do
        eval "$1" && return 0
        sleep 0.2
    done
    echo "never true: $1" >&2
    return 1
}

attached() {
    tmux list-sessions -F '#{session_name} #{session_attached}' | awk -v p="$1" 'index($1, p) == 1 { print $2; exit }'
}

@test "prefix a opens the tab's agent in a popup, and detaching keeps it" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    press "$PREFIX" d
    until_true '[ "$(attached "ai-${ws}")" = 0 ]'
    tmux has-session -t "=ai-${ws}-claude"
}

@test "prefix S opens the coordinator, the same one from every tab" {
    press "$PREFIX" S
    until_true '[ "$(attached coord-myrepo-grid)" = 1 ]'
    grep -aq 'coordinator · dev-myrepo-grid' "$SCREEN"
    press "$PREFIX" d
    until_true '[ "$(attached coord-myrepo-grid)" = 0 ]'
    # One key at a time, as a person presses them: tmux 3.4 drops the second
    # binding when both arrive in one burst.
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    press "$PREFIX" S
    until_true '[ "$(attached coord-myrepo-grid)" = 1 ]'
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^coord-')" -eq 1 ]
}

@test "prefix O shows a box per tab; a digit and Enter go to that tab" {
    press "$PREFIX" O
    until_true 'grep -aq "q close" "$SCREEN"'
    grep -aq "1 myrepo" "$SCREEN"
    grep -aq "2 myrepo-feat" "$SCREEN"
    press 2
    sleep 0.5
    press $'\r'
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
}

@test "in the dashboard, a opens the selected tab's agent" {
    press "$PREFIX" O
    until_true 'grep -aq "q close" "$SCREEN"'
    press 2
    sleep 0.5
    press a
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
}

@test "prefix N asks for a branch and opens it as the next tab" {
    press "$PREFIX" N
    until_true 'grep -aq "Branch for the new tab" "$SCREEN"'
    press "e2e-branch" $'\r'
    until_true '[ -d "$CODE/myrepo-e2e-branch" ]'
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 3 ]'
    [ "$(tmux display-message -p -t '=dev-myrepo-grid:3' '#{pane_current_path}')" = "$CODE/myrepo-e2e-branch" ]
}

@test "dev typed inside tmux in another repo switches to that repo's grid" {
    # D22 + B7 together, from a real shell in a real pane.
    # The pane's login shell has macOS's default PATH (path_helper), where git
    # is Apple's shim; a real user's shell has their own PATH, so set it.
    local other; other="$(make_repo other)"
    tmux send-keys -t '=dev-myrepo-grid:1' -l "export PATH='$PATH'; cd '$other' && zsh '$DEV_ZSH'"
    tmux send-keys -t '=dev-myrepo-grid:1' Enter
    until_true '[ "$(tmux list-clients -F "#{client_session}")" = dev-other-grid ]'
}

@test "prefix a twice reaches the same agent, from the tab or from inside its popup" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    # Again, from inside the popup.
    press "$PREFIX" a
    sleep 1
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^ai-')" -eq 1 ]
    # Not shown inside itself a second time.
    [ "$(attached "ai-${ws}")" = 1 ]
    # Close it, then press again from the tab: the same session comes back.
    press "$PREFIX" d
    until_true '[ "$(attached "ai-${ws}")" = 0 ]'
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    [ "$(tmux list-sessions -F '#{session_name}' | grep -c '^ai-')" -eq 1 ]
}

@test "prefix X in a grid tab asks to remove that tab, and y removes it" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    press "$PREFIX" X
    until_true 'grep -aq "Remove tab 2" "$SCREEN"'
    ! grep -aq "not a grid tab" "$SCREEN"
    press y $'\r'
    until_true '[ ! -d "$CODE/myrepo-feat" ]'
    until_true '[ "$(tmux list-windows -t "=dev-myrepo-grid:" | wc -l | tr -d " ")" -eq 1 ]'
}
