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

# A fixture with one line replaced, for screens no capture shows.
classify_edited() {
    local fixture="$1" line="$2" text="$3" fn="${4:-_dev_agent_screen_state}"
    awk -v n="$line" -v t="$text" 'NR == n { print t; next } { print }' "$FIXTURES/$fixture" > "$BATS_TEST_TMPDIR/edited.txt"
    run zsh -c 'source "$1" 2>/dev/null; "$3" < "$2"' _ "$DEV_ZSH" "$BATS_TEST_TMPDIR/edited.txt" "$fn" </dev/null
}



# Only the line just above the input box is the spinner's: a reply or a
# prompt in the transcript may be shaped like one ("⏺ Done…", "❯ Continue…").
@test "a transcript line shaped like the spinner does not make an idle agent working" {
    classify_edited claude-2.1.286-idle-after-reply.txt 9 "⏺ Done… all tests pass."
    [ "$output" = "idle" ]
    classify_edited claude-2.1.286-idle-after-reply.txt 7 "❯ Continue…"
    [ "$output" = "idle" ]
}

@test "context use is read from the status line, not the transcript" {
    classify_edited claude-2.1.286-idle-after-reply.txt 9 "⏺ the limit is ctx:95% here" _dev_agent_screen_ctx
    [ "$output" = "7" ]
}

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

@test "agy screens classify as working, idle, waiting, and report context percentage" {
    classify agy-working.txt
    [ "$output" = "working" ]
    classify agy-idle.txt
    [ "$output" = "idle" ]
    classify agy-waiting.txt
    [ "$output" = "waiting" ]
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_screen_ctx < "$2"' _ "$DEV_ZSH" "$FIXTURES/agy-idle.txt" </dev/null
    [ "$output" = "12" ]
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

# A fake claude first on PATH, so no test starts the real one.
fake_claude_on_path() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexec sleep 600\n' > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

tab2_agent_command() {
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_command "$2"' _ "$DEV_ZSH" "$pane" </dev/null
}

@test "flags given while the agent runs are kept for its next start, and it says so" {
    fake_claude_on_path
    grid_with_feat
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" start 2 -- --model opus
    [[ "$output" == *"already running"*"--model"*"next start"* ]]
    tab2_agent_command
    [[ "$output" == *"'--model' 'opus'"* ]]
}

@test "reset clears a tab's saved agent flags" {
    fake_claude_on_path
    grid_with_feat
    agent_cmd "$REPO" start 2 -- --model opus
    agent_cmd "$REPO" reset 2 --force
    [ "$status" -eq 0 ]
    tab2_agent_command
    [[ "$output" != *"--model"* ]]
}

@test "a launcher that exits at once is an error, not a running agent" {
    # US-24.5 / D12: never a quiet fallback to plain claude.
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="exit 3"
    agent_cmd "$REPO" start 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"exited as soon as it started (status 3)"* ]]
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
    [[ "$output" =~ 2\ +myrepo-feat\ +feat\ +clean\ +waiting\ +Quick\ safety\ check ]]
    agent_cmd "$REPO" status --json
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
assert rows[1]["agent"] == "waiting", rows[1]
assert rows[1]["detail"].startswith("Quick safety check"), rows[1]'
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
    # Checked raw: json.dumps of the parsed rows would escape an ESC away.
    [[ "$output" != *$'\033'* ]]
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
assert [r["tab"] for r in rows] == [1, 2], rows
assert set(rows[0]) == {"tab", "label", "path", "branch", "dirty", "agent", "detail", "ctx"}, rows[0]
assert rows[1]["agent"] == "idle" and rows[1]["ctx"] == 7, rows[1]'
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

