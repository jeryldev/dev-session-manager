#!/usr/bin/env bats
# Tests for `dev grid`: one tmux session, one tab per git worktree.

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

# ─── Building (US-14, D21) ───

@test "dev grid outside a git repo fails and builds nothing" {
    # US-14.1
    mkdir -p "$CODE/plain"
    run_grid "$CODE/plain"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a git repository"* ]]
    ! tmux has-session 2>/dev/null
}

@test "dev grid gives each worktree a tab, the main checkout first" {
    # US-14.2 / D21: every tab is a workspace; there is no map tab.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    git -C "$repo" worktree add -q -b fix "$CODE/myrepo-fix"
    run_grid "$repo"
    run windows dev-myrepo-grid
    [ "$output" = $'1 myrepo\n2 myrepo-feat\n3 myrepo-fix' ]
}

@test "dev grid numbers tabs from 1 on a stock config" {
    # US-14.5: base-index 0 is the tmux default.
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    [ "$(tmux list-windows -t '=dev-myrepo-grid:' -F '#{window_index}')" = "1" ]
}

@test "each tab starts in its worktree and records it" {
    # US-14.4
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    [ "$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_current_path}')" = "$CODE/myrepo-feat" ]
    [ "$(text_opt -w -t '=dev-myrepo-grid:2' @dev_workspace)" = "$CODE/myrepo-feat" ]
}

@test "a detached worktree still gets a tab" {
    # US-22.15: detached is the common case for agent-grid slots.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q --detach "$CODE/slot-1"
    run_grid "$repo"
    [[ "$(windows dev-myrepo-grid)" == *"2 slot-1"* ]]
}

@test "a worktree whose directory is gone is skipped with a warning" {
    # US-22.14: git reports it as prunable.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b gone "$CODE/myrepo-gone"
    rm -rf "$CODE/myrepo-gone"
    run_grid "$repo"
    [[ "$output" == *"myrepo-gone"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "dev grid from inside a worktree joins the main repo's grid" {
    # US-14.3: --git-common-dir, not --show-toplevel.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$CODE/myrepo-feat"
    tmux has-session -t '=dev-myrepo-grid'
    ! tmux has-session -t '=dev-myrepo-feat-grid' 2>/dev/null
}

@test "the grid session is stamped with its repo" {
    # D9: the stamp, not the name, says this session is a grid.
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    [ "$(text_opt -t '=dev-myrepo-grid:' @dev_grid)" = "$repo" ]
}

@test "running dev grid again reuses the grid" {
    # US-14.8
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    run_grid "$repo"
    [ "$(tmux list-sessions | grep -c grid)" -eq 1 ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "a repo directory with a dot gets a session dev kill accepts" {
    # US-14.7
    local repo; repo="$(make_repo my.repo)"
    run_grid "$repo"
    tmux has-session -t '=dev-my-repo-grid'
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; dev kill my-repo-grid" </dev/null
    [ "$status" -eq 0 ]
    ! tmux has-session -t '=dev-my-repo-grid' 2>/dev/null
}

@test "dev grid installs the popup keys, so a Homebrew install has them" {
    # Design §5: an executed install binds only when a dev command runs, and
    # binding before the server exists is a silent no-op.
    local repo; repo="$(make_repo)"
    run sh -c "cd '$repo' && zsh '$DEV_ZSH' grid" </dev/null
    # Filtered from the full table: `list-keys -T prefix a` prints nothing on
    # tmux 3.7b even when the key is bound.
    [[ "$(tmux list-keys -T prefix | awk '$4 == "a"')" == *"display-popup"* ]]
}

@test "more worktrees than tabs is an error, not a quiet subset" {
    # D10/D21: 9 tabs. Choosing a subset arrives with the selection prompt.
    local repo i; repo="$(make_repo)"
    for i in 1 2 3 4 5 6 7 8 9; do
        git -C "$repo" worktree add -q -b "b$i" "$CODE/myrepo-$i"
    done
    run_grid "$repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"10 worktrees"* ]]
    ! tmux has-session -t '=dev-myrepo-grid' 2>/dev/null
}

# ─── Never adopting a session it did not build (US-15, D9) ───

@test "a role session at the grid's name is refused and left alone" {
    # US-15.1/15.2/15.4
    local repo; repo="$(make_repo)"
    zsh -c "source '$DEV_ZSH' 2>/dev/null; dev myrepo-grid" </dev/null &>/dev/null || true
    [ "$(tmux list-windows -t '=dev-myrepo-grid:' | wc -l | tr -d ' ')" -eq 4 ]
    run_grid "$repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a workspace grid"* ]]
    [[ "$output" == *"dev attach myrepo-grid"* ]]
    [[ "$output" == *"dev kill myrepo-grid"* ]]
    [ "$(tmux list-windows -t '=dev-myrepo-grid:' | wc -l | tr -d ' ')" -eq 4 ]
}

@test "a grid stamped for another repo is refused" {
    # US-15.3: two repos whose names slug alike.
    local repo; repo="$(make_repo)"
    start_isolated_server dev-myrepo-grid
    tmux set-option -t '=dev-myrepo-grid:' @dev_grid /somewhere/else
    run_grid "$repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/somewhere/else"* ]]
}

@test "grid is a command, not a session called dev-grid" {
    run_grid "$CODE"
    ! tmux has-session -t '=dev-grid' 2>/dev/null
}

# ─── dev grid status (US-18) ───

@test "dev grid status shows each tab's branch" {
    # US-18.1
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    run_grid "$repo" status
    [ "$status" -eq 0 ]
    [[ "$output" =~ 1\ +myrepo\ +main\ +clean ]]
    [[ "$output" =~ 2\ +myrepo-feat\ +feat\ +clean ]]
}

@test "dev grid status labels a detached worktree by its commit" {
    # US-18.2
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q --detach "$CODE/slot-1"
    run_grid "$repo"
    run_grid "$repo" status
    [[ "$output" == *"(detached $(git -C "$repo" rev-parse --short HEAD))"* ]]
}

@test "dev grid status counts uncommitted changes" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    touch "$repo/new.txt"
    run_grid "$repo" status
    [[ "$output" == *"1 changed"* ]]
}

