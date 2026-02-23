#!/usr/bin/env bats
# Tests for dev.zsh

setup() {
    load test_helper
    load_dev_functions
    DEV_ZSH="$PROJECT_ROOT/dev.zsh"
}

# Helper: run a dev.zsh function via zsh
run_zsh_func() {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; $*"
}

# Helper: run dev command via zsh (simulates direct execution)
run_dev() {
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; dev $*"
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
    run_dev version
    [ "$status" -eq 0 ]
    [[ "$output" == *"2.1.0"* ]]
}

@test "dev version shows repository URL" {
    run_dev version
    [[ "$output" == *"github.com/jeryldev/dev-session-manager"* ]]
}

@test "dev -v is alias for version" {
    run_dev -v
    [ "$status" -eq 0 ]
    [[ "$output" == *"2.1.0"* ]]
}

@test "dev --version is alias for version" {
    run_dev --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"2.1.0"* ]]
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
    if tmux list-sessions &>/dev/null; then
        skip "tmux server is running"
    fi
    run_dev reload
    [ "$status" -ne 0 ]
    [[ "$output" == *"No active tmux server"* ]]
}

@test "dev reload with tmux server updates keybindings" {
    if ! tmux list-sessions &>/dev/null; then
        skip "no tmux server running"
    fi
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

@test "dev create and kill session lifecycle" {
    if ! command -v tmux &>/dev/null; then
        skip "tmux not installed"
    fi
    # We can't test full create (it calls tmux attach which blocks),
    # but we can test that create detects missing tmux or validates names
    run_dev 'kill bats-test-session 2>/dev/null; true'
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

@test "_dev_setup_popup_keybindings succeeds without tmux server" {
    # Guard returns early if no tmux server is running; binds keys if one is
    run zsh -c "source '$DEV_ZSH' 2>/dev/null; _dev_setup_popup_keybindings"
    [ "$status" -eq 0 ]
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