# Like echoing_agent, but wraps a submitted line itself at 40 columns, with a
# two-space indent, as claude does: real line breaks that capture-pane -J
# cannot join.
wrapping_agent() {
    cat > "$BATS_TEST_TMPDIR/wrap-agent.sh" <<'SH'
stty -echo 2>/dev/null
printf '────\n❯ '
while IFS= read -r line; do
    printf '\n❯ %s\n' "$(printf '%s' "$line" | cut -c1-38)"
    rest="$(printf '%s' "$line" | cut -c39-)"
    while [ -n "$rest" ]; do
        printf '  %s\n' "$(printf '%s' "$rest" | cut -c1-38)"
        rest="$(printf '%s' "$rest" | cut -c39-)"
    done
    printf '────\n❯ '
done
SH
    export DEV_AGENT_LAUNCH_CMD="sh '$BATS_TEST_TMPDIR/wrap-agent.sh'"
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
    [[ "$file" == "$XDG_STATE_HOME/dev-session-manager/briefs/"* ]]
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
    [[ "$output" == *"Not confirmed"* ]]
}

@test "start --brief with a brief it cannot read fails before starting anything" {
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2 --brief "$BATS_TEST_TMPDIR/nope.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read the brief"* ]]
    [ -z "$(agent_sessions)" ]
}

@test "start --brief reports a brief that was not delivered" {
    grid_with_feat
    swallowing_agent
    printf 'x\n' > "$BATS_TEST_TMPDIR/b.md"
    agent_cmd "$REPO" start 2 --brief "$BATS_TEST_TMPDIR/b.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not confirmed"* ]]
    # The agent started; only the brief failed, so it is left running.
    [ -n "$(agent_sessions)" ]
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

@test "the agent popup keeps a failed launch's error on screen" {
    # A popup closes when its command ends; the error must not flash and vanish.
    grid_with_feat
    local pane; pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    tmux new-session -d -s popup -e "DEV_AGENT_LAUNCH_CMD=echo cannot authenticate; exit 3" "zsh '$DEV_ZSH' __agent '$pane'"
    local i screen=""
    for i in $(seq 1 50); do
        screen="$(tmux capture-pane -p -t '=popup:' 2>/dev/null)"
        [[ "$screen" == *"Press Enter to close"* ]] && break
        sleep 0.2
    done
    [[ "$screen" == *"cannot authenticate"* ]]
    [[ "$screen" == *"the agent exited with status 3. Press Enter to close."* ]]
    [ "$(tmux show-options -t '=popup:' -qv @dev_agent_exit)" = 3 ]
    # Still there a moment later, and gone once Enter is pressed: it waits.
    sleep 1
    tmux has-session -t '=popup'
    tmux send-keys -t '=popup:' Enter
    for i in $(seq 1 50); do
        tmux has-session -t '=popup' 2>/dev/null || return 0
        sleep 0.2
    done
    return 1
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
    [[ "$output" == *"Not confirmed"* ]]
}

