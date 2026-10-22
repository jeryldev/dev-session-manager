#!/usr/bin/env bats
# Tests for dev.zsh

# A hung test must fail, not stall the suite. `dev <existing-name>` can block on
# `read` if stdin is ever a TTY, and a leaked tmux server holding bats' output
# descriptor open has the same effect — both have happened here, and both look
# identical from outside: a run that simply stops. Must be set at file scope;
# setting it in setup() is too late, the countdown has already started.
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
    isolate_tmux
}

# Load-bearing, not hygiene: a tmux server that survives a test inherits bats'
# output file descriptor and holds it open, so the run never exits.
teardown() {
    teardown_tmux
}

# Helper: run a dev.zsh function via zsh
run_zsh_func() {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; $*" </dev/null
}

# Helper: run dev command via zsh (simulates direct execution)
# stdin is closed on purpose, and it is load-bearing rather than tidiness.
#
# `dev <existing-name>` branches on `[[ ! -t 0 ]]`. Without this redirect the
# subshell inherits whatever stdin bats was launched with: a pipe under CI (so
# the guard fires and the test passes) but a TTY when a developer runs `bats
# tests/` from a terminal — where `dev` instead takes the interactive branch and
# blocks forever on `read -r choice`. The suite then hangs mid-run with no
# failure message. Closing stdin here makes every test mean the same thing in
# both places.
run_dev() {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; dev $*" </dev/null
}

# A PATH with only the tools dev needs, plus any named, so a test can take
# tmux, kb or lazygit away whatever this machine has installed.
path_with() {
    local dir="$BATS_TEST_TMPDIR/base-path" tool found
    mkdir -p "$dir"
    for tool in zsh sh awk sed grep tr cksum cat mkdir mv rm sort od head tail cut wc env "$@"; do
        found="$(type -P "$tool")" && ln -sf "$found" "$dir/$tool"
    done
    printf '%s' "$dir"
}

# ─── Test isolation (guards the suite itself) ───

