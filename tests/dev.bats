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
    local decoy="$BATS_TEST_TMPDIR/decoy"
    mkdir -p "$decoy"
    TMUX_TMPDIR="$decoy" tmux -f /dev/null new-session -d -s decoy-session
    local decoy_sock
    decoy_sock="$(TMUX_TMPDIR="$decoy" tmux display-message -p '#{socket_path}')"

    # Sabotage isolation the way a third broken mechanism would: point $TMUX at
    # the decoy so it outranks TMUX_TMPDIR, then ask the guard to run.
    run env TMUX="$decoy_sock,1,0" \
            BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/sabotage" \
            bash -c "mkdir -p \"\$BATS_TEST_TMPDIR\"; BATS_TEST_FILENAME='$BATS_TEST_FILENAME'; source '$PROJECT_ROOT/tests/test_helper.bash'; isolate_tmux"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING TO RUN"* ]]

    # The decoy must still be standing.
    run env TMUX_TMPDIR="$decoy" tmux has-session -t decoy-session
    [ "$status" -eq 0 ]

    TMUX_TMPDIR="$decoy" tmux kill-server 2>/dev/null || true
}

# ─── B8: advertised window numbers must exist (US-1) ───

# `dev help` advertises windows 1-7 and `prefix 1` must reach frontend, on any
# config (US-1.1, US-1.2). The code used to hardcode -t <session>:2..:7 while
# new-session put the first window at the server's base-index: on a stock config
# (base-index 0) that gave 0,2,3,4,5,6,7 and `prefix 1` reached nothing.
assert_windows_one_to_seven() {
    run tmux list-windows -t "$1" -F '#{window_index}:#{window_name}'
    [ "$status" -eq 0 ]
    [ "$output" = $'1:frontend\n2:backend\n3:database\n4:testing\n5:editor\n6:scratch\n7:extra' ]
}

@test "dev <name> numbers its windows 1-7 on a stock config (base-index 0)" {
    create_dev_session layout
    [ "$(tmux show-option -gv base-index)" = "0" ]
    assert_windows_one_to_seven dev-layout
}

@test "dev <name> numbers its windows 1-7 under base-index 1" {
    start_isolated_server
    tmux set-option -g base-index 1
    create_dev_session layout
    assert_windows_one_to_seven dev-layout
}

@test "dev <name> opens on the editor window, whatever its index" {
    # 'Starts at window 5 (editor)' is only true when base-index is 1.
    create_dev_session startwin
    run tmux display-message -p -t dev-startwin '#{window_name}'
    [ "$status" -eq 0 ]
    [ "$output" = "editor" ]
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
    [[ "$script" == *'-E "tmux attach-session -t \"$SESSION\""'* ]]
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
    [ "$(cat "$BATS_TEST_TMPDIR/attach.log")" = "switch-client -t dev-other" ]
}

@test "dev attach from outside tmux attaches" {
    start_isolated_server
    tmux new-session -d -s dev-other
    fake_attaching_tmux
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" zsh -c "source '$DEV_ZSH' 2>/dev/null; dev attach dev-other" </dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/attach.log")" = "attach -t dev-other" ]
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

@test "_dev_validate_name rejects special characters" {
    run_zsh_func '_dev_validate_name "my project"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"letters, numbers, hyphens, and underscores"* ]]
}

@test "_dev_validate_name rejects dots" {
    run_zsh_func '_dev_validate_name "my.project"'
    [ "$status" -ne 0 ]
}

@test "_dev_validate_name rejects slashes" {
    run_zsh_func '_dev_validate_name "my/project"'
    [ "$status" -ne 0 ]
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
    local clean=$(echo "$output" | strip_colors)
    [[ "$clean" == *"✓"* ]]
    [[ "$clean" == *"test label"* ]]
}

@test "_dev_check_optional shows X for missing command" {
    run_zsh_func '_dev_check_optional nonexistent_xyz "test label" "brew install foo"'
    local clean=$(echo "$output" | strip_colors)
    [[ "$clean" == *"✗"* ]]
    [[ "$clean" == *"brew install foo"* ]]
}

# ─── dev help ───

@test "dev help shows header box" {
    run_dev help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dev session manager"* ]]
}

@test "dev help shows prerequisites section" {
    run_dev help
    [[ "$output" == *"Prerequisites"* ]]
}