@test "dev grid status without a grid for this repo is an error" {
    # US-18.4
    local repo; repo="$(make_repo)"
    run_grid "$repo" status
    [ "$status" -ne 0 ]
    [[ "$output" == *"No grid for"* ]]
}

# ─── dev grid add (US-35, D20) ───

add_branch() {
    local dir="$1"; shift
    run zsh -c "cd '$dir' && source '$DEV_ZSH' 2>/dev/null; dev grid add $*" </dev/null
}

@test "dev grid add creates a worktree for a new branch and appends its tab" {
    # US-35.1/35.2/35.7
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    add_branch "$repo" fix-1
    [ "$status" -eq 0 ]
    [ "$(git -C "$CODE/myrepo-fix-1" branch --show-current)" = "fix-1" ]
    run windows dev-myrepo-grid
    [ "$output" = $'1 myrepo\n2 myrepo-feat\n3 myrepo-fix-1' ]
    [ "$(text_opt -w -t '=dev-myrepo-grid:3' @dev_workspace)" = "$CODE/myrepo-fix-1" ]
}

@test "dev grid add switches the grid to the new tab" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    add_branch "$repo" fix-1
    [ "$(tmux display-message -p -t '=dev-myrepo-grid:' '#{window_index}')" = "2" ]
}

@test "dev grid add checks out an existing branch rather than making one" {
    local repo; repo="$(make_repo)"
    git -C "$repo" branch old
    run_grid "$repo"
    add_branch "$repo" old
    [ "$status" -eq 0 ]
    [ "$(git -C "$CODE/myrepo-old" branch --show-current)" = "old" ]
}

@test "dev grid add on a branch that already has a tab only switches to it" {
    # US-35.5
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    tmux select-window -t '=dev-myrepo-grid:1'
    add_branch "$repo" feat
    [ "$status" -eq 0 ]
    [ "$(tmux list-windows -t '=dev-myrepo-grid:' | wc -l | tr -d ' ')" -eq 2 ]
    [ "$(tmux display-message -p -t '=dev-myrepo-grid:' '#{window_index}')" = "2" ]
}

@test "dev grid add uses the configured create command" {
    # US-35.3: e.g. bin/agent-grid, which also provisions a database and ports.
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    export DEV_WORKTREE_CREATE_CMD="git worktree add -q -b {branch} $CODE/slot-9 >&2; echo $CODE/slot-9"
    add_branch "$repo" slotted
    [ "$status" -eq 0 ]
    [[ "$(windows dev-myrepo-grid)" == *"2 slot-9"* ]]
}