@test "the suite runs against an isolated tmux server, not the developer's" {
    # This is the regression guard for T2. Two isolation mechanisms have failed
    # here in ways that looked correct: -L (only redirected the tests' own tmux
    # calls) and a bare TMUX_TMPDIR (outranked by $TMUX when run inside tmux).
    # Assert the distinguishing observation directly.
    [ -z "$TMUX" ]
    [ -n "$TMUX_TMPDIR" ]
    start_isolated_server
    local real
    real="$(cd "$TMUX_TMPDIR" && pwd -P)"
    run tmux display-message -p '#{socket_path}'
    [ "$status" -eq 0 ]
    [[ "$output" == "$real"/* ]]
}

@test "the isolated server uses stock tmux config, even when dev.zsh starts it" {
    # Socket isolation is NOT config isolation. dev.zsh starts servers with bare
    # `tmux`, which reads ~/.tmux.conf at server start. A developer running
    # `base-index 1` therefore gets windows 1-7 and a green suite, while every
    # user on a stock config gets 0,2-7 and a dead `prefix 1` (B8). The socket
    # guard passes throughout — it only ever proved the socket.
    #
    # No start_isolated_server here on purpose: dev.zsh must start the server,
    # exactly as it does on a machine with none running.
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; tmux new-session -d -s cfgprobe; tmux show-option -gv base-index"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "the isolation guard does not kill a server it did not start" {
    # The guard exists for the case where isolation silently failed and tmux is
    # resolving to the developer's live server. Killing that server on the way
    # to reporting the failure costs every session the developer had open, which
    # is a worse outcome than the bug being guarded against.
    # Under /tmp: a socket path is capped at 104 bytes on macOS, and the
    # bats temp path, with its test number, comes close on its own.
    local decoy; decoy="$(mktemp -d /tmp/dev-decoy.XXXXXX)"
    TMUX_TMPDIR="$decoy" tmux -f /dev/null new-session -d -s decoy-session
    local decoy_sock
    decoy_sock="$(TMUX_TMPDIR="$decoy" tmux display-message -p '#{socket_path}')"

    # Sabotage isolation so that every tmux call reaches the decoy whatever
    # the environment says: a tmux on PATH pinned to the decoy's socket. (An
    # earlier version pointed $TMUX at it, but isolate_tmux unsets $TMUX first,
    # so it sabotaged nothing; it passed on macOS only because a long temp path
    # broke the probe's socket.)
    local real; real="$(command -v tmux)"
    mkdir -p "$BATS_TEST_TMPDIR/pinned"
    printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$real" "$decoy_sock" > "$BATS_TEST_TMPDIR/pinned/tmux"
    chmod +x "$BATS_TEST_TMPDIR/pinned/tmux"
    run env PATH="$BATS_TEST_TMPDIR/pinned:$PATH" \
            BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/sabotage" \
            bash -c "mkdir -p \"\$BATS_TEST_TMPDIR\"; BATS_TEST_FILENAME='$BATS_TEST_FILENAME'; source '$PROJECT_ROOT/tests/test_helper.bash'; isolate_tmux"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING TO RUN"* ]]

    # The decoy must still be standing.
    run env TMUX_TMPDIR="$decoy" tmux has-session -t decoy-session
    [ "$status" -eq 0 ]

    TMUX_TMPDIR="$decoy" tmux kill-server 2>/dev/null || true
    rm -rf "$decoy"
}

# ─── B8: advertised window numbers must exist (US-1) ───

# `prefix N` must reach window N on any config (US-37.7, formerly US-1): the
# code used to hardcode -t <session>:2..:7 while new-session put the first
# window at the server's base-index, so a stock config (base-index 0) gave
# 0,2,3,... and `prefix 1` reached nothing.
assert_default_windows() {
    run tmux list-windows -t "=$1:" -F '#{window_index}:#{window_name}'
    [ "$status" -eq 0 ]
    [ "$output" = $'1:editor\n2:server\n3:test\n4:shell' ]
}

@test "dev <name> makes four windows numbered from 1 on a stock config" {
    # US-37.1/37.7 (D23)
    create_dev_session layout
    [ "$(tmux show-option -gv base-index)" = "0" ]
    assert_default_windows dev-layout
}

@test "dev <name> makes four windows numbered from 1 under base-index 1" {
    start_isolated_server
    tmux set-option -g base-index 1
    create_dev_session layout
    assert_default_windows dev-layout
}

@test "dev <name> opens on the editor window" {
    create_dev_session startwin
    run tmux display-message -p -t '=dev-startwin:' '#{window_name}'
    [ "$output" = "editor" ]
}

@test "every window of a new session starts in home_dir" {
    export DEV_HOME_DIR="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$DEV_HOME_DIR"
    create_dev_session homed
    local want; want="$(cd "$DEV_HOME_DIR" && pwd -P)"
    run tmux list-panes -s -t '=dev-homed:' -F '#{pane_current_path}'
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
    local path; while IFS= read -r path; do
        [ "$(cd "$path" && pwd -P)" = "$want" ]
    done <<< "$output"
}

@test "DEV_WINDOWS replaces the windows, and the session opens on the first" {
    # US-37.2
    export DEV_WINDOWS="code,logs"
    create_dev_session custom
    run tmux list-windows -t '=dev-custom:' -F '#{window_index}:#{window_name}'
    [ "$output" = $'1:code\n2:logs' ]
    [ "$(tmux display-message -p -t '=dev-custom:' '#{window_name}')" = "code" ]
}

@test "an empty DEV_WINDOWS means the default four" {
    # US-37.4
    export DEV_WINDOWS=""
    create_dev_session empty
    assert_default_windows dev-empty
}

@test "a window name tmux cannot target is refused before anything is built" {
    # US-37.3
    export DEV_WINDOWS="code,my.logs"
    run_dev bad
    [ "$status" -ne 0 ]
    [[ "$output" == *"my.logs"* ]]
    ! tmux has-session -t '=dev-bad' 2>/dev/null
}

@test "more than nine windows is refused" {
    # US-37.5: prefix 1-9.
    export DEV_WINDOWS="a,b,c,d,e,f,g,h,i,j"
    run_dev many
    [ "$status" -ne 0 ]
    ! tmux has-session -t '=dev-many' 2>/dev/null
}

# ─── B1: popup target quoting ───

@test "the popup script quotes its attach target" {
    # tmux hands a display-popup -E payload to sh, which word-splits. An
    # unquoted $SESSION holding a space becomes two arguments and the attach
    # fails with 'too many arguments' — after new-session already created (and
    # leaked) the popup session. Asserted on the script itself: list-keys
    # re-escapes the binding, and slugging makes the space case unreachable
    # end to end, so neither would show this bug.
    local script; script="$(zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_popup_script term sh" </dev/null)"
    [[ "$script" == *'-E "tmux attach-session -t \"=$SESSION\""'* ]]
}

@test "the popup's attach command keeps a target with a space as one argument" {
    # What sh makes of the -E payload, once the outer script has expanded it.
    run sh -c 'SESSION="term-dev-x-1-my work"; payload="tmux attach-session -t \"$SESSION\""; eval "set -- $payload"; echo "$#|$4"'
    [ "$status" -eq 0 ]
    [ "$output" = "4|term-dev-x-1-my work" ]
}

@test "a popup opened twice from an oddly named window creates one session" {
    # US-3.1/3.3: tmux creates sessions named with ':' or '.' and then cannot
    # target them, so has-session misses and every press leaks another one.
    # run-shell expands the #{...} formats the way a key press does.
    start_isolated_server work
    tmux rename-window -t work 'my api:v1.2'
    local script; script="$(zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_popup_script term sh" </dev/null)"
    [ -n "$script" ]

    tmux run-shell -t work "$script" 2>/dev/null || true
    tmux run-shell -t work "$script" 2>/dev/null || true

    run tmux list-sessions -F '#{session_name}'
    local popups; popups="$(printf '%s\n' "$output" | grep '^term-')"
    [ "$(printf '%s\n' "$popups" | grep -c .)" -eq 1 ]
    [[ "$popups" =~ ^[a-zA-Z0-9_-]+$ ]]
}

@test "the popup script slugs the session name as well as the window name" {
    # US-3.5: tmux keeps '.' in a session name and then cannot target it, so a
    # popup opened from a session called 'v1.2' would leak like B1 did.
    local script; script="$(zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_popup_script term sh" </dev/null)"
    [[ "$script" == *'#{s/[^a-zA-Z0-9_-]/-/:session_name}'* ]]
}

# ─── B2: popup lifecycle (US-7, US-8, US-9) ───

# Open a popup the way its key does: run-shell expands the #{...} formats in
# the context of the session it targets. display-popup itself fails without a
# client, after the popup session already exists — which is all these need.
# Creates the session a popup key makes, as nodisplay does: there is no client
# here to show it. Inside another popup that is how older versions nested them.
open_popup() {
    local script; script="$(zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_popup_script $2 '$3' '' nodisplay" </dev/null)"
    tmux run-shell -t "$1" "$script" 2>/dev/null || true
}

session_id_of() { tmux display-message -p -t "$1" '#{session_id}'; }

session_names() { tmux list-sessions -F '#{session_name}' 2>/dev/null | sort; }

install_hooks() {
    zsh -c "source '$DEV_ZSH' 2>/dev/null" </dev/null
}

@test "a popup records its parent by session id, not by name" {
    start_isolated_server dev-proj
    open_popup dev-proj term "sleep 300"
    local popup; popup="$(session_names | grep '^term-')"
    [ -n "$popup" ]
    [ "$(tmux show-options -t "$popup" -v @dev_parent)" = "$(session_id_of dev-proj)" ]
}

@test "dev kill takes the session's popups with it and says how many" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    open_popup dev-proj term "sleep 300"
    open_popup dev-proj lg "sleep 300"
    run_dev kill proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 popups"* ]]
    [ "$(session_names)" = "keep" ]
}

@test "dev kill of a session without popups says only that it killed it" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    run_dev kill proj
    [ "$status" -eq 0 ]
    [ "$output" = "✓ Killed session: proj" ]
    [ "$(session_names)" = "keep" ]
}

@test "dev kill counts a single popup in the singular" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    open_popup dev-proj term "sleep 300"
    run_dev kill proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"(and 1 popup)"* ]]
}

@test "dev k is an alias for kill" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    run_dev k proj
    [ "$status" -eq 0 ]
    [ "$(session_names)" = "keep" ]
}

@test "dev kill reaps the popups of a session that was renamed" {
    # US-8.9: prefix $ renames the parent; a name stamp would strand them.
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    open_popup dev-proj term "sleep 300"
    tmux rename-session -t dev-proj dev-renamed
    run_dev kill renamed
    [ "$status" -eq 0 ]
    [ "$(session_names)" = "keep" ]
}

@test "dev kill reaps a popup whose name tmux cannot target" {
    # US-8.2: tmux keeps '.' in a name and then splits on it when targeting,
    # so only the session id reaches this one.
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    tmux new-session -d -s 'ai-v1.2-x' "sleep 300"
    local popup; popup="$(tmux list-sessions -F '#{session_id} #{session_name}' | awk '$2 == "ai-v1.2-x" {print $1}')"
    tmux set-option -t "$popup" @dev_parent "$(session_id_of dev-proj)"
    run tmux has-session -t 'ai-v1.2-x'
    [ "$status" -ne 0 ]
    run_dev kill proj
    [ "$status" -eq 0 ]
    [ "$(session_names)" = "keep" ]
}

@test "dev kill leaves other sessions' popups alone" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    tmux new-session -d -s dev-other
    open_popup dev-other term "sleep 300"
    run_dev kill proj
    [ "$(session_names | grep -c '^term-dev-other')" -eq 1 ]
}

@test "the popup reaper hook is installed once, however often dev is loaded" {
    # US-8.6: set-hook -ga would append one reaper per shell start.
    start_isolated_server
    install_hooks
    install_hooks
    [ "$(tmux show-hooks -g session-closed | grep -c 'dev_parent')" -eq 1 ]
}

@test "the popup reaper hook keeps the user's own session-closed hook" {
    # US-8.7
    start_isolated_server
    tmux set-hook -g session-closed 'display-message mine'
    install_hooks
    [[ "$(tmux show-hooks -g session-closed)" == *"display-message mine"* ]]
}

@test "killing a session with plain tmux reaps its popups, and theirs" {
    # US-8.4/8.8: the hook cascades — each reaped popup fires it again.
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    install_hooks
    open_popup dev-proj term "sleep 300"
    local popup; popup="$(session_names | grep '^term-')"
    open_popup "$popup" ai "sleep 300"
    [ "$(session_names | grep -c '^ai-')" -eq 1 ]
    tmux kill-session -t dev-proj
    local i; for i in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(session_names)" = "keep" ] && break
        sleep 0.2
    done
    [ "$(session_names)" = "keep" ]
}

@test "dev ls does not list popup sessions" {
    # US-7.1
    start_isolated_server dev-proj
    open_popup dev-proj term "sleep 300"
    run_dev ls
    [[ "$output" == *"proj"* ]]
    [[ "$output" != *"term-"* ]]
}

@test "dev ls --all lists popups under their parent, even after a rename" {
    # US-7.2/7.6
    start_isolated_server dev-proj
    open_popup dev-proj term "sleep 300"
    tmux rename-session -t dev-proj dev-renamed
    run_dev ls --all
    [ "$status" -eq 0 ]
    local after; after="${output#*renamed}"
    [[ "$after" == *"term-dev-proj"* ]]
    [[ "$output" != *"rphan"* ]]
}

@test "dev ls --all marks a popup whose parent is gone" {
    # US-7.3
    start_isolated_server keep
    tmux new-session -d -s term-stray "sleep 300"
    tmux set-option -t term-stray @dev_parent '$999'
    run_dev ls --all
    [[ "$output" == *"rphan"* ]]
    [[ "$output" == *"term-stray"* ]]
}

@test "dev clean is a command, not a session called dev-clean" {
    start_isolated_server keep
    run_dev clean
    [ "$status" -eq 0 ]
    ! tmux has-session -t dev-clean 2>/dev/null
}

@test "dev clean with nothing to do says so" {
    # US-9.1
    start_isolated_server dev-proj
    open_popup dev-proj term "sleep 300"
    run_dev clean
    [ "$status" -eq 0 ]
    [[ "$output" == *"No orphaned popups"* ]]
    [ "$(session_names | grep -c '^term-')" -eq 1 ]
}

@test "dev clean removes orphans and counts them" {
    # US-9.2/9.4/9.6
    start_isolated_server dev-proj
    open_popup dev-proj term "sleep 300"
    tmux new-session -d -s 'lg-gone-1-v1.2' "sleep 300"
    tmux new-session -d -s ai-gone "sleep 300"
    local id; for id in $(tmux list-sessions -F '#{session_id} #{session_name}' | awk '$2 ~ /gone/ {print $1}'); do
        tmux set-option -t "$id" @dev_parent '$999'
    done
    run_dev clean
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 orphaned popups"* ]]
    [ "$(session_names | grep -c gone)" -eq 0 ]
    [ "$(session_names | grep -c '^term-dev-proj')" -eq 1 ]
}

@test "dev clean --dry-run lists orphans and kills nothing" {
    # US-9.3
    start_isolated_server keep
    tmux new-session -d -s ai-gone "sleep 300"
    tmux set-option -t ai-gone @dev_parent '$999'
    run_dev clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ai-gone"* ]]
    tmux has-session -t ai-gone
}

@test "dev clean reports unstamped legacy popups and never kills them" {
    # US-9.5 / D19: only the name says they are ours, and a name is not proof.
    start_isolated_server keep
    tmux new-session -d -s ai-dev-old-1-editor-claude "sleep 300"
    local id; id="$(session_id_of '=ai-dev-old-1-editor-claude:')"
    run_dev clean
    [ "$status" -eq 0 ]
    [[ "$output" == *"ai-dev-old-1-editor-claude"* ]]
    [[ "$output" == *"kill-session -t '${id}'"* ]]
    tmux has-session -t ai-dev-old-1-editor-claude
}

# An orphan (its parent id is gone) with a popup of its own opened inside it.
orphan_with_child() {
    start_isolated_server keep
    tmux new-session -d -s ai-gone "sleep 300"
    tmux set-option -t ai-gone @dev_parent '$999'
    open_popup ai-gone term "sleep 300"
    [ "$(session_names | grep -c '^term-')" -eq 1 ]
}

@test "dev clean removes an orphan's own popups with it" {
    orphan_with_child
    run_dev clean
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed 2 orphaned popups"* ]]
    [ "$(session_names)" = "keep" ]
}

@test "dev clean --dry-run counts an orphan's own popups in its header" {
    orphan_with_child
    run_dev clean --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would remove 2 orphaned popups"* ]]
    [ "$(session_names | wc -l | tr -d ' ')" -eq 3 ]
}

# ─── B7: attaching from inside tmux (US-2) ───

# A tmux on PATH that records attach/switch-client instead of running them —
# both need a real terminal — and passes everything else to the real tmux.
fake_attaching_tmux() {
    local real; real="$(command -v tmux)"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/tmux" <<SH
#!/bin/sh
case "\$1" in
  attach|attach-session|switch-client) echo "\$*" >> "$BATS_TEST_TMPDIR/attach.log"; exit 0 ;;
esac
exec "$real" "\$@"
SH
    chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
}

@test "dev attach from inside tmux switches the client to the session" {
    start_isolated_server
    tmux new-session -d -s dev-other
    fake_attaching_tmux
    local sock; sock="$(tmux display-message -p '#{socket_path}')"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMUX="$sock,1,0" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev attach other" </dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/attach.log")" = "switch-client -t =dev-other" ]
}

@test "dev attach from outside tmux attaches" {
    start_isolated_server
    tmux new-session -d -s dev-other
    fake_attaching_tmux
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev attach dev-other" </dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/attach.log")" = "attach -t =dev-other" ]
}

@test "dev a is an alias for attach" {
    start_isolated_server
    tmux new-session -d -s dev-other
    fake_attaching_tmux
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev a other" </dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/attach.log")" = "attach -t =dev-other" ]
}

@test "dev <name> from inside tmux switches the client to the new session" {
    # README: inside tmux, dev <name> switches rather than nesting an attach.
    start_isolated_server
    fake_attaching_tmux
    local sock; sock="$(tmux display-message -p '#{socket_path}')"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMUX="$sock,1,0" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev fresh" </dev/null
    [ "$status" -eq 0 ]
    tmux has-session -t '=dev-fresh'
    [ "$(cat "$BATS_TEST_TMPDIR/attach.log")" = "switch-client -t =dev-fresh" ]
}

# Answers the "already exists" question on a real terminal, through the pty
# helper. The tmux on PATH is whatever the caller exported.
answer_attach_prompt() {
    local answer="$1" log="$BATS_TEST_TMPDIR/prompt.log" keys="$BATS_TEST_TMPDIR/prompt.keys" i
    mkfifo "$keys"
    python3 "$PROJECT_ROOT/tests/pty_client.py" "$keys" "$log" 120 40 -- \
        zsh -c 'source "$1" 2>/dev/null; dev proj' _ "$DEV_ZSH" >/dev/null 2>&1 3>&- &
    local client=$!
    for i in $(seq 1 50); do grep -aq 'Attach to it?' "$log" 2>/dev/null && break; sleep 0.2; done
    grep -aq "Session 'proj' already exists" "$log"
    printf '%s\r' "$answer" > "$keys"
    for i in $(seq 1 50); do kill -0 "$client" 2>/dev/null || break; sleep 0.2; done
    kill "$client" 2>/dev/null || true
    PROMPT_LOG="$log"
}

@test "on a terminal, answering n to the existing-session prompt cancels" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    answer_attach_prompt n
    grep -aq 'Operation cancelled' "$PROMPT_LOG"
    tmux has-session -t '=dev-proj'
}

@test "on a terminal, answering y to the existing-session prompt attaches" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    fake_attaching_tmux
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" answer_attach_prompt y
    [ "$(cat "$BATS_TEST_TMPDIR/attach.log")" = "attach -t =dev-proj" ]
    run grep -a 'Operation cancelled' "$PROMPT_LOG"
    [ "$status" -ne 0 ]
}

# ─── B6: colour only on a terminal (US-4) ───

ESC=$'\033['

# Run a command with its stdout on a pseudo-terminal, so [[ -t 1 ]] is true
# inside it. Not script(1): the BSD one needs a terminal on its own stdin,
# which bats never gives it, and its flags differ from util-linux's.
run_on_tty() {
    run python3 -c '
import os, subprocess, sys
master, slave = os.openpty()
proc = subprocess.Popen(["sh", "-c", sys.argv[1]], stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
os.close(slave)
out = b""
while True:
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
sys.stdout.buffer.write(out)
sys.exit(proc.wait())
' "$1"
}

@test "executed dev prints no colour codes into a pipe" {
    run sh -c "zsh '$DEV_ZSH' version | cat"
    [ "$status" -eq 0 ]
    [[ "$output" == *"v"* ]]
    [[ "$output" != *"$ESC"* ]]
}

@test "sourced dev prints no colour codes into a pipe" {
    # Sourced from .zshrc, a file-scope [[ -t 1 ]] is judged once, on a
    # terminal, and every later piped command still got colours.
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; dev version | cat" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"v"* ]]
    [[ "$output" != *"$ESC"* ]]
}

@test "dev prints colours on a terminal" {
    run_on_tty "zsh -c \"source '$DEV_ZSH' 2>/dev/null; dev version\""
    [[ "$output" == *"$ESC"* ]]
}

@test "sourcing dev leaves the shell's own colour variables alone" {
    run zsh -c "RED=mine; source '$DEV_ZSH' 2>/dev/null; dev version >/dev/null; print -r -- \"\$RED|\${+GREEN}\"" </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "mine|0" ]
}

# ─── _dev_has_command ───

@test "_dev_has_command detects existing command" {
    run_zsh_func '_dev_has_command ls'
    [ "$status" -eq 0 ]
}

@test "_dev_has_command fails for missing command" {
    run_zsh_func '_dev_has_command nonexistent_command_xyz'
    [ "$status" -ne 0 ]
}

# ─── _dev_normalize_session_name ───

@test "_dev_normalize_session_name adds prefix" {
    run_zsh_func '_dev_normalize_session_name myproject'
    [ "$output" = "dev-myproject" ]
}

@test "_dev_normalize_session_name is idempotent with prefix" {
    run_zsh_func '_dev_normalize_session_name dev-myproject'
    [ "$output" = "dev-myproject" ]
}

@test "_dev_normalize_session_name handles numeric names" {
    run_zsh_func '_dev_normalize_session_name 1'
    [ "$output" = "dev-1" ]
}

# ─── _dev_display_name ───

@test "_dev_display_name strips prefix" {
    run_zsh_func '_dev_display_name dev-myproject'
    [ "$output" = "myproject" ]
}

@test "_dev_display_name handles name without prefix" {
    run_zsh_func '_dev_display_name myproject'
    [ "$output" = "myproject" ]
}

# ─── _dev_validate_name ───

@test "_dev_validate_name accepts valid name" {
    run_zsh_func '_dev_validate_name myproject'
    [ "$status" -eq 0 ]
}

@test "_dev_validate_name accepts hyphens and underscores" {
    run_zsh_func '_dev_validate_name my-project_1'
    [ "$status" -eq 0 ]
}

@test "_dev_validate_name rejects empty name" {
    run_zsh_func '_dev_validate_name ""'
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be empty"* ]]
}

@test "_dev_validate_name rejects spaces, dots and slashes" {
    local name
    for name in "my project" "my.project" "my/project"; do
        run zsh -c 'source "$1" 2>/dev/null; _dev_validate_name "$2"' _ "$DEV_ZSH" "$name" </dev/null
        [ "$status" -ne 0 ]
        [[ "$output" == *"letters, numbers, hyphens, and underscores"* ]]
    done
}

# ─── _dev_center_text ───

@test "_dev_center_text centers text in given width" {
    run_zsh_func '_dev_center_text "hello" 11'
    [ "$output" = "   hello   " ]
}

@test "_dev_center_text handles exact width" {
    run_zsh_func '_dev_center_text "hello" 5'
    [ "$output" = "hello" ]
}

# ─── _dev_check_optional ───

@test "_dev_check_optional shows checkmark for installed command" {
    run_zsh_func '_dev_check_optional ls "test label" "install hint"'
    [[ "$output" == *"✓"* ]]
    [[ "$output" == *"test label"* ]]
}

@test "_dev_check_optional shows X for missing command" {
    run_zsh_func '_dev_check_optional nonexistent_xyz "test label" "brew install foo"'
    [[ "$output" == *"✗"* ]]
    [[ "$output" == *"brew install foo"* ]]
}

# ─── dev help ───

@test "dev help shows header box" {
    run_dev help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dev session manager"* ]]
}

@test "dev help shows the prerequisites and each optional tool" {
    run_dev help
    [[ "$output" == *"Prerequisites"* ]]
    [[ "$output" == *"Optional tools"* ]]
    [[ "$output" == *"claude"* ]]
    [[ "$output" == *"kb"* ]]
    [[ "$output" == *"lazygit"* ]]
}

@test "dev help shows commands section" {
    run_dev help
    [[ "$output" == *"Commands"* ]]
    [[ "$output" == *"dev <name>"* ]]
    [[ "$output" == *"dev attach"* ]]
    [[ "$output" == *"dev ls"* ]]
    [[ "$output" == *"dev kill"* ]]
    [[ "$output" == *"dev reload"* ]]
}

@test "dev help shows popup keybindings" {
    run_dev help
    [[ "$output" == *"Popup keybindings"* ]]
    [[ "$output" == *"Prefix a"* ]]
    [[ "$output" == *"Prefix k"* ]]
    [[ "$output" == *"Prefix g"* ]]
    [[ "$output" == *"Prefix j"* ]]
}

@test "dev help shows the windows actually in effect" {
    # US-37.6
    run_dev help
    [[ "$output" == *"1. editor"*"2. server"*"3. test"*"4. shell"* ]]
    export DEV_WINDOWS="code,logs"
    run_dev help
    [[ "$output" == *"1. code"*"2. logs"* ]]
    [[ "$output" != *"frontend"* ]]
}

@test "dev -h is alias for help" {
    run_dev -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dev session manager"* ]]
}

@test "dev --help is alias for help" {
    run_dev --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dev session manager"* ]]
}

@test "dev h is alias for help" {
    run_dev h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dev session manager"* ]]
}

# ─── dev version ───

@test "dev version shows version number" {
    local expected=$(grep -m1 '^DEV_VERSION=' "$DEV_ZSH" | cut -d'"' -f2)
    run_dev version
    [ "$status" -eq 0 ]
    [[ "$output" == *"$expected"* ]]
}

@test "dev version shows repository URL" {
    run_dev version
    [[ "$output" == *"github.com/jeryldev/dev-session-manager"* ]]
}

@test "dev -v is alias for version" {
    local expected=$(grep -m1 '^DEV_VERSION=' "$DEV_ZSH" | cut -d'"' -f2)
    run_dev -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"$expected"* ]]
}

@test "dev v is alias for version" {
    local expected=$(grep -m1 '^DEV_VERSION=' "$DEV_ZSH" | cut -d'"' -f2)
    run_dev v
    [ "$status" -eq 0 ]
    [[ "$output" == *"$expected"* ]]
}

@test "dev --version is alias for version" {
    local expected=$(grep -m1 '^DEV_VERSION=' "$DEV_ZSH" | cut -d'"' -f2)
    run_dev --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"$expected"* ]]
}

# ─── dev tmux ───

@test "dev tmux shows reference header" {
    run_dev tmux
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tmux commands reference"* ]]
}

@test "dev tmux shows all sections" {
    run_dev tmux
    [[ "$output" == *"Detach and exit"* ]]
    [[ "$output" == *"Window navigation"* ]]
    [[ "$output" == *"Window management"* ]]
    [[ "$output" == *"Pane splits"* ]]
    [[ "$output" == *"Pane navigation"* ]]
    [[ "$output" == *"Copy mode"* ]]
    [[ "$output" == *"Session management"* ]]
    [[ "$output" == *"Dev popups"* ]]
    [[ "$output" == *"Quick reference"* ]]
}

@test "dev tmux shows popup keybindings" {
    run_dev tmux
    [[ "$output" == *"AI assistant popup"* ]]
    [[ "$output" == *"Kanban board popup"* ]]
    [[ "$output" == *"Git UI popup"* ]]
    [[ "$output" == *"Terminal popup"* ]]
    [[ "$output" == *"Prefix N"*"New branch as a grid tab"* ]]
    [[ "$output" == *"Prefix X"*"Remove this tab's worktree"* ]]
    [[ "$output" == *"Prefix W"*"Close this tab, keep its worktree"* ]]
    [[ "$output" == *"Prefix S"*"coordinator agent"* ]]
    [[ "$output" == *"Prefix O"*"Dashboard"* ]]
}

@test "dev t is alias for tmux" {
    run_dev t
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tmux commands reference"* ]]
}

# ─── dev (empty) ───

@test "dev with no args outside a repo shows usage error" {
    # Inside a repo, bare dev opens its grid (D22, tests/grid.bats). The
    # suite's own directory is a repo, so this runs from one that is not.
    run zsh -c "cd '$HOME/code' && source '$DEV_ZSH' 2>/dev/null; dev" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"dev help"* ]]
    [[ "$output" == *"inside a git repo"* ]]
}

# ─── dev ls ───

@test "dev ls, attach, kill and clean require tmux" {
    local nopath; nopath="$(path_with)"
    local cmd
    for cmd in "ls" "attach proj" "kill proj" "clean"; do
        run env PATH="$nopath" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev $cmd" </dev/null
        [ "$status" -ne 0 ]
        [[ "$output" == *"tmux is not installed"* ]]
    done
}

@test "dev ls lists only dev sessions, without the dev- prefix" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    run_dev ls
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '^  proj:'
    [[ "$output" != *"dev-proj"* ]]
    [[ "$output" != *"keep"* ]]
}

@test "dev ls says when there are no dev sessions" {
    start_isolated_server keep
    run_dev ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"No dev sessions found"* ]]
}

@test "dev list is an alias for ls" {
    start_isolated_server keep
    tmux new-session -d -s dev-proj
    run_dev list
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '^  proj:'
}

# ─── dev attach (validation) ───

@test "dev attach without name shows usage" {
    run_dev attach
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: dev attach"* ]]
}

@test "dev attach with invalid name shows error" {
    run_dev 'attach "bad name"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, numbers, hyphens, and underscores"* ]]
}

# ─── dev kill (validation) ───

@test "dev kill without name shows usage" {
    run_dev kill
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: dev kill"* ]]
}

@test "dev kill with invalid name shows error" {
    run_dev 'kill "bad name"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, numbers, hyphens, and underscores"* ]]
}

@test "dev kill nonexistent session shows error" {
    if ! command -v tmux &>/dev/null; then
        skip "tmux not installed"
    fi
    run_dev kill nonexistent-test-session-xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

# ─── dev reload ───

@test "dev reload without tmux server shows warning" {
    run_dev reload
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active tmux server"* ]]
}

@test "dev reload with tmux server updates keybindings" {
    start_isolated_server
    run_dev reload
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reloading"* ]]
    [[ "$output" == *"updated"* ]]
}

@test "dev reload names the keys left unbound for a missing kb and lazygit" {
    start_isolated_server
    run env PATH="$(path_with tmux)" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev reload" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"kb is not installed, so prefix k is not bound"* ]]
    [[ "$output" == *"lazygit is not installed, so prefix g is not bound"* ]]
}

# ─── Session creation (integration, needs tmux) ───

@test "dev create validates session name" {
    run_dev '"bad name!"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, numbers, hyphens, and underscores"* ]]
}

# ─── _dev_check_tmux ───

@test "_dev_check_tmux succeeds when tmux is installed" {
    if ! command -v tmux &>/dev/null; then
        skip "tmux not installed"
    fi
    run_zsh_func '_dev_check_tmux'
    [ "$status" -eq 0 ]
}

# ─── Popup keybinding guards ───

@test "_dev_setup_popup_keybindings returns non-zero without tmux server" {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_setup_popup_keybindings"
    [ "$status" -ne 0 ]
}

# ─── _dev_session_not_found ───

@test "_dev_session_not_found shows error and tip" {
    run_zsh_func '_dev_session_not_found myproject'
    [[ "$output" == *"✗"* ]]
    [[ "$output" == *"myproject"* ]]
    [[ "$output" == *"dev ls"* ]]
}

# ─── _dev_attach_session ───

@test "_dev_attach_session is defined after sourcing" {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; type _dev_attach_session"
    [ "$status" -eq 0 ]
    [[ "$output" == *"function"* ]]
}

# ─── Configuration defaults ───

@test "DEV_SESSION_PREFIX defaults to dev-" {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; echo \$DEV_SESSION_PREFIX"
    [ "$output" = "dev-" ]
}

@test "ai_cmd defaults to claude" {
    run zsh -c "unset DEV_AI_CMD; source '$DEV_ZSH' 2>/dev/null; _dev_cfg ai_cmd"
    [ "$output" = "claude" ]
}

@test "DEV_AI_CMD overrides ai_cmd" {
    run zsh -c "DEV_AI_CMD=aider; source '$DEV_ZSH' 2>/dev/null; _dev_cfg ai_cmd"
    [ "$output" = "aider" ]
}

@test "home_dir defaults to ~/code" {
    run zsh -c "unset DEV_HOME_DIR; source '$DEV_ZSH' 2>/dev/null; _dev_cfg home_dir"
    [ "$output" = "$HOME/code" ]
}

@test "DEV_HOME_DIR overrides home_dir" {
    run zsh -c "DEV_HOME_DIR=/tmp/test; source '$DEV_ZSH' 2>/dev/null; _dev_cfg home_dir"
    [ "$output" = "/tmp/test" ]
}

# ─── Issue 3: read -r and terminal guard for interactive prompts ───

@test "dev <name> refuses to prompt when stdin is not a TTY" {
    # Behavioural replacement for the old '[[ -t 0 ]]' source-grep (T3): drive
    # the real path instead of asserting on the text of the file.
    start_isolated_server dev-ttyguard
    run_dev ttyguard
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-interactive"* ]]
}

# LINT, not a behaviour test: the prompt is gated behind [[ ! -t 0 ]], so the
# 'read' call is unreachable without a pty harness. Kept as a narrow static
# check rather than dropped, and scoped to 'read' as a command so an innocent
# string like "read the docs" cannot trip it.
@test "dev.zsh uses read -r for the interactive choice prompt" {
    run grep -nE '^[[:space:]]*read[[:space:]]+[^-]' "$DEV_ZSH"
    [ "$status" -ne 0 ]
}

# ─── Issue 4: DEV_AI_CMD validation rejects spaces ───

@test "DEV_AI_CMD with spaces is rejected at keybinding setup" {
    run zsh -c "
        DEV_AI_CMD='claude --flag bad';
        source '$DEV_ZSH' 2>/dev/null;
        _dev_validate_ai_cmd
    "
    [ "$status" -ne 0 ]
}

@test "DEV_AI_CMD without spaces passes validation" {
    run zsh -c "
        DEV_AI_CMD='claude';
        source '$DEV_ZSH' 2>/dev/null;
        _dev_validate_ai_cmd
    "
    [ "$status" -eq 0 ]
}

# ─── Issue 5: Double-prefix normalization ───

@test "_dev_display_name strips only one prefix from dev-dev-name" {
    # If someone passes dev-dev-x, display name should be dev-x (one prefix stripped)
    run_zsh_func '_dev_display_name dev-dev-myproject'
    [ "$output" = "dev-myproject" ]
}

# ─── Issue 7: dev reload should not print success when keybindings are skipped ───

@test "dev reload does not print success when keybindings are skipped" {
    # Two actions on one key is the binding error that fails the setup.
    start_isolated_server
    export DEV_KEY_AGENT=j
    run_dev reload
    [[ "$output" == *"Some keybindings were skipped"* ]]
    [[ "$output" != *"Popup keybindings updated"* ]]
}

@test "dev reload does not print success when the agent key is left unbound" {
    start_isolated_server
    export DEV_AI_CMD='claude --model opus'
    run_dev reload
    [[ "$output" == *"DEV_AI_ARGS"* ]]
    [[ "$output" == *"Some keybindings were skipped"* ]]
    [[ "$output" != *"Popup keybindings updated"* ]]
}

# ─── B9: a name never reaches a different session by prefix ───

# tmux resolves -t by exact name, then falls back to a prefix match, so a
# missing dev-proj silently became dev-project.

@test "dev kill does not kill a session whose name merely starts with it" {
    start_isolated_server keep
    tmux new-session -d -s dev-project
    run_dev kill proj
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
    tmux has-session -t '=dev-project'
}

@test "dev attach does not attach to a session whose name merely starts with it" {
    start_isolated_server keep
    tmux new-session -d -s dev-project
    fake_attaching_tmux
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev attach proj" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
    [ ! -s "$BATS_TEST_TMPDIR/attach.log" ]
}

@test "dev <name> creates its session when only a longer name exists" {
    start_isolated_server keep
    tmux new-session -d -s dev-project
    create_dev_session proj
    tmux has-session -t '=dev-proj'
}


# ─── dev help stays true to what dev does (plan Phase 9) ───

reserved_names() {
    run_dev help
    printf '%s\n' "$output" | sed -n 's/^Reserved names[^:]*: *//p' | tr ' ' '\n' | grep .
}

@test "dev help lists the reserved names" {
    run_dev help
    [[ "$output" == *"Reserved names"*"grid"* ]]
}

@test "every reserved name is a command, never a new session" {
    # Because dev <name> is a catch-all, a name the help calls reserved that
    # is not really a command would quietly become a session.
    start_isolated_server keep
    [ -n "$(reserved_names)" ]
    local name
    for name in $(reserved_names); do
        [[ "$name" == __* ]] && continue
        zsh -c 'cd "$HOME/code" && source "$1" 2>/dev/null; dev "$2"' _ "$DEV_ZSH" "$name" </dev/null &>/dev/null || true
        if tmux has-session -t "=dev-${name}" 2>/dev/null; then
            echo "dev ${name} made a session" >&2
            return 1
        fi
    done
}

@test "every command dev help shows is reserved" {
    local reserved commands cmd
    reserved=" $(reserved_names | tr '\n' ' ') "
    run_dev help
    commands="$(printf '%s\n' "$output" | sed -n '/^Commands:/,/^$/p' | sed -n 's/^  dev \([a-z]*\).*/\1/p' | grep . | sort -u)"
    [ -n "$commands" ]
    [ -n "$(reserved_names)" ]
    for cmd in $commands; do
        [[ "$reserved" == *" $cmd "* ]] || { echo "dev $cmd is not in the reserved list" >&2; return 1; }
    done
}

@test "a session name starting with __ is refused" {
    # dev's own entry points (__agent, ...) start with __.
    start_isolated_server keep
    run_dev __mine
    [ "$status" -ne 0 ]
    [[ "$output" == *"__"* ]]
    ! tmux has-session -t '=dev-__mine' 2>/dev/null
}

@test "dev help warns when tmux is older than 3.3" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\n[ "$1" = -V ] && echo "tmux 3.2a" && exit 0\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/tmux"
    chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" zsh -c 'source "$1" 2>/dev/null; dev help' _ "$DEV_ZSH" </dev/null
    [[ "$output" == *"3.3 or newer"* ]]
    run_dev help
    [[ "$output" != *"3.3 or newer"* ]]
}

@test "the keys point at dev's path as installed, not where a symlink resolves" {
    # Homebrew installs bin/dev as a symlink into a versioned Cellar directory
    # that an upgrade deletes; keys bound to it would break until dev ran again.
    mkdir -p "$BATS_TEST_TMPDIR/cellar/9.9/bin" "$BATS_TEST_TMPDIR/opt/bin"
    cp "$DEV_ZSH" "$BATS_TEST_TMPDIR/cellar/9.9/bin/dev"
    ln -s "$BATS_TEST_TMPDIR/cellar/9.9/bin/dev" "$BATS_TEST_TMPDIR/opt/bin/dev"
    start_isolated_server
    run zsh "$BATS_TEST_TMPDIR/opt/bin/dev" reload </dev/null
    local binding; binding="$(tmux list-keys -T prefix | awk '$4 == "a"')"
    [[ "$binding" == *"$BATS_TEST_TMPDIR/opt/bin/dev"* ]]
    [[ "$binding" != *"cellar"* ]]
}

# ─── Unknown subcommands and dev's own entry points ───

@test "dev grid with an unknown command fails and builds nothing" {
    isolate_git
    local repo; repo="$(make_repo)"
    start_isolated_server keep
    run zsh -c 'cd "$1" && source "$2" 2>/dev/null; dev grid bogus' _ "$repo" "$DEV_ZSH" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown grid command: bogus"* ]]
    [ "$(session_names)" = "keep" ]
}

@test "dev agent with no or an unknown command shows its usage" {
    local args
    for args in "" "bogus"; do
        run zsh -c 'source "$1" 2>/dev/null; dev agent $2' _ "$DEV_ZSH" "$args" </dev/null
        [ "$status" -ne 0 ]
        [[ "$output" == *"Usage: dev agent"* ]]
    done
}

@test "dev agent dashboard and overview outside a grid say there is none" {
    start_isolated_server keep
    local verb
    for verb in dashboard overview; do
        run zsh -c 'source "$1" 2>/dev/null; dev agent "$2"' _ "$DEV_ZSH" "$verb" </dev/null
        [ "$status" -eq 0 ]
        [[ "$output" == *"No grid here"* ]]
    done
}

@test "the __overview entry point 3.0.0 keys still run says there is no grid" {
    # A server bound by 3.0.0 runs this until the key is rebound.
    start_isolated_server keep
    local pane; pane="$(tmux display-message -p -t '=keep:' '#{pane_id}')"
    run zsh "$DEV_ZSH" __overview "$pane" "" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"No grid here"* ]]
}

@test "every command dev dispatches is a reserved name" {
    # A command missing from the list would be refused nowhere else: help
    # would not name it, and the reserved-name tests would never run it.
    local reserved labels label
    reserved=" $(zsh -c 'source "$1" 2>/dev/null; print -r -- "${DEV_RESERVED_NAMES[*]}"' _ "$DEV_ZSH" </dev/null) "
    labels="$(sed -n '/^dev() {/,/^}/p' "$DEV_ZSH" | sed -n 's/^        \([^ #(][^ ]*\))$/\1/p' | tr '|' '\n')"
    [[ "$labels" == *ls* ]]
    while IFS= read -r label; do
        [[ "$label" == -* || "$label" == __* || "$label" == '""' || "$label" == '*' ]] && continue
        [[ "$reserved" == *" $label "* ]] || { echo "dev $label is not in DEV_RESERVED_NAMES" >&2; return 1; }
    done <<< "$labels"
}
