#!/usr/bin/env bats
# The suite must not read the developer's own settings or write their state.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
}

@test "a developer's exported DEV_* settings do not reach the tests" {
    export DEV_WINDOWS=one DEV_GRID_CMD=false DEV_KEY_AGENT=z DEV_WORKTREE_REMOVE_CMD=false
    isolate_tmux
    [ -z "$(compgen -e | grep '^DEV_')" ]
}

@test "state is written under the test's directory, not the developer's" {
    export XDG_STATE_HOME=/should/not/be/used
    isolate_tmux
    [[ "$XDG_STATE_HOME" == "$BATS_TEST_TMPDIR"/* ]]
}

@test "an agent opened without a launcher runs a stub, never the real claude" {
    isolate_tmux
    [ "$(command -v claude)" = "$BATS_TEST_TMPDIR/stub-bin/claude" ]
}
