#!/usr/bin/env bash
# Shared test helper for dev-session-manager bats tests

PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# Source dev.zsh functions into bash for unit testing.
# We extract functions and variable definitions, skipping zsh-specific constructs.
load_dev_functions() {
    # Set defaults that dev.zsh expects
    export DEV_VERSION="2.1.0"
    export DEV_SESSION_PREFIX="dev-"
    export DEV_DEFAULT_DIR="${HOME}/code"
    export DEV_AI_CMD="claude"

    # Colors
    export RED='\033[0;31m'
    export GREEN='\033[0;32m'
    export YELLOW='\033[0;33m'
    export BLUE='\033[0;34m'
    export NC='\033[0m'
}

# Create a temporary HOME for isolated install tests
setup_temp_home() {
    export ORIGINAL_HOME="$HOME"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME"
}

teardown_temp_home() {
    if [[ -n "$HOME" && "$HOME" != "$ORIGINAL_HOME" ]]; then
        rm -rf "$HOME"
        export HOME="$ORIGINAL_HOME"
    fi
}

# Strip ANSI color codes from output for easier assertion
strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}
