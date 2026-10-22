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

@test "in the dashboard, s starts the selected tab's agent" {
    press "$PREFIX" O
    until_true 'grep -aq "q close" "$SCREEN"'
    press 2
    until_true 'grep -aq "▶2 myrepo-feat" "$SCREEN"'
    press s
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    until_true 'tmux has-session -t "=ai-${ws}-claude" 2>/dev/null'
}

@test "in the dashboard, q closes it" {
    local client; client="$(tmux list-clients -F '#{client_name}')"
    press "$PREFIX" O
    until_true 'grep -aq "q close" "$SCREEN"'
    pgrep -f "__dashboard .*${client}" >/dev/null
    press q
    until_true '! pgrep -f "__dashboard .*${client}" >/dev/null'
}

@test "in the dashboard, a digit for a missing tab keeps the selection" {
    press "$PREFIX" O
    until_true 'grep -aq "q close" "$SCREEN"'
    press 2
    until_true 'grep -aq "▶2 myrepo-feat" "$SCREEN"'
    # Selecting tab 7 would make Enter go nowhere and leave tab 1 showing.
    press 7
    press $'\r'
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
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
    until_true 'grep -aq "Already in this popup" "$SCREEN"'
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

@test "a digit pressed inside a tab's agent opens that tab's agent instead" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    local ws1 ws2
    ws1="$(tmux show-options -w -t '=dev-myrepo-grid:1' -v @dev_ws_id)"
    ws2="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws2}")" = 1 ]'
    press "$PREFIX" 1
    until_true '[ "$(attached "ai-${ws1}")" = 1 ]'
    [ "$(attached "ai-${ws2}")" = 0 ]
    [ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 1 ]
    # And back again, from the agent it just opened.
    press "$PREFIX" 2
    until_true '[ "$(attached "ai-${ws2}")" = 1 ]'
    [ "$(attached "ai-${ws1}")" = 0 ]
}

@test "a digit for a tab that does not exist leaves the agent open" {
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:1' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    press "$PREFIX" 7
    until_true 'grep -aq "No tab 7" "$SCREEN"'
    [ "$(attached "ai-${ws}")" = 1 ]
}

@test "a digit from the coordinator opens that tab's agent" {
    press "$PREFIX" S
    until_true '[ "$(attached coord-myrepo-grid)" = 1 ]'
    press "$PREFIX" 2
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    [ "$(attached coord-myrepo-grid)" = 0 ]
}

@test "prefix X in a grid tab asks to remove that tab, and y removes it" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    press "$PREFIX" X
    until_true 'grep -aq "Remove tab 2" "$SCREEN"'
    [ "$(grep -ac "not a grid tab" "$SCREEN")" -eq 0 ]
    press y $'\r'
    until_true '[ ! -d "$CODE/myrepo-feat" ]'
    until_true '[ "$(tmux list-windows -t "=dev-myrepo-grid:" | wc -l | tr -d " ")" -eq 1 ]'
}

@test "prefix W in a grid tab closes it and its agent, and keeps the worktree" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    press "$PREFIX" d
    until_true '[ "$(attached "ai-${ws}")" = 0 ]'
    press "$PREFIX" W
    until_true '[ "$(tmux list-windows -t "=dev-myrepo-grid:" | wc -l | tr -d " ")" -eq 1 ]'
    [ -d "$CODE/myrepo-feat" ]
    # The agent and the prompt's own popup are gone with the tab.
    until_true '[ -z "$(others)" ]'
}

@test "a digit inside the agent of that same tab stays in it" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    press "$PREFIX" 2
    until_true 'grep -aq "Already in this popup" "$SCREEN"'
    [ "$(attached "ai-${ws}")" = 1 ]
}

@test "an agent opened with prefix a and then gone is dead, not none" {
    # The popup marks the tab itself; no dev agent start was involved.
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:1' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    # Attached is not yet launched: wait until the popup's agent runner has
    # recorded its pane, which it does just after marking the tab.
    until_true '[ -n "$(tmux show-options -t "=ai-${ws}-claude:" -qv @dev_agent_pane)" ]'
    tmux kill-session -t "=ai-${ws}-claude"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev agent status' _ "$REPO" "$DEV_ZSH" </dev/null
    [[ "$output" =~ 1\ +myrepo\ +main\ +clean\ +dead ]]
}

# The dashboard and the N and X prompts run a command, not a session, so
# tmux's prefix d had nothing to detach and they could only be left with q.
# Each must close with prefix d and with Ctrl-C, end its command, leave no
# session behind, and keep the grid's own client attached.
others() { tmux list-sessions -F '#{session_name}' | grep -v '^dev-myrepo-grid$'; }

# The command runs in its own session (the popup's), so checking that session
# and the command in its pane stays inside this test's tmux server.
dialog_closes() {
    local key="$1" shown="$2" command="$3" close="$4"
    press "$PREFIX" "$key"
    until_true "grep -aq '$shown' \"\$SCREEN\""
    until_true '[ "$(others | wc -l | tr -d " ")" = 1 ]'
    local pid; pid="$(tmux list-panes -t "=$(others):" -F '#{pane_pid}')"
    ps -o args= -p "$pid" | grep -q -- "$command"
    press "$close"
    until_true '[ -z "$(others)" ]'
    until_true '! kill -0 "$pid" 2>/dev/null'
    [ "$(attached dev-myrepo-grid)" = 1 ]
}

@test "prefix d closes the dashboard" {
    dialog_closes O "q close" "__dashboard" "${PREFIX}d"
}

@test "Ctrl-C closes the dashboard" {
    dialog_closes O "q close" "__dashboard" $'\x03'
}

