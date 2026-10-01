#!/usr/bin/env bats
# Key bindings (plan Phase 3a, US-34, D17): bound once per change, never over
# a key someone else bound, and configurable.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    unset DEV_AI_CMD DEV_KEY_AGENT DEV_KEY_TERM DEV_KEY_GIT DEV_KEY_KB DEV_KEY_NEW
    start_isolated_server
}

teardown() {
    teardown_tmux
}

load_dev() { run zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null; }

dev_cmd() { run zsh -c 'source "$1" 2>/dev/null; shift; dev "$@"' _ "$DEV_ZSH" "$@" </dev/null; }

prefix_key() { tmux list-keys -T prefix | awk -v k="$1" '$4 == k'; }

# The shape v2.3.0 bound `prefix a` with, before any of this.
LEGACY_A='SESSION="ai-#{session_name}-#{window_index}-#{window_name}-claude"; tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -c "#{pane_current_path}" "claude --enable-auto-mode"; tmux display-popup -w 90% -h 90% -b single -E "tmux attach-session -t $SESSION"'

@test "a new shell on an unchanged machine binds nothing" {
    # Plan 3a / review D5: binding ran on every shell start.
    load_dev
    tmux unbind-key -T prefix j
    load_dev
    [ -z "$(prefix_key j)" ]
}

@test "dev reload binds again regardless" {
    load_dev
    tmux unbind-key -T prefix j
    dev_cmd reload
    [[ "$(prefix_key j)" == *"display-popup"* ]]
}

@test "a changed setting rebinds on the next shell" {
    # Story C: an overnight change must take effect without a reload.
    load_dev
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/bin/lazygit"; chmod +x "$BATS_TEST_TMPDIR/bin/lazygit"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" zsh -c 'source "$1"' _ "$DEV_ZSH" </dev/null
    [[ "$(prefix_key g)" == *"lazygit"* ]]
}

@test "a key the user bound is left alone, and the conflict is reported" {
    # US-34.2
    tmux bind-key a display-message mine
    load_dev
    [[ "$(prefix_key a)" == *"display-message mine"* ]]
    [[ "$output" == *"prefix a"*"display-message mine"* ]]
}

@test "a user's repeatable binding is recognised as theirs" {
    # bind-key -r shifts list-keys' columns; matched by column, it looked free.
    tmux bind-key -r a display-message mine
    load_dev
    [[ "$(tmux list-keys -T prefix | grep -- '-T prefix *a ')" == *"display-message mine"* ]]
}

@test "a key bound by an older dev is upgraded" {
    # US-34.3 / review H1: 2.3.x bindings carry no marker but have a shape.
    tmux bind-key a run-shell "$LEGACY_A"
    load_dev
    [[ "$(prefix_key a)" == *"__agent"* ]]
}

@test "a configured key is used instead of the default" {
    # US-34.4
    export DEV_KEY_AGENT=V
    load_dev
    [[ "$(prefix_key V)" == *"__agent"* ]]
    [ -z "$(prefix_key a)" ]
}

@test "moving a key releases the old one dev had bound" {
    load_dev
    [[ "$(prefix_key a)" == *"__agent"* ]]
    export DEV_KEY_AGENT=V
    load_dev
    [ -z "$(prefix_key a)" ]
    [[ "$(prefix_key V)" == *"__agent"* ]]
}

@test "two actions on one key is a configuration error" {
    # US-34.5
    export DEV_KEY_AGENT=j
    load_dev
    [[ "$output" == *"prefix j"* ]]
    [ "$(tmux list-keys -T prefix | awk '$4 == "j"' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "once the user frees a key, dev reload takes it" {
    # US-34.6
    tmux bind-key a display-message mine
    load_dev
    tmux unbind-key -T prefix a
    dev_cmd reload
    [[ "$(prefix_key a)" == *"__agent"* ]]
}

@test "dev help lists each key and says which are not bound" {
    # US-34.7
    tmux bind-key a display-message mine
    load_dev
    dev_cmd help
    [[ "$output" == *"Prefix a"*"not bound"* ]]
    [[ "$output" == *"Prefix j"*"Terminal"* ]]
}

@test "a key setting that is not a key is refused" {
    dev_cmd config set key_agent "ab"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a tmux key"* ]]
}

@test "a user's own popup binding with dev's flags is never taken for dev's" {
    # The user's cheatsheet and worktree-manager keys use the same
    # display-popup flags as dev's popups. Only dev's own text marks a
    # binding as dev's, so moving a dev key never unbinds them.
    tmux bind-key h run-shell 'tmux display-popup -w 90% -h 90% -b single -E "less -R ~/cheatsheet.md"'
    tmux bind-key T run-shell 'tmux display-popup -w 90% -h 90% -b single -E "my-manager.sh"'
    export DEV_KEY_AGENT=V
    load_dev
    [[ "$(prefix_key h)" == *"cheatsheet.md"* ]]
    [[ "$(prefix_key T)" == *"my-manager.sh"* ]]
}
