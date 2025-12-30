#!/bin/bash

# Dev Session Manager Installer
# https://github.com/jeryldev/dev-session-manager

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Dev Session Manager Installer${NC}"
echo ""

# Check for tmux
if ! command -v tmux &> /dev/null; then
    echo -e "${YELLOW}Warning: tmux is not installed${NC}"
    echo -e "Install with: ${BLUE}brew install tmux${NC} (macOS)"
    echo -e "           or ${BLUE}apt install tmux${NC} (Ubuntu/Debian)"
    echo ""
fi

# Check for zsh
if [[ ! "$SHELL" == *"zsh"* ]] && [[ ! -f ~/.zshrc ]]; then
    echo -e "${RED}Error: This tool requires zsh${NC}"
    exit 1
fi

# Create config directory
CONFIG_DIR="${HOME}/.config/zsh"
mkdir -p "$CONFIG_DIR"

# Determine script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy dev.zsh
if [[ -f "${SCRIPT_DIR}/dev.zsh" ]]; then
    cp "${SCRIPT_DIR}/dev.zsh" "${CONFIG_DIR}/dev.zsh"
    echo -e "${GREEN}✓${NC} Installed dev.zsh to ${CONFIG_DIR}/"
else
    # Download from GitHub if running via curl
    echo -e "${BLUE}Downloading dev.zsh...${NC}"
    curl -fsSL https://raw.githubusercontent.com/jeryldev/dev-session-manager/main/dev.zsh -o "${CONFIG_DIR}/dev.zsh"
    echo -e "${GREEN}✓${NC} Downloaded dev.zsh to ${CONFIG_DIR}/"
fi

# Add source line to .zshrc if not present
ZSHRC="${HOME}/.zshrc"
SOURCE_LINE='[[ -f ~/.config/zsh/dev.zsh ]] && source ~/.config/zsh/dev.zsh'

if ! grep -q "dev.zsh" "$ZSHRC" 2>/dev/null; then
    echo "" >> "$ZSHRC"
    echo "# Dev Session Manager" >> "$ZSHRC"
    echo "$SOURCE_LINE" >> "$ZSHRC"
    echo -e "${GREEN}✓${NC} Added source line to ~/.zshrc"
else
    echo -e "${YELLOW}→${NC} Source line already exists in ~/.zshrc"
fi

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo -e "Run ${BLUE}source ~/.zshrc${NC} or restart your terminal to activate."
echo ""
echo -e "Then try: ${BLUE}dev help${NC}"