@test "a failing create command adds no tab and does not fall back to git" {
    # US-35.4 / D12
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    export DEV_WORKTREE_CREATE_CMD="exit 3"
    add_branch "$repo" nope
    [ "$status" -ne 0 ]
    # The message, not the echoed command ("exit 3"), carries the status.
    [[ "$output" == *"create command exited 3"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
    [ ! -d "$CODE/myrepo-nope" ]
}

@test "a create command that prints no existing directory adds no tab" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    export DEV_WORKTREE_CREATE_CMD="echo /nonexistent"
    add_branch "$repo" x
    [ "$status" -ne 0 ]
    [[ "$output" == *"no existing directory"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "dev grid add refuses when the new worktree's directory already exists" {
    # git would happily check out into an existing empty directory.
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    mkdir "$CODE/myrepo-x"
    add_branch "$repo" x
    [ "$status" -ne 0 ]
    [[ "$output" == *"$CODE/myrepo-x already exists"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
    run ! git -C "$repo" show-ref --verify --quiet refs/heads/x
}

@test "a new branch starts from the HEAD of the worktree it is added from" {
    # prefix N runs in the current tab: the new branch builds on what you see.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    git -C "$CODE/myrepo-feat" commit -q --allow-empty -m feat-work
    run_grid "$repo"
    add_branch "$CODE/myrepo-feat" new
    [ "$status" -eq 0 ]
    [ "$(git -C "$repo" rev-parse new)" = "$(git -C "$repo" rev-parse feat)" ]
}

@test "a branch name reaches the create command as data, never as code" {
    # US-35.9 (corrected): git accepts ; $( ) ' | & > and backticks in branch
    # names, so this one is valid — and runs a command if left unquoted.
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    export DEV_WORKTREE_CREATE_CMD="printf '%s' {branch} > $BATS_TEST_TMPDIR/got; mkdir -p $CODE/inj; echo $CODE/inj"
    local payload="x\$(true>$BATS_TEST_TMPDIR/pwned)"
    git check-ref-format --branch "$payload"
    add_branch "$repo" "'$payload'"
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    [ "$(cat "$BATS_TEST_TMPDIR/got")" = "$payload" ]
}

@test "dev grid add rejects a name git would not accept as a branch" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    add_branch "$repo" "'bad name'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid branch name"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "dev grid add refuses when the grid already has nine tabs" {
    # US-35.6
    local repo i; repo="$(make_repo)"
    for i in 2 3 4 5 6 7 8 9; do
        git -C "$repo" worktree add -q -b "b$i" "$CODE/myrepo-$i"
    done
    run_grid "$repo"
    add_branch "$repo" tenth
    [ "$status" -ne 0 ]
    [[ "$output" == *"9 tabs"* ]]
    [ ! -d "$CODE/myrepo-tenth" ]
}

@test "dev grid add without a grid says to build one" {
    # US-35.10
    local repo; repo="$(make_repo)"
    add_branch "$repo" fix-1
    [ "$status" -ne 0 ]
    [[ "$output" == *"No grid for"* ]]
    [ ! -d "$CODE/myrepo-fix-1" ]
}

# ─── Ctrl-p N (US-35.8, D20) ───

# The key opens a popup that reads the branch with `read`, so typed text is
# only ever data: tmux's command-prompt would paste it into a command and parse
# it again, expanding $VAR on the way.
prompt_add() {
    local dir="$1" input="$2"
    run zsh -c "cd '$dir' && source '$DEV_ZSH' 2>/dev/null; dev grid add --prompt" <<< "$input"
}

prefix_key() { tmux list-keys -T prefix | awk -v k="$1" '$4 == k'; }

@test "the prompt adds the branch typed into it" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    prompt_add "$repo" fix-1
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-fix-1' ]
}

@test "the prompt with nothing typed creates nothing" {
    # US-35.8
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    prompt_add "$repo" ""
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "text typed into the prompt is never run" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    export DEV_WORKTREE_CREATE_CMD="mkdir -p $CODE/inj; echo $CODE/inj"
    # Runs under sh and zsh alike (zsh does not split ${IFS}), and git
    # accepts it as a branch — or the test would pass without reaching the
    # code it guards.
    local payload="x\$(true>$BATS_TEST_TMPDIR/pwned)"
    git check-ref-format --branch "$payload"
    prompt_add "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

# `dev ARGS` on a real terminal through the pty helper. Keys go in with
# tty_keys, the screen collects in $TTY_LOG. Waits run up to 30s: on a loaded
# machine a prompt can take far longer than usual, and each ends when done.
tty_dev() {
    local dir="$1"; shift
    TTY_LOG="$BATS_TEST_TMPDIR/tty.log" TTY_KEYS="$BATS_TEST_TMPDIR/tty.keys"
    rm -f "$TTY_LOG" "$TTY_KEYS"
    mkfifo "$TTY_KEYS"
    python3 "$PROJECT_ROOT/tests/pty_client.py" "$TTY_KEYS" "$TTY_LOG" 120 40 -- \
        zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev "$@"' _ "$dir" "$DEV_ZSH" "$@" >/dev/null 2>&1 3>&- &
    TTY_CLIENT=$!
}
tty_keys() { printf '%s' "$1" > "$TTY_KEYS"; }
tty_wait_for() {
    local i
    for i in $(seq 1 150); do grep -aq -- "$1" "$TTY_LOG" 2>/dev/null && return 0; sleep 0.2; done
    return 1
}
tty_wait_exit() {
    local i
    for i in $(seq 1 150); do kill -0 "$TTY_CLIENT" 2>/dev/null || return 0; sleep 0.2; done
    return 1
}

@test "on a terminal, a failed prompt add stays open until Enter" {
    # prefix N's popup closes with the command; the error must be readable.
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    tty_dev "$repo" grid add --prompt
    tty_wait_for 'Branch for the new tab'
    tty_keys $'bad name\r'
    tty_wait_for 'Press Enter to close'
    grep -aq 'not a valid branch name' "$TTY_LOG"
    sleep 0.5
    kill -0 "$TTY_CLIENT"
    tty_keys $'\r'
    tty_wait_exit
}

@test "on a terminal, a failed prefix X remove stays open until Enter" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    tmux new-session -d -s other
    tty_dev "$repo" grid remove --pane "$(tmux display-message -p -t '=other:' '#{pane_id}')"
    tty_wait_for 'Press Enter to close'
    grep -aq 'not a grid tab' "$TTY_LOG"
    sleep 0.5
    kill -0 "$TTY_CLIENT"
    tty_keys $'\r'
    tty_wait_exit
}

@test "prefix N opens the new-branch prompt in the current pane's directory" {
    start_isolated_server
    zsh -c "source '$DEV_ZSH'" </dev/null
    local binding; binding="$(prefix_key N)"
    # Full size, like the other popups: provisioning a worktree prints a lot.
    # The pane is passed so the prompt starts in its directory (e2e checks it).
    [[ "$binding" == *"__dialog"*"#{pane_id}"*"90%"* ]]
    [[ "$binding" == *"$DEV_ZSH"*"grid add --prompt"* ]]
}

@test "prefix N is left alone when the user bound it" {
    # D17: dev never takes a key someone else bound.
    start_isolated_server
    tmux bind-key N display-message mine
    zsh -c "source '$DEV_ZSH'" </dev/null
    [[ "$(prefix_key N)" == *"display-message mine"* ]]
}

@test "prefix N bound by an older dev is rebound" {
    start_isolated_server
    tmux bind-key N display-popup -E zsh /old/dev.zsh grid add --prompt
    zsh -c "source '$DEV_ZSH'" </dev/null
    [[ "$(prefix_key N)" == *"$DEV_ZSH"* ]]
}

# ─── Bare `dev` in a repo (US-36, D22) ───

run_bare_dev() {
    run zsh -c "cd '$1' && source '$DEV_ZSH' 2>/dev/null; dev" </dev/null
}

@test "dev alone inside a repo builds its grid" {
    # US-36.1
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_bare_dev "$repo"
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "dev alone inside a worktree reuses the main repo's grid" {
    # US-36.2/36.3
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    run_bare_dev "$CODE/myrepo-feat"
    [[ "$output" == *"Attaching to grid: myrepo-grid"* ]]
    [ "$(tmux list-sessions | grep -c grid)" -eq 1 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

# ─── Drift, sync, prune, kill (US-16, US-19, US-20, US-21, D13, D14) ───

grid_cmd() {
    local dir="$1"; shift
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev grid "$@"' _ "$dir" "$DEV_ZSH" "$@" </dev/null
}

@test "re-entering a grid reports worktrees added and removed" {
    # US-19.1 / US-20.1
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b gone "$CODE/myrepo-gone"
    run_grid "$repo"
    git -C "$repo" worktree add -q -b new1 "$CODE/myrepo-new1"
    git -C "$repo" worktree add -q -b new2 "$CODE/myrepo-new2"
    git -C "$repo" worktree remove "$CODE/myrepo-gone"
    run_grid "$repo"
    [[ "$output" == *"2 workspaces added, 1 removed"* ]]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-gone' ]
}

@test "sync appends new worktrees and leaves every tab number alone" {
    # US-19.2/19.3
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    run_grid "$repo"
    git -C "$repo" worktree add -q -b b "$CODE/myrepo-b"
    grid_cmd "$repo" sync
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-a\n3 myrepo-b' ]
    [[ "$(tmux show-options -w -t '=dev-myrepo-grid:3' -v @dev_ws_id)" =~ ^myrepo-b- ]]
}

@test "sync names a new tab by its .dev-grid label" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    printf '%s\n' "$repo" > "$repo/.dev-grid"
    run_grid "$repo"
    printf '%s\tapi\n' "$CODE/myrepo-a" >> "$repo/.dev-grid"
    grid_cmd "$repo" sync
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 api' ]
}

@test "sync with nothing new says so" {
    # US-19.4
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    grid_cmd "$repo" sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to sync"* ]]
}

@test "sync refuses to go past nine tabs and says how to proceed" {
    # US-19.5 / D13
    local repo i; repo="$(make_repo)"
    for i in 2 3 4 5 6 7 8; do git -C "$repo" worktree add -q -b "b$i" "$CODE/myrepo-$i"; done
    run_grid "$repo"
    git -C "$repo" worktree add -q -b x "$CODE/myrepo-x"
    git -C "$repo" worktree add -q -b y "$CODE/myrepo-y"
    grid_cmd "$repo" sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"dev grid prune"* ]]
    [ "$(tmux list-windows -t '=dev-myrepo-grid:' | wc -l | tr -d ' ')" -eq 8 ]
}

@test "sync --dry-run shows what it would add and adds nothing" {
    # US-16.2
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    git -C "$repo" worktree add -q -b b "$CODE/myrepo-b"
    grid_cmd "$repo" sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"myrepo-b"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "prune removes the tab of a removed worktree, and its popups" {
    # US-20.2
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b gone "$CODE/myrepo-gone"
    git -C "$repo" worktree add -q -b keep "$CODE/myrepo-keep"
    run_grid "$repo"
    local id; id="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    tmux new-session -d -s "term-$id" "sleep 300"
    tmux set-option -t "=term-$id:" @dev_parent "$(tmux display-message -p -t '=dev-myrepo-grid:' '#{session_id}')"
    tmux set-option -w -t "=term-$id:" @dev_ws_id "$id"
    git -C "$repo" worktree remove "$CODE/myrepo-gone"
    grid_cmd "$repo" prune
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n3 myrepo-keep' ]
    ! tmux has-session -t "=term-$id" 2>/dev/null
}

@test "prune --dry-run removes nothing" {
    # US-16.3
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b gone "$CODE/myrepo-gone"
    run_grid "$repo"
    git -C "$repo" worktree remove "$CODE/myrepo-gone"
    grid_cmd "$repo" prune --dry-run
    [[ "$output" == *"myrepo-gone"* ]]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-gone' ]
}

# A window the user opens in the grid themselves carries no workspace stamp.
@test "dev grid status calls a plain window not a workspace" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    tmux new-window -d -t '=dev-myrepo-grid:2' -n scratch
    grid_cmd "$repo" status
    [ "$status" -eq 0 ]
    [[ "$output" =~ 2\ +scratch\ +-\ +not\ a\ workspace ]]
}

@test "prune leaves a plain window alone" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    tmux new-window -d -t '=dev-myrepo-grid:2' -n scratch
    grid_cmd "$repo" prune --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to prune"* ]]
}

@test "dev grid kill removes the grid and its popups" {
    # US-21.1
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    tmux new-session -d -s keep
    tmux new-session -d -s term-x "sleep 300"
    tmux set-option -t '=term-x:' @dev_parent "$(tmux display-message -p -t '=dev-myrepo-grid:' '#{session_id}')"
    grid_cmd "$repo" kill
    [ "$status" -eq 0 ]
    [ "$(tmux list-sessions -F '#{session_name}')" = "keep" ]
}

@test "dev grid kill --dry-run kills nothing" {
    # US-16.4
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    grid_cmd "$repo" kill --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dev-myrepo-grid"* ]]
    tmux has-session -t '=dev-myrepo-grid'
}

@test "dev grid kill finds nothing to kill in an unstamped session" {
    # US-21.2/21.3: never by name.
    local repo; repo="$(make_repo)"
    start_isolated_server dev-myrepo-grid
    grid_cmd "$repo" kill
    [ "$status" -ne 0 ]
    [[ "$output" == *"No grid for"* ]]
    tmux has-session -t '=dev-myrepo-grid'
}

# ─── Where the workspaces come from (US-22, D7, D11, D12) ───

@test "a .dev-grid file chooses the workspaces and their labels" {
    # US-22.5/22.8/22.9/22.11
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    git -C "$repo" worktree add -q -b b "$CODE/myrepo-b"
    printf '# my week\n\n../myrepo-b\tbugfix\n%s\n' "$repo" > "$repo/.dev-grid"
    run_grid "$repo"
    [ "$(windows dev-myrepo-grid)" = $'1 bugfix\n2 myrepo' ]
}

@test "a .dev-grid file is read, never run" {
    # US-22.7 / D7: a cloned repo must not be able to run code on dev grid.
    local repo; repo="$(make_repo)"
    printf '#!/bin/sh\ntouch "%s/pwned"\necho %s\n' "$BATS_TEST_TMPDIR" "$repo" > "$repo/.dev-grid"
    chmod +x "$repo/.dev-grid"
    run_grid "$repo"
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "a .dev-grid line naming a missing directory is skipped with a warning" {
    # US-22.10
    local repo; repo="$(make_repo)"
    printf '%s\n%s\n' "$repo" "$CODE/nowhere" > "$repo/.dev-grid"
    run_grid "$repo"
    [[ "$output" == *"nowhere"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "a .dev-grid with nothing usable is an error that says why" {
    # US-22.12 / D11
    local repo; repo="$(make_repo)"
    printf '%s\n' "$CODE/nowhere" > "$repo/.dev-grid"
    run_grid "$repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 entry"*"skipped"* ]]
    ! tmux has-session -t '=dev-myrepo-grid' 2>/dev/null
}

@test "DEV_GRID_CMD's output is the workspace list" {
    # US-22.1
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    export DEV_GRID_CMD="printf '%s\tslot\n' '$CODE/myrepo-a'"
    run_grid "$repo"
    [ "$(windows dev-myrepo-grid)" = "1 slot" ]
}

@test "a failing DEV_GRID_CMD is an error, never a fall back to git" {
    # US-22.2/22.4 / D12
    local repo; repo="$(make_repo)"
    export DEV_GRID_CMD="echo broken >&2; exit 4"
    run_grid "$repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"grid_cmd exited 4"* ]]
    [[ "$output" == *"broken"* ]]
    ! tmux has-session -t '=dev-myrepo-grid' 2>/dev/null
}

@test "a relative path from DEV_GRID_CMD is read from the repo root" {
    # Run two levels down, where ../myrepo-a names another directory that
    # also exists: only the repo root gives the right one.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    git -C "$repo" worktree add -q -b deep "$CODE/nested/deep/wt"
    mkdir -p "$CODE/nested/deep/myrepo-a"
    export DEV_GRID_CMD="printf '../myrepo-a\tslot\n'"
    run_grid "$CODE/nested/deep/wt"
    [ "$(text_opt -w -t '=dev-myrepo-grid:1' @dev_workspace)" = "$CODE/myrepo-a" ]
}

@test "a DEV_GRID_CMD that prints nothing is an error too" {
    # US-22.3
    local repo; repo="$(make_repo)"
    export DEV_GRID_CMD="true"
    run_grid "$repo"
    [ "$status" -ne 0 ]
    ! tmux has-session -t '=dev-myrepo-grid' 2>/dev/null
}

# ─── --filter, --limit, selection, --session (US-17, US-15.5, D10, D15) ───

many_worktrees() {
    REPO="$(make_repo)"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11; do git -C "$REPO" worktree add -q -b "io$i" "$CODE/myrepo-io$i"; done
}

@test "--filter keeps the matching workspaces" {
    # US-17.3
    many_worktrees
    run_grid "$REPO" --filter io1
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo-io1\n2 myrepo-io10\n3 myrepo-io11' ]
}

@test "--filter, then --limit, then the cap" {
    # US-17.4/17.5
    many_worktrees
    # git lists worktrees by name: io1, io10, io11, io2, ...
    run_grid "$REPO" --filter io --limit 2
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo-io1\n2 myrepo-io10' ]
}

@test "--limit outside 1-9 is an error, not a clamp" {
    # US-17.6/17.7
    local repo; repo="$(make_repo)"
    run_grid "$repo" --limit 10
    [ "$status" -ne 0 ]
    [[ "$output" == *"--limit takes 1-9"* ]]
    run_grid "$repo" --limit 0
    [ "$status" -ne 0 ]
    run_grid "$repo" --limit x
    [ "$status" -ne 0 ]
    ! tmux has-session -t '=dev-myrepo-grid' 2>/dev/null
}

@test "--filter matching nothing names the filter and what there is" {
    # US-17.8
    many_worktrees
    run_grid "$REPO" --filter zzz
    [ "$status" -ne 0 ]
    [[ "$output" == *"zzz"*"12 workspaces"* ]]
}

@test "sync keeps a filtered grid's filter" {
    many_worktrees
    run_grid "$REPO" --filter io1
    git -C "$REPO" worktree add -q -b io12 "$CODE/myrepo-io12"
    git -C "$REPO" worktree add -q -b other "$CODE/myrepo-other"
    grid_cmd "$REPO" sync
    [ "$(windows dev-myrepo-grid | tail -1)" = "4 myrepo-io12" ]
}

@test "over nine on a terminal asks which, writes .dev-grid and keeps it out of git" {
    # US-17.1 (a TTY via the pty helper)
    many_worktrees
    local log="$BATS_TEST_TMPDIR/sel.log" keys="$BATS_TEST_TMPDIR/sel.keys"
    mkfifo "$keys"
    python3 "$PROJECT_ROOT/tests/pty_client.py" "$keys" "$log" 120 40 -- \
        zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid' _ "$REPO" "$DEV_ZSH" >/dev/null 2>&1 3>&- &
    local client=$! i
    # Up to 30s each: on a heavily loaded machine the prompt, and then the
    # build, can take far longer than usual; each loop ends as soon as it is done.
    for i in $(seq 1 150); do grep -aq 'Pick up to 9' "$log" 2>/dev/null && break; sleep 0.2; done
    printf '2 4-5\r' > "$keys"
    for i in $(seq 1 150); do [ "$(tmux list-windows -t '=dev-myrepo-grid:' 2>/dev/null | wc -l | tr -d ' ')" -eq 3 ] && break; sleep 0.2; done
    kill "$client" 2>/dev/null || true
    # Picks 2, 4 and 5 of the list as git orders it: myrepo, io1, io10, io11, io2, ...
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo-io1\n2 myrepo-io11\n3 myrepo-io2' ]
    [ "$(cat "$REPO/.dev-grid")" = "$(printf '%s\n' "$CODE/myrepo-io1" "$CODE/myrepo-io11" "$CODE/myrepo-io2")" ]
    grep -qx '.dev-grid' "$REPO/.git/info/exclude"
    # The saved choice is the next build's list: off a terminal, no prompt.
    tmux kill-session -t '=dev-myrepo-grid'
    run_grid "$REPO"
    [[ "$output" != *"Pick up to 9"* ]]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo-io1\n2 myrepo-io11\n3 myrepo-io2' ]
}

# Answers the over-nine prompt with a bad pick and checks nothing was built.
bad_pick() {
    many_worktrees
    tty_dev "$REPO" grid
    tty_wait_for 'Pick up to 9'
    tty_keys "$1"$'\r'
    # A build that went ahead attaches and never exits; the checks say why.
    tty_wait_exit || true
    [ ! -e "$REPO/.dev-grid" ]
    [ -z "$(tmux list-sessions 2>/dev/null)" ]
    grep -aq -- "$2" "$TTY_LOG"
}

@test "a pick that is not a number or a range builds nothing" {
    bad_pick '1 x' "'x' is not a number or a range"
}

@test "a pick past the last workspace builds nothing" {
    bad_pick '1 13' '13 is not in 1-12'
}

@test "more than nine picks build nothing" {
    bad_pick '1-10' 'pick between 1 and 9'
}

@test "an empty pick builds nothing" {
    bad_pick '' 'pick between 1 and 9'
}

@test "--session builds under another name, and verbs still find it" {
    # US-15.5/15.6 / D15
    local repo; repo="$(make_repo)"
    run_grid "$repo" --session mine
    tmux has-session -t '=mine'
    grid_cmd "$repo" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"myrepo"* ]]
}

@test "the refusal names --session as a way out" {
    # US-15.2
    local repo; repo="$(make_repo)"
    start_isolated_server dev-myrepo-grid
    run_grid "$repo"
    [[ "$output" == *"--session"* ]]
}

# ─── Review fixes (2026-10-01): drift, prune and lookups ───

@test "prune never closes a tab whose worktree still exists, filtered or not" {
    # A tab outside --filter / --limit is not a removed worktree.
    many_worktrees
    run_grid "$REPO" --filter io1
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    grid_cmd "$REPO" add feat
    # Or the grid holds no tab outside the filter and this proves nothing.
    [ "$status" -eq 0 ]
    [[ "$(windows dev-myrepo-grid)" == *$'\n4 myrepo-feat'* ]]
    grid_cmd "$REPO" prune --dry-run
    [[ "$output" == *"Nothing to prune"* ]]
}

@test "a failing workspace source stops sync and prune instead of emptying the grid" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    run_grid "$repo"
    export DEV_GRID_CMD=false
    grid_cmd "$repo" prune
    [ "$status" -ne 0 ]
    grid_cmd "$repo" sync
    [ "$status" -ne 0 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-a' ]
    run_grid "$repo"
    [[ "$output" != *"removed — run"* ]]
    [[ "$output" == *"Could not read the workspace list"* ]]
}

@test "prune closes the right tabs when tmux renumbers windows" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    git -C "$repo" worktree add -q -b b "$CODE/myrepo-b"
    git -C "$repo" worktree add -q -b keep "$CODE/myrepo-keep"
    run_grid "$repo"
    tmux set-option -g renumber-windows on
    git -C "$repo" worktree remove "$CODE/myrepo-a"
    git -C "$repo" worktree remove "$CODE/myrepo-b"
    grid_cmd "$repo" prune
    [ "$status" -eq 0 ]
    [ "$(tmux list-windows -t '=dev-myrepo-grid:' -F '#{window_name}')" = $'myrepo\nmyrepo-keep' ]
}

@test "--session with a name dev would not accept builds nothing" {
    local repo; repo="$(make_repo)"
    run_grid "$repo" --session 'bad.name'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Session name can only contain"* ]]
    [ -z "$(tmux list-sessions 2>/dev/null)" ]
}

@test "an unknown option is an error and builds nothing" {
    local repo; repo="$(make_repo)"
    run_grid "$repo" --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown option --bogus"* ]]
    [ -z "$(tmux list-sessions 2>/dev/null)" ]
}

@test "an option without its value is an error, not a hang" {
    local repo; repo="$(make_repo)"
    run_grid "$repo" --limit
    [ "$status" -ne 0 ]
    [[ "$output" == *"--limit needs a value"* ]]
}

@test "a second grid for the same repo is refused" {
    # D15: ambiguity is reported, never guessed.
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    run_grid "$repo" --session mine
    [ "$status" -ne 0 ]
    [[ "$output" == *"already"*"dev-myrepo-grid"* ]]
    ! tmux has-session -t '=mine' 2>/dev/null
}

@test "two sessions stamped for one repo make verbs refuse and list both" {
    # US-15.7
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    tmux new-session -d -s other
    tmux set-option -t '=other:' @dev_grid "$repo"
    grid_cmd "$repo" kill
    [ "$status" -ne 0 ]
    [[ "$output" == *"dev-myrepo-grid"*"other"* ]]
    tmux has-session -t '=dev-myrepo-grid'
}

@test "a relative path from the create command is read from the repo root" {
    local repo; repo="$(make_repo)"
    # Run from a worktree two levels down, where ../myrepo-feat2 means
    # something else: the command ran in the repo root, so that is the base.
    git -C "$repo" worktree add -q -b deep "$CODE/nested/deep/wt"
    run_grid "$repo"
    git -C "$repo" worktree add -q -b feat2 "$CODE/myrepo-feat2"
    export DEV_WORKTREE_CREATE_CMD="echo ../myrepo-feat2"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid add other' _ "$CODE/nested/deep/wt" "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    [ "$(text_opt -w -t '=dev-myrepo-grid:3' @dev_workspace)" = "$CODE/myrepo-feat2" ]
}

@test "a # in a worktree path or label is taken literally, not as a tmux format" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b hash "$CODE/fix#Sx"
    run_grid "$repo"
    [ "$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{window_name}')" = 'fix#Sx' ]
    [ "$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_current_path}')" = "$CODE/fix#Sx" ]
}

@test "a | in a label does not shift the columns" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    printf '%s\tapi|v2\n' "$CODE/myrepo-a" > "$repo/.dev-grid"
    run_grid "$repo"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev agent status --json' _ "$repo" "$DEV_ZSH" </dev/null
    printf '%s\n' "$output" | python3 -c '
import json, sys
row = json.loads(sys.stdin.readline())
assert row["label"] == "api|v2" and row["branch"] == "a" and row["path"].endswith("myrepo-a"), row'
}

@test "a bare repo's worktrees each get a tab, the bare directory none" {
    # The layout `git clone --bare` plus worktrees: no main checkout at all.
    local src; src="$(make_repo src)"
    git clone -q --bare "$src" "$CODE/proj.git"
    git -C "$CODE/proj.git" worktree add -q "$CODE/proj-main" main
    git -C "$CODE/proj.git" worktree add -q -b a "$CODE/proj-a"
    run_grid "$CODE/proj-a"
    # Named after the bare directory, .git and all; tabs in git's (name) order.
    run windows dev-proj-git-grid
    [ "$output" = $'1 proj-a\n2 proj-main' ]
}

@test "a non-ASCII workspace path survives a C locale" {
    # tmux turns non-ASCII into _ on the way out when the client is not
    # UTF-8; dev's hex text options must still give the real path back.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/café"
    export LC_ALL=C
    run_grid "$repo"
    # A garbled path would read as missing, not as branch a.
    grid_cmd "$repo" status
    [[ "$output" =~ 2\ +[^\ ]+\ +a\ +clean ]]
}

@test "a workspace git cannot read is reported, never shown as clean" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    run_grid "$repo"
    rm -rf "$CODE/myrepo-a"
    grid_cmd "$repo" status
    [[ "$output" =~ 2\ +myrepo-a\ +-\ +missing ]]
}

