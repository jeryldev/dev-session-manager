#!/usr/bin/env bats
# `dev agent watch` (plan Phase 4c, US-32): status, compared over time.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    FIXTURES="$PROJECT_ROOT/tests/fixtures/agent-screens"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS DEV_WATCH_CMD
    REPO="$(make_repo)"
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$REPO"
    OUT="$BATS_TEST_TMPDIR/watch.out"
}

teardown() {
    teardown_tmux
}

# The captures end in blank lines; print only up to the last real one.
show() {
    printf "awk 'NF { last = NR } { line[NR] = \$0 } END { for (i = 1; i <= last; i++) print line[i] }' '%s'; exec sleep 600" "$FIXTURES/$1"
}

start_agent_showing() {
    DEV_AGENT_LAUNCH_CMD="$(show "$1")" zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev agent start 2' _ "$REPO" "$DEV_ZSH" </dev/null >/dev/null
    AGENT="$(tmux list-windows -a -F '#{session_name}|#{@dev_popup_kind}' | awk -F'|' '$2 == "ai" {print $1}')"
}

# The agent's screen changes as a real one would.
switch_to() {
    tmux respawn-pane -k -t "=${AGENT}:" "$(show "$1")"
}

# Runs the watch in the background for a bounded time; output to $OUT.
# Returns once the watch has taken its first look (its opening heartbeat), so
# a screen changed afterwards is a change it sees, however loaded the machine.
watch_for() {
    zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev agent watch "$@"' _ "$REPO" "$DEV_ZSH" --interval 1 "$@" </dev/null >"$OUT" 2>&1 &
    WATCH=$!
    local i
    for i in $(seq 1 100); do
        grep -q 'heartbeat' "$OUT" 2>/dev/null && return 0
        sleep 0.2
    done
}

finish() { wait "$WATCH"; }

@test "a change of state is one event, not one per poll" {
    # US-32.2/32.12
    # Generous time: under a full suite's load a 1s poll can slip.
    start_agent_showing claude-2.1.286-working.txt
    watch_for --for 8
    sleep 2
    switch_to claude-2.1.286-idle.txt
    finish
    [ "$(grep -c 'working → idle' "$OUT")" -eq 1 ]
    # Every change line, not just the expected one: a watch that emits on
    # each poll repeats "idle → idle", which the line above never sees.
    [ "$(grep -c ' → ' "$OUT")" -eq 1 ]
}

@test "an agent waiting for an answer is reported with its question" {
    # US-32.1
    start_agent_showing claude-2.1.286-working.txt
    watch_for --for 8
    sleep 1.5
    switch_to claude-2.1.286-waiting-trust.txt
    finish
    grep -q 'working → waiting.*trust' "$OUT"
}

@test "an agent that dies is reported dead, never idle" {
    # US-32.3
    start_agent_showing claude-2.1.286-idle.txt
    watch_for --for 8
    sleep 1.5
    tmux kill-session -t "=${AGENT}"
    finish
    grep -q 'idle → dead' "$OUT"
}

@test "a screen it cannot read is one unknown event" {
    # US-32.5
    start_agent_showing claude-2.1.286-idle.txt
    watch_for --for 8
    sleep 1.5
    switch_to unknown-screen.txt
    finish
    [ "$(grep -c 'idle → unknown' "$OUT")" -eq 1 ]
}

@test "crossing the context threshold is one event" {
    # US-32.4
    start_agent_showing claude-2.1.286-idle.txt
    watch_for --for 8 --ctx 5
    sleep 1.5
    switch_to claude-2.1.286-idle-after-reply.txt
    finish
    [ "$(grep -c 'context 7%' "$OUT")" -eq 1 ]
}

@test "with nothing changing, a heartbeat still lists every workspace" {
    # US-32.6: silence is never the signal.
    start_agent_showing claude-2.1.286-idle.txt
    watch_for --for 8 --every 2
    finish
    grep -q 'heartbeat.*1 myrepo none.*2 myrepo-feat idle' "$OUT"
}

@test "--json prints one parseable object per line with stable keys" {
    # US-32.7
    start_agent_showing claude-2.1.286-working.txt
    watch_for --for 8 --every 2 --json
    sleep 1.5
    switch_to claude-2.1.286-idle.txt
    finish
    python3 - "$OUT" <<'PY'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
change = [e for e in events if e["event"] == "change"]
assert change and {"ts", "event", "ws", "from", "to", "detail"} <= set(change[0]), change
assert change[0]["from"] == "working" and change[0]["to"] == "idle", change
assert events[-1]["event"] == "stopped", events[-1]
PY
}

@test "the watch hook's output becomes events, and its failure is one too" {
    # US-32.8
    start_agent_showing claude-2.1.286-idle.txt
    export DEV_WATCH_CMD="echo PR 12 is green"
    watch_for --for 3 --every 1
    finish
    grep -q 'repo: PR 12 is green' "$OUT"
    export DEV_WATCH_CMD="exit 3"
    watch_for --for 3 --every 1
    finish
    grep -q 'watch_cmd failed (exit 3)' "$OUT"
}

@test "--notify marks the tab that needs attention" {
    # US-32.9
    start_agent_showing claude-2.1.286-working.txt
    watch_for --for 8 --notify
    sleep 1.5
    switch_to claude-2.1.286-waiting-trust.txt
    finish
    [ "$(tmux show-options -w -t '=dev-myrepo-grid:2' -qv @dev_attention)" = "waiting" ]
}

@test "the watch always says when it stops, and why" {
    # US-32.10
    start_agent_showing claude-2.1.286-idle.txt
    watch_for --for 2
    finish
    grep -q 'watch stopped: --for elapsed' "$OUT"
    watch_for
    sleep 1.5
    kill -TERM "$WATCH"
    wait "$WATCH" || true
    grep -q 'watch stopped: terminated' "$OUT"
}

@test "watching changes nothing it watches" {
    # US-32.11
    start_agent_showing claude-2.1.286-idle.txt
    local before; before="$(tmux list-sessions -F '#{session_name}' | sort)"
    watch_for --for 2
    finish
    [ "$(tmux list-sessions -F '#{session_name}' | sort)" = "$before" ]
}

@test "a tab added during the watch is not a none → none change" {
    start_agent_showing claude-2.1.286-idle.txt
    watch_for --for 8
    sleep 1.5
    zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid add later' _ "$REPO" "$DEV_ZSH" </dev/null >/dev/null
    finish
    ! grep -q 'none → none' "$OUT"
}

@test "a watch leaves no traps behind in the shell that ran it" {
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev agent watch --for 1 --interval 1 >/dev/null; trap' _ "$REPO" "$DEV_ZSH" </dev/null
    [[ "$output" != *INT* && "$output" != *TERM* ]]
}