@test "prefix d closes the new branch tab prompt" {
    dialog_closes N "Branch" "grid add --prompt" "${PREFIX}d"
}

@test "Ctrl-C closes the new branch tab prompt" {
    dialog_closes N "Branch" "grid add --prompt" $'\x03'
}

@test "prefix d closes the remove tab prompt" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    dialog_closes X "Remove tab 2" "grid remove --pane" "${PREFIX}d"
    [ -d "$CODE/myrepo-feat" ]
}

@test "Ctrl-C closes the remove tab prompt" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    dialog_closes X "Remove tab 2" "grid remove --pane" $'\x03'
    [ -d "$CODE/myrepo-feat" ]
}


@test "prefix d closes the terminal and coordinator popups, which keep running" {
    press "$PREFIX" j
    until_true '[ "$(attached term-)" = 1 ]'
    press "$PREFIX" d
    until_true '[ "$(attached term-)" = 0 ]'
    press "$PREFIX" S
    until_true '[ "$(attached coord-)" = 1 ]'
    press "$PREFIX" d
    until_true '[ "$(attached coord-)" = 0 ]'
    [ "$(attached dev-myrepo-grid)" = 1 ]
}

@test "prefix N's prompt starts in the directory of the tab it was pressed in" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    press "$PREFIX" N
    until_true '[ "$(others | wc -l | tr -d " ")" = 1 ]'
    [ "$(tmux display-message -p -t "=$(others):" '#{pane_current_path}')" = "$(cd "$CODE/myrepo-feat" && pwd -P)" ]
}


# One popup at a time: a dev popup key pressed inside a dev popup closes it
# and opens the new one in its place, for the tab the first one belonged to,
# never as a popup inside the popup.

# Tab 2's agent, open in its popup.
open_agent_of_tab2() {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    WS="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${WS}")" = 1 ]'
}

# Every client but the grid's: one per popup showing. A popup inside a popup
# is a client attached from inside another.
popup_clients() { tmux list-clients -F '#{session_name}' | grep -cv '^dev-myrepo-grid$'; }

@test "prefix O inside an agent closes it and opens the dashboard for its tab" {
    open_agent_of_tab2
    press "$PREFIX" O
    until_true '[ "$(attached dlg-)" = 1 ]'
    until_true '[ "$(attached "ai-${WS}")" = 0 ]'
    tmux has-session -t "=ai-${WS}-claude"
    until_true 'grep -aq "▶2 myrepo-feat" "$SCREEN"'
    [ "$(popup_clients)" = 1 ]
}

@test "the terminal key inside an agent swaps it for that tab's terminal" {
    open_agent_of_tab2
    press "$PREFIX" j
    until_true '[ "$(attached term-)" = 1 ]'
    until_true '[ "$(attached "ai-${WS}")" = 0 ]'
    [ "$(tmux show-options -w -t "=$(tmux list-sessions -F '#{session_name}' | grep '^term-'):" -v @dev_ws_id)" = "$WS" ]
    [ "$(popup_clients)" = 1 ]
}

@test "prefix S inside an agent swaps it for the coordinator" {
    open_agent_of_tab2
    press "$PREFIX" S
    until_true '[ "$(attached coord-myrepo-grid)" = 1 ]'
    until_true '[ "$(attached "ai-${WS}")" = 0 ]'
    [ "$(popup_clients)" = 1 ]
}

@test "prefix a inside the dashboard closes it and opens the agent of its tab" {
    press "$PREFIX" 2
    until_true '[ "$(tmux display-message -p -t "=dev-myrepo-grid:" "#{window_index}")" = 2 ]'
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    press "$PREFIX" O
    until_true '[ "$(attached dlg-)" = 1 ]'
    press "$PREFIX" a
    until_true '[ "$(attached "ai-${ws}")" = 1 ]'
    until_true '[ -z "$(tmux list-sessions -F "#{session_name}" | grep "^dlg-")" ]'
    [ "$(popup_clients)" = 1 ]
}

@test "prefix N inside an agent asks in the directory of the agent's tab" {
    open_agent_of_tab2
    press "$PREFIX" N
    until_true '[ "$(attached dlg-)" = 1 ]'
    until_true '[ "$(attached "ai-${WS}")" = 0 ]'
    local dlg; dlg="$(tmux list-sessions -F '#{session_name}' | grep '^dlg-')"
    [ "$(tmux display-message -p -t "=${dlg}:" '#{pane_current_path}')" = "$(cd "$CODE/myrepo-feat" && pwd -P)" ]
}

@test "the dashboard key inside the dashboard keeps the one dashboard" {
    press "$PREFIX" O
    until_true '[ "$(attached dlg-)" = 1 ]'
    local dlg; dlg="$(tmux list-sessions -F '#{session_name}' | grep '^dlg-')"
    press "$PREFIX" O
    sleep 1
    [ "$(tmux list-sessions -F '#{session_name}' | grep '^dlg-')" = "$dlg" ]
    [ "$(attached dlg-)" = 1 ]
    [ "$(popup_clients)" = 1 ]
}

@test "a split pressed inside a popup is undone, and in a tab it is kept" {
    open_agent_of_tab2
    press "$PREFIX" %
    sleep 1
    [ "$(tmux list-panes -s -t "=ai-${WS}-claude" | wc -l | tr -d ' ')" = 1 ]
    press "$PREFIX" d
    until_true '[ "$(attached "ai-${WS}")" = 0 ]'
    press "$PREFIX" %
    until_true '[ "$(tmux list-panes -t "=dev-myrepo-grid:2" | wc -l | tr -d " ")" = 2 ]'
}