# ─── dev grid remove (US-38) ───

# --yes: off a terminal, remove refuses to delete anything without it.
remove_cmd() {
    local dir="$1"; shift
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev grid remove "$@"' _ "$dir" "$DEV_ZSH" "$@" --yes </dev/null
}

@test "remove deletes the worktree, closes its tab, and keeps the branch" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    git -C "$repo" worktree add -q -b keep "$CODE/myrepo-keep"
    run_grid "$repo"
    remove_cmd "$repo" 2
    [ "$status" -eq 0 ]
    [ ! -d "$CODE/myrepo-feat" ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n3 myrepo-keep' ]
    git -C "$repo" show-ref --verify --quiet refs/heads/feat
}

@test "a new tab fills the lowest free number and no tab moves" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    git -C "$repo" worktree add -q -b b "$CODE/myrepo-b"
    run_grid "$repo"
    remove_cmd "$repo" 2
    [ "$status" -eq 0 ]
    add_branch "$repo" x
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-x\n3 myrepo-b' ]
}

@test "remove refuses a workspace with uncommitted changes" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    touch "$CODE/myrepo-feat/unsaved.txt"
    remove_cmd "$repo" myrepo-feat
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"*"--force"* ]]
    [ -d "$CODE/myrepo-feat" ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "remove --force removes it anyway" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    touch "$CODE/myrepo-feat/unsaved.txt"
    remove_cmd "$repo" 2 --force
    [ "$status" -eq 0 ]
    [ ! -d "$CODE/myrepo-feat" ]
}

