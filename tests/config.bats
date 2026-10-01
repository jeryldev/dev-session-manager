#!/usr/bin/env bats
# `dev config` (plan Phase 2b, US-10, US-11): one settings file that a sourced
# and an executed (Homebrew) install read the same way.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
    unset DEV_AI_CMD DEV_AI_ARGS DEV_SSH_KEY DEV_HOME_DIR DEV_WINDOWS DEV_WORKTREE_CREATE_CMD DEV_AGENT_LAUNCH_CMD
    CONFIG="$XDG_CONFIG_HOME/dev-session-manager/config"
}

teardown() {
    teardown_tmux
}

# Values travel as arguments, never spliced into the script.
dev_cmd() {
    run zsh -c 'source "$1" 2>/dev/null; shift; dev "$@"' _ "$DEV_ZSH" "$@" </dev/null
}

executed_dev() {
    run zsh "$DEV_ZSH" "$@" </dev/null
}

@test "dev config set creates the file, and get reads it back" {
    # US-10.2
    dev_cmd config set ai_cmd codex
    [ "$status" -eq 0 ]
    [ -f "$CONFIG" ]
    dev_cmd config get ai_cmd
    [ "$output" = "codex" ]
}

@test "setting a key twice keeps one line" {
    # US-10.3
    dev_cmd config set ai_cmd codex
    dev_cmd config set ai_cmd aider
    [ "$(grep -c '^ai_cmd' "$CONFIG")" -eq 1 ]
    dev_cmd config get ai_cmd
    [ "$output" = "aider" ]
}

@test "get on a key with no value prints nothing and fails" {
    # US-10.4
    dev_cmd config get ssh_key
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "an unknown key is an error and the file is untouched" {
    # US-10.5
    dev_cmd config set ai_cmd codex
    local before; before="$(cat "$CONFIG")"
    dev_cmd config set nonsense 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"nonsense"* ]]
    [ "$(cat "$CONFIG")" = "$before" ]
}

@test "ai_cmd with a space is refused" {
    # US-10.6: flags belong in ai_args.
    dev_cmd config set ai_cmd "claude --x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ai_args"* ]]
    [ ! -f "$CONFIG" ]
}

@test "a window list tmux cannot use is refused" {
    dev_cmd config set windows "a,b.c"
    [ "$status" -ne 0 ]
    [[ "$output" == *"b.c"* ]]
    [ ! -f "$CONFIG" ]
}

@test "a value with a newline is refused" {
    dev_cmd config set agent_launch_cmd $'a\nb'
    [ "$status" -ne 0 ]
    [[ "$output" == *"one line"* ]]
    [ ! -f "$CONFIG" ]
}

@test "unset removes the key" {
    dev_cmd config set ai_cmd codex
    dev_cmd config unset ai_cmd
    [ "$status" -eq 0 ]
    dev_cmd config get ai_cmd
    [ "$output" = "claude" ]
}

@test "a malformed config file is reported, and dev still works" {
    # US-10.7
    mkdir -p "$(dirname "$CONFIG")"
    printf 'this is not a setting\n# a comment\nai_cmd = codex\n' > "$CONFIG"
    dev_cmd version
    [ "$status" -eq 0 ]
    dev_cmd config list
    [ "$status" -eq 0 ]
    [[ "$output" == *"line 1"* ]]
    [[ "$output" != *"line 2"* ]]
    [[ "$output" =~ ai_cmd\ +codex\ +\(file\) ]]
}

@test "the same setting works the same sourced and executed" {
    # US-10.1 — the reason this phase exists.
    executed_dev config set windows code,logs
    [ "$status" -eq 0 ]
    create_dev_session sourced
    run tmux list-windows -t '=dev-sourced:' -F '#{window_name}'
    [ "$output" = $'code\nlogs' ]
    zsh "$DEV_ZSH" executed </dev/null &>/dev/null || true
    run tmux list-windows -t '=dev-executed:' -F '#{window_name}'
    [ "$output" = $'code\nlogs' ]
}

@test "a new ai_cmd reaches the agent key without logging in again" {
    # US-10.8: the popup reads what dev last published to the server.
    start_isolated_server dev-plain
    zsh -c "source '$DEV_ZSH'" </dev/null
    dev_cmd config set ai_cmd codex
    local pane; pane="$(tmux display-message -p -t '=dev-plain:' '#{pane_id}')"
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_command "$2"' _ "$DEV_ZSH" "$pane" </dev/null
    [[ "$output" == *"codex"* ]]
}

@test "config list shows each value and where it came from" {
    # US-11.1/11.2/11.3/11.5
    dev_cmd config set ai_cmd codex
    export DEV_HOME_DIR=/somewhere
    dev_cmd config list
    [[ "$output" =~ ai_cmd\ +codex\ +\(file\) ]]
    [[ "$output" =~ home_dir\ +/somewhere\ +\(env\ DEV_HOME_DIR\) ]]
    [[ "$output" =~ windows\ +editor,server,test,shell\ +\(default\) ]]
}

@test "the environment wins over the file" {
    # US-11.5: env > file > default.
    dev_cmd config set ai_cmd codex
    export DEV_AI_CMD=aider
    dev_cmd config get ai_cmd
    [ "$output" = "aider" ]
}

@test "config is a command, not a session called dev-config" {
    start_isolated_server keep
    dev_cmd config list
    ! tmux has-session -t '=dev-config' 2>/dev/null
}