@test "start --brief on a running agent delivers the brief to it" {
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2
    printf 'the brief\n' > "$BATS_TEST_TMPDIR/brief.md"
    agent_cmd "$REPO" start 2 --brief "$BATS_TEST_TMPDIR/brief.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    [[ "$output" == *"Delivered to tab 2"* ]]
    [ "$(agent_sessions | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a short multi-line message goes to a file too" {
    # A newline typed into the agent's input would submit the first line alone.
    grid_with_feat
    echoing_agent
    agent_cmd "$REPO" start 2
    agent_cmd "$REPO" send 2 "$(printf 'first line\nsecond line')"
    [ "$status" -eq 0 ]
    local session; session="$(agent_sessions | cut -d'|' -f1)"
    local typed; typed="$(tmux capture-pane -p -J -t "=${session}:" | grep -m1 '^❯ Read')"
    [[ "$typed" == "❯ Read and follow the instructions in "* ]]
    local file; file="${typed#*instructions in }"
    [ "$(cat "$file")" = "$(printf 'first line\nsecond line')" ]
}

@test "status --json escapes quotes and backslashes" {
    # They ride in a waiting agent's question, and a quote in the path.
    local repo; repo="$(make_repo)"
    local odd="$CODE/we\"ird/myrepo-a"
    mkdir -p "${odd%/*}"
    git -C "$repo" worktree add -q -b a "$odd"
    run_grid "$repo"
    export DEV_AGENT_LAUNCH_CMD="printf 'Allow \"C:\\\\tmp\" now?\\nEnter to confirm\\n'; exec sleep 600"
    agent_cmd "$repo" start 2
    agent_cmd "$repo" status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
assert rows[1]["path"] == sys.argv[1], (rows[1]["path"], sys.argv[1])
assert rows[1]["detail"] == "Allow \"C:\\tmp\" now?", rows[1]["detail"]' "$odd"
}

@test "the JSON encoder escapes tabs and drops other control characters" {
    # Not through a screen: tmux versions differ in how a tab is captured.
    run zsh -c 'source "$1" 2>/dev/null; _dev_json_str "$(printf "a\tb\001c\\\\d\"e")"' _ "$DEV_ZSH" </dev/null
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c '
import json, sys
assert json.loads(sys.stdin.read()) == "a\tbc\\d\"e"'
}

@test "a .dev-grid label keeps its backslashes" {
    local repo; repo="$(make_repo)"
    git -C "$repo" worktree add -q -b a "$CODE/myrepo-a"
    printf '%s\t%s\n' "$CODE/myrepo-a" 'api\now' > "$repo/.dev-grid"
    run_grid "$repo"
    agent_cmd "$repo" status --json
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
assert [r["label"] for r in rows] == ["api\\now"], rows'
}

# ─── dev grid close with a busy agent ───

grid_close() {
    local dir="$1"; shift
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev grid close "$@"' _ "$dir" "$DEV_ZSH" "$@" </dev/null
}

# Tab 2's agent started on a captured screen, once status reads it as $2: a
# fresh pane is blank for a moment, and blank reads as unknown, not busy.
tab2_agent_showing() {
    fake_agent_showing "$1"
    agent_cmd "$REPO" start 2
    wait_tab2_state "$2"
}

wait_tab2_state() {
    local i
    for i in $(seq 1 100); do
        agent_cmd "$REPO" status
        [[ "$output" =~ 2\ +myrepo-feat\ +feat\ +clean\ +$1 ]] && return 0
        sleep 0.2
    done
    return 1
}

@test "close refuses a tab whose agent is working, off a terminal" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-working.txt working
    grid_close "$REPO" 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent is working"*"--force"* ]]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
    [ -n "$(agent_sessions)" ]
}

@test "close refuses a tab whose agent is waiting for an answer" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-waiting-trust.txt waiting
    grid_close "$REPO" 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"agent is waiting"* ]]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

# Only Claude's screen is read: another tool's agent, or one still drawing,
# reads as unknown, and may be mid-turn.
@test "close refuses a tab whose agent's state it cannot read" {
    grid_with_feat
    tab2_agent_showing unknown-screen.txt unknown
    grid_close "$REPO" 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot tell whether it is busy"*"--force"* ]]
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
}

@test "close --force closes a busy agent's tab and stops the agent" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-working.txt working
    grid_close "$REPO" 2 --force
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
    [ -z "$(agent_sessions)" ]
}

@test "close does not stop for an idle agent" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-idle.txt idle
    grid_close "$REPO" 2
    [ "$status" -eq 0 ]
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
    [ -z "$(agent_sessions)" ]
}

answer_close() {
    local answer="$1" log="$BATS_TEST_TMPDIR/close.log" keys="$BATS_TEST_TMPDIR/close.keys" i
    rm -f "$log" "$keys"
    mkfifo "$keys"
    python3 "$PROJECT_ROOT/tests/pty_client.py" "$keys" "$log" 120 40 -- \
        zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid close 2' _ "$REPO" "$DEV_ZSH" >/dev/null 2>&1 3>&- &
    local client=$!
    for i in $(seq 1 150); do grep -aq 'Type y to close' "$log" 2>/dev/null && break; sleep 0.2; done
    grep -aq 'agent is working' "$log"
    printf '%s\r' "$answer" > "$keys"
    for i in $(seq 1 150); do kill -0 "$client" 2>/dev/null || break; sleep 0.2; done
    kill "$client" 2>/dev/null || true
}