@test "the main checkout is never removed" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    remove_cmd "$repo" 1 --force
    [ "$status" -ne 0 ]
    [[ "$output" == *"main checkout"* ]]
    [ -d "$repo/.git" ]
}

@test "remove --dry-run changes nothing" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    remove_cmd "$repo" 2 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would remove"* ]]
    [ -d "$CODE/myrepo-feat" ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "remove closes the tab's popups too" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    local id; id="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    tmux new-session -d -s "term-$id" "sleep 300"
    tmux set-option -t "=term-$id:" @dev_parent "$(tmux display-message -p -t '=dev-myrepo-grid:' '#{session_id}')"
    tmux set-option -w -t "=term-$id:" @dev_ws_id "$id"
    remove_cmd "$repo" 2
    ! tmux has-session -t "=term-$id" 2>/dev/null
}

@test "a configured remove command is used, with the values quoted" {
    # e.g. bin/agent-grid worktree remove {path}, which also drops its database.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    export DEV_WORKTREE_REMOVE_CMD="printf '%s|%s' {path} {branch} > '$BATS_TEST_TMPDIR/got'; git worktree remove {path}"
    remove_cmd "$repo" 2
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/got")" = "$CODE/myrepo-feat|feat" ]
    [ ! -d "$CODE/myrepo-feat" ]
}

