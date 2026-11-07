#!/usr/bin/env bats
# What a tab's conversation is about, read from the file Claude keeps it in:
# when it last changed, its title, the last thing typed and the first. Shown by
# `dev agent status`, the dashboard, `dev grid kill --fresh` and
# `dev agent history`, so the right conversation is the one resumed. Claude's
# file format is not a published interface, so anything dev cannot read in it
# leaves the summary empty, never an error.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    CONVERSATIONS="$PROJECT_ROOT/tests/fixtures/claude-conversations"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS CLAUDE_CONFIG_DIR
    export DEV_AGENT_LAUNCH_CMD="exec sleep 600"
    REPO="$(make_repo)"
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$REPO"
}

teardown() {
    teardown_tmux
}

sid() { tmux show-options -w -t "=dev-myrepo-grid:$1" -qv @dev_agent_sid; }

# A saved conversation, as Claude keeps it: one file per id, in a folder per
# workspace whose name dev never relies on. Last changed Nov 7, 2026, 09:34.
saved() {
    local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-any-folder"
    mkdir -p "$dir"
    cp "$CONVERSATIONS/$2" "$dir/$1.jsonl"
    touch -t "${3:-202611070934}" "$dir/$1.jsonl"
}

summary() {
    run zsh -c 'source "$1" 2>/dev/null; _dev_conversation_summary "$2"' _ "$DEV_ZSH" "$1" </dev/null
    output="${output//$'\x1f'/|}"
}

agent_cmd() {
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev agent "$@"' _ "$REPO" "$DEV_ZSH" "$@" </dev/null
}

# ─── the summary ───

@test "a summary is the last change, the last title, the last prompt and the first" {
    saved abc titled.jsonl
    summary abc
    [ "$status" -eq 0 ]
    [ "$output" = 'Nov 07 09:34|Fix the "login" bug|add a test for C:\tmp then push|first' ]
}

@test "a title given with /rename wins over Claude's own" {
    saved abc renamed.jsonl
    summary abc
    [ "$output" = "Nov 07 09:34|My name for it|keep going|" ]
}

@test "a conversation without a title still has its last prompt and its first" {
    saved abc untitled.jsonl
    summary abc
    [ "$output" = "Nov 07 09:34||delete the branches|hello" ]
}

@test "the first prompt is the first thing typed, not commands, notices or interruptions" {
    saved abc untitled-noisy.jsonl
    summary abc
    [ "$output" = 'Nov 07 09:34||ship it|fix the "login" page then push' ]
}

@test "a long first prompt is cut short" {
    local dir="$HOME/.claude/projects/-any-folder" long
    long="$(printf 'word %.0s' {1..60})"
    mkdir -p "$dir"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$long" > "$dir/abc.jsonl"
    summary abc
    local first="${output##*|}"
    [ "${#first}" -le 80 ]
    [[ "$first" == "word word"*"…" ]]
}

@test "a file dev cannot read is a summary with only its time, not an error" {
    saved abc junk.jsonl
    summary abc
    [ "$status" -eq 0 ]
    [ "$output" = "Nov 07 09:34|||" ]
}