@test "on a terminal, close of a busy agent's tab needs a y" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-working.txt working
    answer_close n
    grep -aq 'Kept\.' "$BATS_TEST_TMPDIR/close.log"
    [ "$(windows dev-myrepo-grid)" = $'1 myrepo\n2 myrepo-feat' ]
    answer_close y
    [ "$(windows dev-myrepo-grid)" = "1 myrepo" ]
}

# ─── dev grid kill with a busy agent ───

grid_kill() {
    local dir="$1"; shift
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; shift 2; dev grid kill "$@"' _ "$dir" "$DEV_ZSH" "$@" </dev/null
}

@test "grid kill refuses while an agent is busy, off a terminal" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-working.txt working
    grid_kill "$REPO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"tab 2"*"working"*"--force"* ]]
    tmux has-session -t '=dev-myrepo-grid'
    [ -n "$(agent_sessions)" ]
}

@test "grid kill --force kills the grid and its busy agent" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-working.txt working
    grid_kill "$REPO" --force
    [ "$status" -eq 0 ]
    ! tmux has-session -t '=dev-myrepo-grid' 2>/dev/null
    [ -z "$(agent_sessions)" ]
}

@test "grid kill does not stop for an idle agent" {
    grid_with_feat
    tab2_agent_showing claude-2.1.286-idle.txt idle
    grid_kill "$REPO"
    [ "$status" -eq 0 ]
    ! tmux has-session -t '=dev-myrepo-grid' 2>/dev/null
}

# ─── typing into an agent that is asking something ───

# Shows claude's trust dialog and records whatever is typed into it: a brief
# typed there would answer the dialog.
dialog_agent() {
    cat > "$BATS_TEST_TMPDIR/dialog-agent.sh" <<SH
stty -echo 2>/dev/null
awk 'NF { last = NR } { line[NR] = \$0 } END { for (i = 1; i <= last; i++) print line[i] }' '$FIXTURES/claude-2.1.286-waiting-trust.txt'
exec cat > '$BATS_TEST_TMPDIR/typed'
SH
    export DEV_AGENT_LAUNCH_CMD="sh '$BATS_TEST_TMPDIR/dialog-agent.sh'"
}

@test "send refuses an agent that is waiting for an answer, and types nothing" {
    grid_with_feat
    dialog_agent
    agent_cmd "$REPO" start 2
    wait_tab2_state waiting
    agent_cmd "$REPO" send 2 "2 tests still fail"
    [ "$status" -ne 0 ]
    [[ "$output" == *"waiting for an answer"*"--force"* ]]
    sleep 0.5
    [ ! -s "$BATS_TEST_TMPDIR/typed" ]
}

@test "send --force types into a waiting agent" {
    grid_with_feat
    dialog_agent
    agent_cmd "$REPO" start 2
    wait_tab2_state waiting
    agent_cmd "$REPO" send 2 1 --force --no-confirm
    [ "$status" -eq 0 ]
    local i
    for i in $(seq 1 50); do grep -qx 1 "$BATS_TEST_TMPDIR/typed" 2>/dev/null && break; sleep 0.1; done
    grep -qx 1 "$BATS_TEST_TMPDIR/typed"
}

@test "start --brief never answers the agent's opening question with the brief" {
    grid_with_feat
    dialog_agent
    printf 'fix the tests\n' > "$BATS_TEST_TMPDIR/brief.md"
    agent_cmd "$REPO" start 2 --brief "$BATS_TEST_TMPDIR/brief.md"
    [ "$status" -ne 0 ]
    [[ "$output" == *"waiting for an answer"* ]]
    sleep 0.5
    [ ! -s "$BATS_TEST_TMPDIR/typed" ]
}