# A value is filled in once and never read again as a template: a path that
# contains "{branch}" is the path, not a second placeholder outside the quotes.
@test "a placeholder inside a filled-in path is left as text" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b 'x;touch${IFS}pwned' "$CODE/myrepo-{branch}"
    run_grid "$repo"
    export DEV_WORKTREE_REMOVE_CMD="printf '%s|%s' {path} {branch} > '$BATS_TEST_TMPDIR/got'; git worktree remove {path}"
    remove_cmd "$repo" 2
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/got")" = "$CODE/myrepo-{branch}|x;touch\${IFS}pwned" ]
    [ ! -e "$repo/pwned" ] && [ ! -e "$CODE/pwned" ]
    [ ! -d "$CODE/myrepo-{branch}" ]
}

@test "a detached worktree gives the remove command an empty branch" {
    # Agent-grid slots are detached; "(detached abc123)" is not a branch name.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q --detach "$CODE/myrepo-slot"
    run_grid "$repo"
    export DEV_WORKTREE_REMOVE_CMD="printf '[%s]' {branch} > '$BATS_TEST_TMPDIR/got'; git worktree remove {path}"
    remove_cmd "$repo" 2
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/got")" = "[]" ]
}

@test "a workspace git cannot read counts as changed and is kept without --force" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    echo "gitdir: /nowhere" > "$CODE/myrepo-feat/.git"
    remove_cmd "$repo" 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"--force"* ]]
    [ -d "$CODE/myrepo-feat" ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "remove with no tab removes the tab it is run in" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    run env TMUX_PANE="$pane" zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid remove --yes' _ "$CODE/myrepo-feat" "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    [ ! -d "$CODE/myrepo-feat" ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "remove with no tab outside tmux prints its usage" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid remove --yes' _ "$repo" "$DEV_ZSH" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: dev grid remove"* ]]
}

