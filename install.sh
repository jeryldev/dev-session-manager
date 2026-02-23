#!/bin/bash
# Dev session manager installer
# https://github.com/jeryldev/dev-session-manager

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Dev session manager installer${NC}"
echo ""

# Check for zsh
if [[ ! "$SHELL" == *"zsh"* ]] && [[ ! -f ~/.zshrc ]]; then
  echo -e "${RED}Error: This tool requires zsh${NC}"
  echo -e "${YELLOW}Install zsh and set it as your default shell first${NC}"
  exit 1
fi

# Check for tmux
if ! command -v tmux &>/dev/null; then
  echo -e "${YELLOW}Warning: tmux is not installed${NC}"
  echo -e "  Install with: ${BLUE}brew install tmux${NC} (macOS)"
  echo -e "             or ${BLUE}apt install tmux${NC} (Ubuntu/Debian)"
  echo -e "             or ${BLUE}dnf install tmux${NC} (Fedora)"
  echo ""
fi

# Optional tool installation prompts
if command -v brew &>/dev/null; then
  echo -e "${YELLOW}Optional tools for popup features:${NC}"
  echo ""

  # Claude Code (AI popup)
  if command -v claude &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} claude (AI popup: Prefix a)"
  else
    echo -ne "  ${YELLOW}Install claude-code for AI popup? (y/n) ${NC}"
    read -r choice
    if [[ "$choice" == [yY] ]]; then
      echo -e "  ${BLUE}Installing claude-code...${NC}"
      brew install claude-code || echo -e "  ${RED}✗${NC} Installation failed. Install manually: ${BLUE}brew install claude-code${NC}"
    else
      echo -e "  ${YELLOW}→${NC} Skipped. Install later: ${BLUE}brew install claude-code${NC}"
    fi
  fi

  # kb (Kanban popup)
  if command -v kb &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} kb (Kanban popup: Prefix k)"
  else
    echo -ne "  ${YELLOW}Install kb for Kanban popup? (y/n) ${NC}"
    read -r choice
    if [[ "$choice" == [yY] ]]; then
      echo -e "  ${BLUE}Installing kb...${NC}"
      brew install jeryldev/tap/kb || echo -e "  ${RED}✗${NC} Installation failed. Install manually: ${BLUE}brew install jeryldev/tap/kb${NC}"
    else
      echo -e "  ${YELLOW}→${NC} Skipped. Install later: ${BLUE}brew install jeryldev/tap/kb${NC}"
    fi
  fi

  # lazygit (Git popup)
  if command -v lazygit &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} lazygit (Git popup: Prefix g)"
  else
    echo -ne "  ${YELLOW}Install lazygit for Git popup? (y/n) ${NC}"
    read -r choice
    if [[ "$choice" == [yY] ]]; then
      echo -e "  ${BLUE}Installing lazygit...${NC}"
      brew install lazygit || echo -e "  ${RED}✗${NC} Installation failed. Install manually: ${BLUE}brew install lazygit${NC}"
    else
      echo -e "  ${YELLOW}→${NC} Skipped. Install later: ${BLUE}brew install lazygit${NC}"
    fi
  fi

  echo ""
else
  echo ""
  echo -e "${YELLOW}Optional popup tools (install manually):${NC}"
  echo -e "  ${BLUE}brew install claude-code${NC}       AI popup (Prefix a)"
  echo -e "  ${BLUE}brew install jeryldev/tap/kb${NC}   Kanban popup (Prefix k)"
  echo -e "  ${BLUE}brew install lazygit${NC}           Git popup (Prefix g)"
  echo ""
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
  echo "" >>"$ZSHRC"
  echo "# Dev session manager" >>"$ZSHRC"
  echo "$SOURCE_LINE" >>"$ZSHRC"
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