@test "no saved conversation is no summary" {
    summary abc
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# Claude writes a conversation's title and last prompt again after each turn,
# so the newest are at the end; a file grows past a gigabyte, so dev reads the
# end only.
big_conversation() {
    local dir="$HOME/.claude/projects/-any-folder"
    mkdir -p "$dir"
    {
        printf '%s\n' '{"type":"user","message":{"role":"user","content":"start here"}}'
        printf '%s\n' '{"type":"ai-title","aiTitle":"Old title","sessionId":"s"}'
        printf '%s\n' '{"type":"last-prompt","lastPrompt":"old prompt","sessionId":"s"}'
        local filler; filler="$(head -c 1048576 /dev/zero | tr '\0' 'x')"
        local i; for (( i = 0; i < 10; i++ )); do printf '{"type":"assistant","text":"%s"}\n' "$filler"; done
        printf '%s\n' "$@"
    } > "$dir/abc.jsonl"
    touch -t 202611070934 "$dir/abc.jsonl"
}

@test "a large conversation's title and last prompt come from its end" {
    big_conversation '{"type":"ai-title","aiTitle":"New title","sessionId":"s"}' \
        '{"type":"last-prompt","lastPrompt":"new prompt","sessionId":"s"}'
    summary abc
    [ "$output" = "Nov 07 09:34|New title|new prompt|start here" ]
}

@test "a large conversation is not read whole for a title it no longer repeats" {
    big_conversation
    summary abc
    [ "$output" = "Nov 07 09:34|||start here" ]
}

@test "CLAUDE_CONFIG_DIR moves where conversations are found" {
    export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude-elsewhere"
    saved abc titled.jsonl
    summary abc
    [[ "$output" == *"Fix the"* ]]
}

# ─── dev agent status ───

@test "status shows when each tab's conversation changed and what it is" {
    saved "$(sid 2)" titled.jsonl
    agent_cmd status
    [ "$status" -eq 0 ]
    [[ "$output" == *"updated"*"conversation"* ]]
    [[ "$(printf '%s\n' "$output" | grep myrepo-feat)" == *"Nov 07 09:34"*'Fix the "login" bug'* ]]
}

@test "status shows the first prompt for a conversation without a title" {
    saved "$(sid 2)" untitled.jsonl
    agent_cmd status
    [[ "$(printf '%s\n' "$output" | grep myrepo-feat)" == *'"hello"'* ]]
}

@test "status --json carries the conversation, null where there is none" {
    saved "$(sid 2)" titled.jsonl
    agent_cmd status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
assert rows[0]["updated"] is None and rows[0]["title"] is None and rows[0]["last_prompt"] is None and rows[0]["first_prompt"] is None, rows[0]
assert rows[1]["updated"] == "Nov 07 09:34", rows[1]
assert rows[1]["title"] == "Fix the \"login\" bug", rows[1]
assert rows[1]["last_prompt"] == "add a test for C:\\tmp then push", rows[1]
assert rows[1]["first_prompt"] == "first", rows[1]'
}

# ─── the dashboard ───

@test "the dashboard shows a tab's conversation under its agent" {
    saved "$(sid 2)" titled.jsonl
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; repo="$(_dev_repo_root)"; _dev_dashboard_frame "$(_dev_grid_session "$repo")" 120 0' _ "$REPO" "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *'Fix the "login" bug · Nov 07 09:34'* ]]
}

@test "the dashboard names an untitled conversation by its first prompt" {
    saved "$(sid 2)" untitled.jsonl
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; repo="$(_dev_repo_root)"; _dev_dashboard_frame "$(_dev_grid_session "$repo")" 120 0' _ "$REPO" "$DEV_ZSH" </dev/null
    [[ "$output" == *'"hello" · Nov 07 09:34'* ]]
}

# ─── dev grid kill --fresh ───

@test "grid kill --fresh names each old conversation beside its resume" {
    local two; two="$(sid 2)"
    saved "$two" titled.jsonl
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid kill --fresh' _ "$REPO" "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude --resume ${two}"*'Fix the "login" bug'*"Nov 07 09:34"* ]]
}

# ─── dev agent history ───

@test "history lists a tab's conversations newest first, each with its resume" {
    local first; first="$(sid 2)"
    saved "$first" untitled.jsonl 202611051200
    agent_cmd reset 2
    local second; second="$(sid 2)"
    saved "$second" titled.jsonl
    agent_cmd reset 2
    local third; third="$(sid 2)"
    agent_cmd history 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"$third"*"$second"*"$first"* ]]
    [[ "$output" == *"current"*"$third"* ]]
    [[ "$output" == *'Fix the "login" bug'*"claude --resume ${second}"* ]]
    [[ "$output" == *"Nov 05 12:00"*'"hello"'*'last: "delete the branches"'*"claude --resume ${first}"* ]]
}

@test "history says which conversations were never saved" {
    agent_cmd history 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing saved yet"*"claude --resume $(sid 1)"* ]]
}

@test "history of a tab that is not there is an error" {
    agent_cmd history 7
    [ "$status" -ne 0 ]
}

@test "history needs a tab" {
    agent_cmd history
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: dev agent history"* ]]
}