@test "remove --pane refuses a pane that is not a grid tab" {
    # prefix X pressed in a popup or another session must delete nothing.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    tmux new-session -d -s other -c "$CODE/myrepo-feat"
    local pane; pane="$(tmux display-message -p -t '=other:' '#{pane_id}')"
    remove_cmd "$repo" --pane "$pane"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a grid tab"* ]]
    [ -d "$CODE/myrepo-feat" ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "remove --pane refuses a popup of a grid tab" {
    # A popup's pane leads back to the grid through @dev_origin, but its
    # window number is the popup's, not a tab's: it must delete nothing.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    tmux new-session -d -s popup
    tmux new-window -d -t '=popup:2'
    tmux set-option -w -t '=popup:2' @dev_origin "$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    remove_cmd "$repo" --pane "$(tmux display-message -p -t '=popup:2' '#{pane_id}')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a grid tab"* ]]
    [ -d "$CODE/myrepo-feat" ]
}

@test "a failing remove command keeps the tab and does not fall back to git" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    export DEV_WORKTREE_REMOVE_CMD="echo 'that is a slot' >&2; exit 5"
    remove_cmd "$repo" 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"exited 5"* ]]
    [ -d "$CODE/myrepo-feat" ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "a workspace whose folder is already gone just loses its tab" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    rm -rf "$CODE/myrepo-feat"
    remove_cmd "$repo" 2
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

@test "remove of a name not in the grid lists the tabs" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    remove_cmd "$repo" nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 myrepo"* ]]
}

