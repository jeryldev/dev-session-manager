#!/usr/bin/env bats
# Tests for `dev grid`: one tmux session, one tab per git worktree.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    # HOME is redirected, so git has no identity to commit with.
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    CODE="$(cd "$HOME/code" && pwd -P)"
}

teardown() {
    teardown_tmux
}

# A repo with one commit. Further worktrees are added by each test.
make_repo() {
    local repo="$CODE/${1:-myrepo}"
    git init -q -b main "$repo"
    git -C "$repo" commit -q --allow-empty -m init
    echo "$repo"
}

# `dev grid` ends in an attach, which fails without a terminal (as `dev <name>`
# does). Build tests therefore assert on the session, not on this status.
run_grid() {
    local dir="$1"; shift
    run zsh -c "cd '$dir' && source '$DEV_ZSH' 2>/dev/null; dev grid $*" </dev/null
}

windows() { tmux list-windows -t "=$1:" -F '#{window_index} #{window_name}'; }

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
    [ "$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_workspace)" = "$CODE/myrepo-feat" ]
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
    [ "$(tmux show-options -t '=dev-myrepo-grid:' -v @dev_grid)" = "$repo" ]
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
    [ "$(tmux show-options -w -t '=dev-myrepo-grid:3' -v @dev_workspace)" = "$CODE/myrepo-fix-1" ]
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
    [[ "$output" == *"exit 3"* || "$output" == *"exited 3"* ]]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
    [ ! -d "$CODE/myrepo-nope" ]
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

@test "prefix N opens the new-branch prompt in the current pane's directory" {
    start_isolated_server
    zsh -c "source '$DEV_ZSH'" </dev/null
    local binding; binding="$(prefix_key N)"
    [[ "$binding" == *"display-popup"* ]]
    [[ "$binding" == *"#{pane_current_path}"* ]]
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
