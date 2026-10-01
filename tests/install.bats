#!/usr/bin/env bats
# Tests for install.sh

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-60}"

setup() {
    load test_helper

    INSTALL_SH="$PROJECT_ROOT/install.sh"

    # Use a temporary HOME so we don't touch the real one
    setup_temp_home

    # Create a .zshrc so zsh detection passes
    touch "$HOME/.zshrc"
}

teardown() {
    teardown_temp_home
}

# Helper: run install.sh with stdin piped (to answer prompts)
run_install() {
    run bash -c "SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH' $*"
}

# Helper: run install.sh declining all optional prompts
run_install_decline_all() {
    run bash -c "SHELL=/bin/zsh HOME='$HOME' echo 'nnn' | bash '$INSTALL_SH'"
}

# ─── Syntax validation ───

@test "install.sh has valid bash syntax" {
    run bash -n "$INSTALL_SH"
    [ "$status" -eq 0 ]
}

# ─── Config directory creation ───

@test "install.sh creates ~/.config/zsh directory" {
    # The variables belong to the installer, not to printf.
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
    [ -d "$HOME/.config/zsh" ]
}

# ─── dev.zsh file copy ───

@test "install.sh copies dev.zsh to config directory" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/zsh/dev.zsh" ]
}

@test "copied dev.zsh has same content as source" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    diff "$PROJECT_ROOT/dev.zsh" "$HOME/.config/zsh/dev.zsh"
}

# ─── .zshrc source line ───

@test "install.sh adds source line to .zshrc" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
    grep -q "dev.zsh" "$HOME/.zshrc"
}

@test "install.sh source line is idempotent" {
    # Run twice
    bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'" 2>/dev/null
    bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'" 2>/dev/null

    local count=$(grep -c "dev.zsh" "$HOME/.zshrc")
    # Should only have the source line once (the [[ -f ... ]] && source line)
    # The grep pattern matches both the comment and source line, so count can be 2
    # but should not be 4 (which would mean it was added twice)
    [ "$count" -le 2 ]
}

@test "install.sh shows 'already exists' on second run" {
    bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'" 2>/dev/null
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [[ "$output" == *"already exists"* ]]
}

# ─── Completion message ───

@test "install.sh shows completion message" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installation complete"* ]]
}

@test "install.sh shows next steps" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [[ "$output" == *"source ~/.zshrc"* ]]
    [[ "$output" == *"dev help"* ]]
}

# ─── Optional tools section ───

@test "install.sh shows optional tools section" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
    # Should mention at least one of the optional tools
    [[ "$output" == *"claude"* ]] || [[ "$output" == *"popup"* ]]
}

@test "install.sh shows skip message when declining optional tool" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
    # Should show skip/install-later messages or checkmarks for already-installed tools
    [[ "$output" == *"Skipped"* ]] || [[ "$output" == *"✓"* ]]
}

# ─── Installer header ───

@test "install.sh shows installer header" {
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [[ "$output" == *"Dev session manager installer"* ]]
}

# ─── Zsh detection ───

@test "install.sh fails without zsh shell and no .zshrc" {
    rm -f "$HOME/.zshrc"
    run bash -c "SHELL=/bin/bash HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires zsh"* ]]
}

@test "install.sh passes with .zshrc present even if SHELL is not zsh" {
    # .zshrc exists from setup
    run bash -c "SHELL=/bin/bash HOME='$HOME' printf 'n\nn\nn\n' | bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
}

# ─── Issue 1: set -e should not make optional brew failures fatal ───

@test "install.sh does not use set -e" {
    # set -e makes optional brew install failures fatal even with || guards
    # The script should not contain set -e at all
    run bash -c "grep -n '^set -e' '$INSTALL_SH'"
    [ "$status" -ne 0 ]
}

# ─── Issue 2: Zsh detection should use OR logic ───

@test "install.sh passes with zsh SHELL but no .zshrc file" {
    rm -f "$HOME/.zshrc"
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
}

@test "install.sh fails only when SHELL is not zsh AND .zshrc is missing" {
    rm -f "$HOME/.zshrc"
    run bash -c "SHELL=/bin/bash HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires zsh"* ]]
}

# ─── Issue 6: Idempotency check should match exact source line ───

@test "install.sh idempotency matches exact source line not just dev.zsh" {
    # Pre-populate .zshrc with an unrelated dev.zsh reference
    echo "# I like dev.zsh very much" > "$HOME/.zshrc"
    run bash -c "printf 'n\nn\nn\n' | SHELL=/bin/zsh HOME='$HOME' bash '$INSTALL_SH'"
    [ "$status" -eq 0 ]
    # The actual source line should have been added despite the comment
    grep -q "source.*dev.zsh" "$HOME/.zshrc"
}

# ─── B5: a failed download is a failed install (US-5) ───

@test "install.sh fails, and touches nothing, when the download fails" {
    # A copy without dev.zsh beside it takes the download path.
    local dir; dir="$(mktemp -d)"
    cp "$INSTALL_SH" "$dir/install.sh"
    mkdir -p "$dir/bin"
    printf '#!/bin/sh\nexit 22\n' > "$dir/bin/curl"
    chmod +x "$dir/bin/curl"
    local before; before="$(cat "$HOME/.zshrc")"

    run bash -c "PATH='$dir/bin:$PATH' SHELL=/bin/zsh HOME='$HOME' printf 'n\nn\nn\n' | PATH='$dir/bin:$PATH' SHELL=/bin/zsh HOME='$HOME' bash '$dir/install.sh'"
    rm -rf "$dir"

    [ "$status" -ne 0 ]
    [[ "$output" != *"Downloaded dev.zsh"* ]]
    [[ "$output" != *"Installation complete"* ]]
    [ "$(cat "$HOME/.zshrc")" = "$before" ]
}

# ─── README configuration matches the install path (US-6) ───

readme_section() {
    awk -v h="$1" '$0 == h {on=1; next} on && /^#{2,3} / {exit} on' "$PROJECT_ROOT/README.md"
}

@test "README tells Homebrew users to export settings, with no source line" {
    local section; section="$(readme_section '### Homebrew' | sed -n '1,40p')"
    [[ "$section" == *'export DEV_AI_CMD='* ]]
    [[ "$section" != *'source line'* ]]
}

@test "README tells sourced installs to set settings before the source line" {
    local section; section="$(readme_section '### Quick install or manual install')"
    [[ "$section" == *'before the source line'* ]]
}