# ─── the agent key after ai_cmd changes ───

# What prefix a runs in tab 2, with the ai_cmd given, minus showing the popup.
press_agent_key_in_tab2() {
    local script pane
    pane="$(tmux display-message -p -t '=dev-myrepo-grid:2' '#{pane_id}')"
    script="$(DEV_AI_CMD="$1" zsh -c 'source "$1" 2>/dev/null; local -a spec=("${(@f)$(_dev_popup_spec ai)}"); _dev_popup_script ai "${spec[1]}" "${spec[2]}" nodisplay' _ "$DEV_ZSH" </dev/null)"
    DEV_AI_CMD="$1" tmux run-shell -t "$pane" "$script"
}

@test "after ai_cmd changes, the agent key reaches the tab's running agent" {
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="exec sleep 600"
    agent_cmd "$REPO" start 2
    [ "$(agent_sessions | wc -l | tr -d ' ')" -eq 1 ]
    press_agent_key_in_tab2 codex
    [ "$(agent_sessions | wc -l | tr -d ' ')" -eq 1 ]
}

@test "an ai_cmd given as a path names a session tmux can reach" {
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="exec sleep 600"
    press_agent_key_in_tab2 "$HOME/.claude/local/claude"
    local name; name="$(agent_sessions | cut -d'|' -f1)"
    [[ "$name" == *-claude ]]
    tmux has-session -t "=$name"
    press_agent_key_in_tab2 "$HOME/.claude/local/claude"
    [ "$(agent_sessions | wc -l | tr -d ' ')" -eq 1 ]
}

# ─── a plain window in the grid has no agent ───

@test "opening the agent of a plain window starts nothing" {
    grid_with_feat
    export DEV_AGENT_LAUNCH_CMD="exec sleep 600"
    tmux new-window -d -t '=dev-myrepo-grid:3' -n scratch
    run zsh -c 'source "$1" 2>/dev/null; _dev_open_tab_agent dev-myrepo-grid 3 ""' _ "$DEV_ZSH" </dev/null
    [ "$status" -ne 0 ]
    sleep 0.5
    [ -z "$(tmux list-sessions -F '#{session_name}' | grep '^ai-')" ]
}

@test "a brief the agent wraps over several lines is still confirmed" {
    grid_with_feat
    wrapping_agent
    agent_cmd "$REPO" start 2
    mkdir -p "$BATS_TEST_TMPDIR/briefs/a-rather-long-directory-name"
    printf 'do x\n' > "$BATS_TEST_TMPDIR/briefs/a-rather-long-directory-name/2026-10-23-a-long-brief-name.md"
    agent_cmd "$REPO" send 2 --file "$BATS_TEST_TMPDIR/briefs/a-rather-long-directory-name/2026-10-23-a-long-brief-name.md" --timeout 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"Delivered"* ]]
}

@test "dev agent start --cmd agy sets the tab's tool to agy while other tabs stay on claude" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexec sleep 600\n' > "$BATS_TEST_TMPDIR/bin/agy"
    chmod +x "$BATS_TEST_TMPDIR/bin/agy"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    grid_with_feat
    agent_cmd "$REPO" start 2 --cmd agy
    [ "$status" -eq 0 ]
    local ws2; ws2="$(tmux show-options -w -t '=dev-myrepo-grid:2' -qv @dev_ws_id)"
    [[ "$(agent_sessions)" == "ai-${ws2}-agy|ai|${ws2}" ]]
    tab2_agent_command
    [[ "$output" == *"agy --mode auto"* ]]
    local pane1; pane1="$(tmux display-message -p -t '=dev-myrepo-grid:1' '#{pane_id}')"
    run zsh -c 'source "$1" 2>/dev/null; _dev_agent_command "$2"' _ "$DEV_ZSH" "$pane1" </dev/null
    [[ "$output" == *"claude --enable-auto-mode"* ]]
}
