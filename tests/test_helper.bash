#!/usr/bin/env bash
# Shared test helper for dev-session-manager bats tests

PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# Give this test its own tmux server, isolated from the developer's live one.
#
# Two things have to be isolated, and only the first is obvious:
#
#   1. The SOCKET. Setting TMUX_TMPDIR alone is not enough — when $TMUX is set,
#      which it is whenever the suite is run from inside tmux (i.e. the way this
#      tool is used), tmux takes the socket path from $TMUX and ignores
#      TMUX_TMPDIR entirely.
#
#   2. The CONFIG. dev.zsh starts servers with bare `tmux`, and a tmux server
#      reads ~/.tmux.conf at start. An isolated socket whose server was started
#      by dev.zsh still inherits the developer's settings. That is how B8 stayed
#      invisible: with `base-index 1` the seven windows land on 1-7 and the
#      suite is green, while on a stock config they land on 0 and 2-7 and
#      `prefix 1` reaches nothing. Redirecting HOME and XDG_CONFIG_HOME leaves
#      no config for any server to find, whoever starts it.
#
# Leaves the isolated socket with no server running; tests that need one call
# start_isolated_server.
isolate_tmux() {
    export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
    unset TMUX TMUX_PANE

    # Config isolation (2). DEV_DEFAULT_DIR derives from $HOME, so give it a
    # real directory to point at rather than letting tmux fall back silently.
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
    mkdir -p "$HOME/code" "$XDG_CONFIG_HOME"

    command -v tmux &>/dev/null || return 0

    # Verify the isolation instead of assuming it. Two mechanisms have already
    # failed here in a way that looked correct, so this refuses to run rather
    # than let a test pass against the wrong server.
    #
    # A server with no sessions exits immediately, so start-server is not enough
    # to make display-message answer — the probe has to be a real session.
    local sock real
    tmux -f /dev/null new-session -d -s _isolation_probe 2>/dev/null
    sock="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
    # macOS symlinks /var -> /private/var, so TMUX_TMPDIR reports /var/... while
    # tmux reports /private/var/... — both sides must be resolved before
    # comparing, or this never matches and refuses every run.
    real="$(cd "$TMUX_TMPDIR" && pwd -P)"

    # Remove only our own footprint. NEVER kill-server here: if isolation has
    # failed, the server on the other end is the developer's live one, and the
    # guard would destroy every session they had open before reporting that
    # anything was wrong. Killing the probe session is enough — on the isolated
    # socket it was the only session, so the server exits with it.
    tmux kill-session -t _isolation_probe 2>/dev/null

    if [[ "$sock" != "$real"/* ]]; then
        echo "REFUSING TO RUN: tmux resolves to '$sock', not under '$real'" >&2
        return 1
    fi
}

# Start a server on the isolated socket, for tests that need one to exist.
# -f /dev/null is belt and braces: HOME is already redirected, but this makes
# the stock-config intent explicit at the call site.
start_isolated_server() {
    tmux -f /dev/null new-session -d -s "${1:-isolated-test}"
}

# Only ever tear down a server we can prove is the isolated one.
teardown_tmux() {
    command -v tmux &>/dev/null || return 0
    [[ -n "${TMUX_TMPDIR:-}" ]] || return 0

    local sock real
    sock="$(tmux display-message -p '#{socket_path}' 2>/dev/null)" || return 0
    real="$(cd "$TMUX_TMPDIR" 2>/dev/null && pwd -P)" || return 0
    [[ "$sock" == "$real"/* ]] && tmux kill-server 2>/dev/null
    return 0
}

# Create a temporary HOME for isolated install tests
setup_temp_home() {
    export ORIGINAL_HOME="$HOME"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME"
}

teardown_temp_home() {
    if [[ -n "$HOME" && "$HOME" != "$ORIGINAL_HOME" ]]; then
        rm -rf "$HOME"
        export HOME="$ORIGINAL_HOME"
    fi
}

# Create a dev session without tripping over the attach.
#
# `dev <name>` ends in `tmux attach`, which fails with "open terminal failed"
# when stdin is not a tty — so it always exits non-zero under bats. Everything
# before the attach (validation, the seven new-window calls, select-window) has
# already run by then, so the session is fully built and inspectable. Callers
# assert on the resulting session, never on this exit status.
create_dev_session() {
    # `|| true` is load-bearing: bats runs helpers under errexit, so the attach's
    # non-zero exit would abort the test before it could inspect the session.
    zsh -c "source '$PROJECT_ROOT/dev.zsh' 2>/dev/null; dev $1" </dev/null &>/dev/null || true
    return 0
}

# Git with an identity and no developer config: HOME is redirected, and a
# repo-level hook or alias from the real config must not reach the tests.
isolate_git() {
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    CODE="$(cd "$HOME/code" && pwd -P)"
}

# A repo with one commit, under $CODE. Further worktrees are added by each test.
make_repo() {
    local repo="$CODE/${1:-myrepo}"
    git init -q -b main "$repo"
    git -C "$repo" commit -q --allow-empty -m init
    echo "$repo"
}

# `dev grid` ends in an attach, which fails without a terminal (as `dev <name>`
# does). Build tests therefore assert on the session, not on this status.
# Values travel as arguments, not spliced into the script: a test directory
# with a quote in its name must not break the helper that tests quoting.
run_grid() {
    local dir="$1"; shift
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev grid "$@"' _ "$dir" "$PROJECT_ROOT/dev.zsh" "$@" </dev/null
}

windows() { tmux list-windows -t "=$1:" -F '#{window_index} #{window_name}'; }

# A tmux option dev stores as text: hex-encoded ("hex:..."), because tmux 3.3-3.4
# rewrite `$` and non-ASCII on the way out. Decoded here in bash, rather than by
# sourcing dev.zsh, which would bind keys mid-test.
text_opt() {
    local value hex
    value="$(tmux show-options -qv "$@")"
    if [[ "$value" == hex:* ]]; then
        hex="${value#hex:}"
        printf '%b' "$(printf '%s' "$hex" | sed 's/../\\x&/g')"
    else
        printf '%s' "$value"
    fi
}