@test "off a terminal, remove refuses without --yes" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid remove 2' _ "$repo" "$DEV_ZSH" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"--yes"* ]]
    [ -d "$CODE/myrepo-feat" ]
}

# Answers remove's question on a real terminal, through the pty helper.
answer_remove() {
    local answer="$1" log="$BATS_TEST_TMPDIR/rm.log" keys="$BATS_TEST_TMPDIR/rm.keys" i
    mkfifo "$keys"
    python3 "$PROJECT_ROOT/tests/pty_client.py" "$keys" "$log" 120 40 -- \
        zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid remove 2' _ "$REPO" "$DEV_ZSH" >/dev/null 2>&1 3>&- &
    local client=$!
    # Up to 30s each, as for the selection prompt: a loaded machine is slow.
    for i in $(seq 1 150); do grep -aq 'Type y to remove' "$log" 2>/dev/null && break; sleep 0.2; done
    grep -aq 'myrepo-feat' "$log"
    grep -aq 'branch feat is kept' "$log"
    printf '%s\r' "$answer" > "$keys"
    for i in $(seq 1 150); do kill -0 "$client" 2>/dev/null || break; sleep 0.2; done
    kill "$client" 2>/dev/null || true
}

@test "on a terminal, remove shows what it will do and needs a y" {
    REPO="$(make_repo)"
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$REPO"
    answer_remove n
    grep -aq 'Kept\.' "$BATS_TEST_TMPDIR/rm.log"
    [ -d "$CODE/myrepo-feat" ]
    rm -f "$BATS_TEST_TMPDIR/rm.keys" "$BATS_TEST_TMPDIR/rm.log"
    answer_remove y
    [ ! -d "$CODE/myrepo-feat" ]
}

@test "prefix X asks to remove the tab it was pressed in" {
    start_isolated_server
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    local binding; binding="$(tmux list-keys -T prefix | awk '$4 == "X"')"
    [[ "$binding" == *"__dialog"* && "$binding" == *"grid remove --pane"* ]]
}

@test "prefix W closes the tab it was pressed in" {
    start_isolated_server
    zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    local binding; binding="$(tmux list-keys -T prefix | awk '$4 == "W"')"
    [[ "$binding" == *"__dialog"* && "$binding" == *"grid close --pane"* ]]
}

@test "close --pane acts on the tab that pane is in" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    run zsh -c 'cd / && source "$1" 2>/dev/null; dev grid close --pane "$2"' _ "$DEV_ZSH" "$pane" </dev/null
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
    [ -d "$CODE/myrepo-feat" ]
}

@test "remove --pane acts on the tab that pane is in" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    run zsh -c 'cd / && source "$1" 2>/dev/null; dev grid remove --pane "$2" --yes' _ "$DEV_ZSH" "$pane" </dev/null
    [ "$status" -eq 0 ]
    [ ! -d "$CODE/myrepo-feat" ]
}

@test "a configured remove command gets {force} only with --force" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    git -C "$repo" worktree add -q -b other "$CODE/myrepo-other"
    run_grid "$repo"
    export DEV_WORKTREE_REMOVE_CMD="printf '[%s]' {force} >> '$BATS_TEST_TMPDIR/got'; git worktree remove {force} {path}"
    remove_cmd "$repo" 2
    remove_cmd "$repo" myrepo-other --force
    [ "$(cat "$BATS_TEST_TMPDIR/got")" = "[][--force]" ]
}

@test "uncommitted changes are refused even when the remove command would not check" {
    # git worktree remove refuses a dirty worktree itself; a configured command
    # may not, so dev's own check is what protects the work.
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    touch "$CODE/myrepo-feat/unsaved.txt"
    export DEV_WORKTREE_REMOVE_CMD="rm -rf {path} && git worktree prune"
    remove_cmd "$repo" 2
    [ "$status" -ne 0 ]
    [ -f "$CODE/myrepo-feat/unsaved.txt" ]
}

# ─── dev grid close ───

close_cmd() {
    local dir="$1"; shift
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev grid close "$@"' _ "$dir" "$DEV_ZSH" "$@" </dev/null
}

# A popup session of tab $1 of the myrepo grid, as dev marks one.
tab_popup() {
    local id; id="$(tmux show-options -w -t "=dev-myrepo-grid:$1" -v @dev_ws_id)"
    tmux new-session -d -s "term-$id" "sleep 300"
    tmux set-option -t "=term-$id:" @dev_parent "$(tmux display-message -p -t '=dev-myrepo-grid:' '#{session_id}')"
    tmux set-option -w -t "=term-$id:" @dev_ws_id "$id"
    printf '%s' "term-$id"
}

@test "close closes a tab and its popups, and keeps its worktree" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    git -C "$repo" worktree add -q -b keep "$CODE/myrepo-keep"
    run_grid "$repo"
    local popup; popup="$(tab_popup 2)"
    close_cmd "$repo" 2
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n3 myrepo-keep' ]
    ! tmux has-session -t "=$popup" 2>/dev/null
    [ -d "$CODE/myrepo-feat" ]
    git -C "$repo" worktree list | grep -q "myrepo-feat"
    [[ "$output" == *"dev grid sync"* ]]
}

@test "a closed tab comes back with sync" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    close_cmd "$repo" myrepo-feat
    [ "$status" -eq 0 ]
    grid_cmd "$repo" sync
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "close --dry-run changes nothing" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    local popup; popup="$(tab_popup 2)"
    close_cmd "$repo" 2 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would close tab 2 (myrepo-feat) and 1 popup"* ]]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
    tmux has-session -t "=$popup"
}

@test "close with no tab closes the tab it is run in" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$repo"
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    run env TMUX_PANE="$pane" zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid close' _ "$CODE/myrepo-feat" "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
    [ -d "$CODE/myrepo-feat" ]
}

@test "close with no tab outside tmux prints its usage" {
    local repo; repo="$(make_repo)"
    run_grid "$repo"
    close_cmd "$repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: dev grid close"* ]]
}
