#!/usr/bin/env bats
# `dev agent` (plan Phase 4b, US-24, US-25, US-26, US-30): starting, briefing
# and watching each workspace's agent — the same agent `prefix a` opens.

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    FIXTURES="$PROJECT_ROOT/tests/fixtures/agent-screens"
    isolate_tmux
    isolate_git
    unset DEV_AI_CMD DEV_AI_ARGS DEV_AGENT_LAUNCH_CMD
}

teardown() {
    teardown_tmux
}

agent_cmd() {
    local dir="$1"; shift
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev agent "$@"' _ "$dir" "$DEV_ZSH" "$@" </dev/null
}

grid_with_feat() {
    REPO="$(make_repo)"
    git -C "$REPO" worktree add -q -b feat "$CODE/myrepo-feat"
    run_grid "$REPO"
}

# An agent that shows a captured screen and stays up: the launcher hook (D18)
# is how tests stand in for claude without calling a model.
# The captures end in blank lines (they came from a 40-line pane); printed
# whole into a 24-line test pane, the screen would scroll out of view. Real
# claude redraws its visible screen, which is what status reads.
fake_agent_showing() {
    export DEV_AGENT_LAUNCH_CMD="awk 'NF { last = NR } { line[NR] = \$0 } END { for (i = 1; i <= last; i++) print line[i] }' '$FIXTURES/$1'; exec sleep 600"
}

agent_sessions() {
    tmux list-windows -a -F '#{session_name}|#{@dev_popup_kind}|#{@dev_ws_id}' | awk -F'|' '$2 == "ai"'
}

classify() {
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_screen_state < "$2"' _ "$DEV_ZSH" "$FIXTURES/$1" </dev/null
}

# ─── Reading an agent's screen (US-26.3/26.4; fixtures from claude 2.1.286) ───

@test "a working claude screen reads as working" {
    classify claude-2.1.286-working.txt
    [ "$output" = "working" ]
    classify claude-2.1.286-working-hooks.txt
    [ "$output" = "working" ]
}

@test "an idle claude screen reads as idle, before and after a reply" {
    classify claude-2.1.286-idle.txt
    [ "$output" = "idle" ]
    classify claude-2.1.286-idle-after-reply.txt
    [ "$output" = "idle" ]
}

@test "a claude question reads as waiting" {
    classify claude-2.1.286-waiting-trust.txt
    [ "$output" = "waiting" ]
}

@test "a screen it cannot read is unknown, never a guessed idle" {
    # US-26 / plan: an unknown screen must stay unknown.
    classify unknown-screen.txt
    [ "$output" = "unknown" ]
}

@test "the context percentage is read from claude's status line" {
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_screen_ctx < "$2"' _ "$DEV_ZSH" "$FIXTURES/claude-2.1.286-idle-after-reply.txt" </dev/null
    [ "$output" = "7" ]
}

# ─── dev agent start (US-24) ───

@test "dev agent start creates the agent prefix a would open" {
    # US-24.1: the same session — asserted by stamp and id, not by name.
    grid_with_feat
    fake_agent_showing claude-2.1.286-idle.txt
    agent_cmd "$REPO" start 2
    [ "$status" -eq 0 ]
    local ws; ws="$(tmux show-options -w -t '=dev-myrepo-grid:2' -v @dev_ws_id)"
    [ "$(agent_sessions | wc -l | tr -d ' ')" -eq 1 ]
    [[ "$(agent_sessions)" == *"|ai|${ws}" ]]
    [[ "$(agent_sessions)" == "ai-${ws}-claude|"* ]]
}

@test "starting twice reports it is already running" {
    # US-24.2
    grid_with_feat
    fake_agent_showing claude-2.1.286-idle.txt
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" start 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    [ "$(agent_sessions | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a workspace can be named by tab, label or path" {
    grid_with_feat
    fake_agent_showing claude-2.1.286-idle.txt
    agent_cmd "$REPO" start myrepo-feat
    [ "$status" -eq 0 ]
    agent_cmd "$REPO" start "$CODE/myrepo-feat"
    [[ "$output" == *"already running"* ]]
}

@test "a workspace not in the grid is an error listing the tabs" {
    # US-24.7
    grid_with_feat
    agent_cmd "$REPO" start nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 myrepo"*"2 myrepo-feat"* ]]
}

@test "extra agent flags reach the agent's command line" {
    # US-24.3 / R5 without a repo file: given by whoever runs dev. A fake
    # claude first on PATH, so the test never starts the real one.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh
exec sleep 600
' > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    grid_with_feat
    agent_cmd "$REPO" start 2 -- --model opus
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_command "$2"' _ "$DEV_ZSH" "$pane" </dev/null
    [[ "$output" == *"claude --enable-auto-mode '--model' 'opus' --resume"* ]]
}

@test "a launcher that exits at once is an error, not a running agent" {
    # US-24.5 / D12: never a quiet fallback to plain claude.
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="exit 3"
    agent_cmd "$REPO" start 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"exited"* ]]
    [ -z "$(agent_sessions)" ]
}