@test "dev help shows optional tools section" {
    run_dev help
    [[ "$output" == *"Optional tools"* ]]
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

@test "dev help shows session layout" {
    run_dev help
    [[ "$output" == *"frontend"* ]]
    [[ "$output" == *"backend"* ]]
    [[ "$output" == *"editor"* ]]
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
}

@test "dev t is alias for tmux" {
    run_dev t
    [ "$status" -eq 0 ]
    [[ "$output" == *"Tmux commands reference"* ]]
}

# ─── dev (empty) ───

@test "dev with no args shows usage error" {
    run_dev
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"dev help"* ]]
}

# ─── dev ls ───

@test "dev ls requires tmux" {
    # This test verifies tmux is checked; if tmux is installed it will work
    run_dev ls
    if command -v tmux &>/dev/null; then
        [ "$status" -eq 0 ]
        [[ "$output" == *"Active dev sessions"* ]]
    else
        [ "$status" -ne 0 ]
        [[ "$output" == *"tmux is not installed"* ]]
    fi
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
}

# ─── dev kill (validation) ───

@test "dev kill without name shows usage" {
    run_dev kill
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: dev kill"* ]]
}

@test "dev kill nonexistent session shows error" {
    if ! command -v tmux &>/dev/null; then
        skip "tmux not installed"
    fi
    run_dev kill nonexistent-test-session-xyz
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

# ─── _dev_show_prerequisites ───

@test "_dev_show_prerequisites shows required and optional sections" {
    run_zsh_func '_dev_show_prerequisites'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Prerequisites"* ]]
    [[ "$output" == *"Optional tools"* ]]
    [[ "$output" == *"claude"* ]]
    [[ "$output" == *"kb"* ]]
    [[ "$output" == *"lazygit"* ]]
}

# ─── Popup keybinding guards ───

@test "_dev_setup_popup_keybindings returns non-zero without tmux server" {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_setup_popup_keybindings"
    [ "$status" -ne 0 ]
}

@test "_dev_bind_popup is defined after sourcing" {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; type _dev_bind_popup"
    [ "$status" -eq 0 ]
    [[ "$output" == *"function"* ]]
}

# ─── _dev_session_not_found ───

@test "_dev_session_not_found shows error and tip" {
    run_zsh_func '_dev_session_not_found myproject'
    local clean=$(echo "$output" | strip_colors)
    [[ "$clean" == *"✗"* ]]
    [[ "$clean" == *"myproject"* ]]
    [[ "$clean" == *"dev ls"* ]]
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

@test "DEV_AI_CMD defaults to claude" {
    run zsh -c "unset DEV_AI_CMD; source '$DEV_ZSH' 2>/dev/null; echo \$DEV_AI_CMD"
    [ "$output" = "claude" ]
}

@test "DEV_AI_CMD can be overridden" {
    run zsh -c "DEV_AI_CMD=aider; source '$DEV_ZSH' 2>/dev/null; echo \$DEV_AI_CMD"
    [ "$output" = "aider" ]
}

@test "DEV_DEFAULT_DIR defaults to ~/code" {
    run zsh -c "unset DEV_HOME_DIR; source '$DEV_ZSH' 2>/dev/null; echo \$DEV_DEFAULT_DIR"
    [ "$output" = "$HOME/code" ]
}

@test "DEV_DEFAULT_DIR respects DEV_HOME_DIR" {
    run zsh -c "DEV_HOME_DIR=/tmp/test; source '$DEV_ZSH' 2>/dev/null; echo \$DEV_DEFAULT_DIR"
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

@test "dev <name> does not hang when stdin is not a TTY" {
    start_isolated_server dev-ttyguard
    run timeout 5 zsh -c "source '$DEV_ZSH' 2>/dev/null; dev ttyguard" </dev/null
    # 124 is timeout(1) killing a hung prompt — the bug this guards against
    [ "$status" -ne 124 ]
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

@test "_dev_normalize_session_name does not double-prefix dev-dev-" {
    run_zsh_func '_dev_normalize_session_name dev-myproject'
    [ "$output" = "dev-myproject" ]
    # Explicitly verify no double prefix
    [[ "$output" != "dev-dev-"* ]]
}

@test "_dev_display_name strips only one prefix from dev-dev-name" {
    # If someone passes dev-dev-x, display name should be dev-x (one prefix stripped)
    run_zsh_func '_dev_display_name dev-dev-myproject'
    [ "$output" = "dev-myproject" ]
}

# ─── Issue 7: dev reload should not print success when keybindings are skipped ───

@test "dev reload does not print success when keybindings are skipped" {
    # When _dev_setup_popup_keybindings returns early (no tmux server),
    # reload should not print the success message
    run_dev reload
    [[ "$output" != *"Popup keybindings updated"* ]]
}