# ─── dev agent status (US-26, US-30) ───

@test "status shows each workspace's agent state" {
    # US-26.1 / US-30.1
    grid_with_feat
    fake_agent_showing claude-2.1.286-working.txt
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" status
    [ "$status" -eq 0 ]
    [[ "$output" =~ 1\ +myrepo\ +main\ +clean\ +none ]]
    [[ "$output" =~ 2\ +myrepo-feat\ +feat\ +clean\ +working ]]
}

@test "status reports a waiting agent with its question" {
    # US-26.3
    grid_with_feat
    fake_agent_showing claude-2.1.286-waiting-trust.txt
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" status
    [[ "$output" == *"waiting"* ]]
}

@test "an agent that died is dead, not idle and not none" {
    # US-26.6
    grid_with_feat
    fake_agent_showing claude-2.1.286-idle.txt
    agent_cmd "$REPO" start 2
    tmux kill-session -t "=$(agent_sessions | cut -d'|' -f1)"
    agent_cmd "$REPO" status
    [[ "$output" =~ 2\ +myrepo-feat\ +feat\ +clean\ +dead ]]
}

@test "status --json prints one object per workspace with stable keys" {
    # US-26.2
    grid_with_feat
    fake_agent_showing claude-2.1.286-idle-after-reply.txt
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
assert [r["tab"] for r in rows] == [1, 2], rows
assert set(rows[0]) == {"tab", "label", "path", "branch", "dirty", "agent", "detail", "ctx"}, rows[0]
assert rows[1]["agent"] == "idle" and rows[1]["ctx"] == 7, rows[1]
assert "\033" not in json.dumps(rows)
'
}

@test "status outside a grid is an error" {
    # US-26.7
    local repo; repo="$(make_repo)"
    agent_cmd "$repo" status
    [ "$status" -ne 0 ]
    [[ "$output" == *"No grid for"* ]]
}

@test "the coordinator's DEV_GRID picks the grid without a working directory" {
    # US-33.10: a coordinator's dev agent calls resolve its own grid.
    grid_with_feat
    run zsh -c 'cd / && source "$1" 2>/dev/null; DEV_GRID="$2" dev agent status' _ "$DEV_ZSH" "$REPO" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"myrepo-feat"* ]]
}

# ─── dev agent send (US-25, US-24.6) ───

# Behaves like claude's prompt: a submitted line moves into the transcript
# ("❯ text") and the input box ("❯ ") is empty again.
echoing_agent() {
    cat > "$BATS_TEST_TMPDIR/echo-agent.sh" <<'SH'
stty -echo 2>/dev/null
printf '────\n❯ '
while IFS= read -r line; do
    printf '\n❯ %s\n────\n❯ ' "$line"
done
SH
    export DEV_AGENT_LAUNCH_CMD="sh '$BATS_TEST_TMPDIR/echo-agent.sh'"
}

# Takes the keys and shows nothing: the brief that silently never arrived.
swallowing_agent() {
    export DEV_AGENT_LAUNCH_CMD="stty -echo; exec cat >/dev/null"
}

@test "a short message is typed, submitted and confirmed" {
    # US-25.3/25.4
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" send 2 "run the tests"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Delivered"* ]]
    local session; session="$(agent_sessions | cut -d'|' -f1)"
    [[ "$(tmux capture-pane -p -t "=${session}:")" == *"❯ run the tests"* ]]
}

@test "a message the agent never shows is not confirmed, and says so" {
    # US-25.7: the silent success this command exists to end.
    grid_with_feat
    swallowing_agent
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" send 2 --timeout 1 "run the tests"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not confirmed"* ]]
}

@test "a long message goes to a file and only a pointer is typed" {
    # US-25.1: long pastes reached the agent with their start cut off.
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2
    local long; long="$(printf 'step %s; ' $(seq 1 120))"
    agent_cmd "$REPO" send 2 "$long"
    [ "$status" -eq 0 ]
    local session; session="$(agent_sessions | cut -d'|' -f1)"
    local typed; typed="$(tmux capture-pane -p -J -t "=${session}:" | grep -m1 '^❯ Read')"
    local file; file="${typed#*instructions in }"
    [ "$(cat "$file")" = "$long" ]
}

@test "--file sends a pointer to that file and copies nothing" {
    # US-25.2
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2
    printf 'the brief\n' > "$BATS_TEST_TMPDIR/brief.md"
    agent_cmd "$REPO" send 2 --file "$BATS_TEST_TMPDIR/brief.md"
    [ "$status" -eq 0 ]
    local session; session="$(agent_sessions | cut -d'|' -f1)"
    [[ "$(tmux capture-pane -p -J -t "=${session}:")" == *"$BATS_TEST_TMPDIR/brief.md"* ]]
}

@test "sending to a workspace with no agent fails and starts nothing" {
    # US-25.6
    grid_with_feat
    agent_cmd "$REPO" send 2 "hello"
    [ "$status" -ne 0 ]
    [[ "$output" == *"dev agent start 2"* ]]
    [ -z "$(agent_sessions)" ]
}

@test "--no-confirm sends and says the delivery is unconfirmed" {
    # US-25.8
    grid_with_feat
    swallowing_agent
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" send 2 --no-confirm "hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unconfirmed"* ]]
}

@test "start --brief starts the agent and delivers the brief" {
    # US-24.6
    grid_with_feat
    echoing_agent
    printf 'the brief\n' > "$BATS_TEST_TMPDIR/brief.md"
    agent_cmd "$REPO" start 2 --brief "$BATS_TEST_TMPDIR/brief.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Delivered"* ]]
}

@test "text left in the input box is not taken for delivered" {
    # The other half of US-25.4: on screen is not the same as received.
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="printf '────\n❯ '; exec cat >/dev/null"
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" send 2 --timeout 1 "run the tests"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not confirmed"* ]]
}

# ─── Review fixes (2026-10-01) ───

@test "a second brief that never arrives is not confirmed by the first" {
    # Every --file pointer starts with the same words; the old receipt found
    # the first brief's line and called the second delivered.
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="stty -echo; printf '────\n❯ '; IFS= read -r l; printf '\n❯ %s\n────\n❯ ' \"\$l\"; exec cat >/dev/null"
    agent_cmd "$REPO" start 2
    printf 'one\n' > "$BATS_TEST_TMPDIR/one.md"; printf 'two\n' > "$BATS_TEST_TMPDIR/two.md"
    agent_cmd "$REPO" send 2 --file "$BATS_TEST_TMPDIR/one.md"
    [ "$status" -eq 0 ]
    agent_cmd "$REPO" send 2 --timeout 1 --file "$BATS_TEST_TMPDIR/two.md"
    [ "$status" -ne 0 ]
}

@test "start --brief with a brief it cannot read fails before starting anything" {
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2 --brief "$BATS_TEST_TMPDIR/nope.md"
    [ "$status" -ne 0 ]
    [ -z "$(agent_sessions)" ]
}

@test "start --brief reports a brief that was not delivered" {
    grid_with_feat
    swallowing_agent
    printf 'x\n' > "$BATS_TEST_TMPDIR/b.md"
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev agent start 2 --brief "$3"' _ "$REPO" "$DEV_ZSH" "$BATS_TEST_TMPDIR/b.md" </dev/null
    [ "$status" -ne 0 ]
}

@test "send types into the agent's pane, even after the session was split" {
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2
    local session; session="$(agent_sessions | cut -d'|' -f1)"
    tmux split-window -t "=${session}:" 'exec sleep 600'
    agent_cmd "$REPO" send 2 "hello agent"
    [ "$status" -eq 0 ]
    [[ "$(tmux capture-pane -p -t "=${session}:.0")" == *"❯ hello agent"* ]]
}

@test "an agent whose launch fails leaves its error on screen and start reports it" {
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="echo cannot authenticate; exit 3"
    agent_cmd "$REPO" start 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"exited"* ]]
}

@test "a waiting question is reported without its indent" {
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_screen_question < "$2"' _ "$DEV_ZSH" "$FIXTURES/claude-2.1.286-waiting-trust.txt" </dev/null
    [[ "$output" == "Quick safety check"* ]]
}

@test "the same brief sent twice is confirmed only when it arrives again" {
    # Same pointer line both times: only a new occurrence on screen counts.
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="stty -echo; printf '────\n❯ '; IFS= read -r l; printf '\n❯ %s\n────\n❯ ' \"\$l\"; exec cat >/dev/null"
    agent_cmd "$REPO" start 2
    printf 'one\n' > "$BATS_TEST_TMPDIR/one.md"
    agent_cmd "$REPO" send 2 --file "$BATS_TEST_TMPDIR/one.md"
    [ "$status" -eq 0 ]
    agent_cmd "$REPO" send 2 --timeout 1 --file "$BATS_TEST_TMPDIR/one.md"
    [ "$status" -ne 0 ]
}
