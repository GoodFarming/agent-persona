#!/usr/bin/env bash
set -euo pipefail

# agent-persona uninstaller

BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/agent-persona"
STATE_DIR="${TMPDIR:-/tmp}/agent-persona-state"

info() { echo "[uninstall] $*"; }
warn() { echo "[uninstall] WARNING: $*" >&2; }

echo "This will remove agent-persona and all installed personas."
echo ""
echo "Files to be removed:"
echo "  $BIN_DIR/agent-persona"
echo "  $BIN_DIR/codex-persona (symlink)"
echo "  $BIN_DIR/claude-persona (symlink)"
echo "  $BIN_DIR/gemini-persona (symlink)"
echo "  $BIN_DIR/opencode-persona (symlink)"
echo "  $SHARE_DIR/ (personas)"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  info "Aborted"
  exit 0
fi

# Check for orphaned backups first
if [[ -d "$STATE_DIR" ]] && ls "$STATE_DIR"/*.backup 2>/dev/null | grep -q .; then
  warn "Orphaned backups exist. Run 'agent-persona recover' first?"
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Remove binaries
rm -f "$BIN_DIR/agent-persona"
rm -f "$BIN_DIR/codex-persona"
rm -f "$BIN_DIR/claude-persona"
rm -f "$BIN_DIR/gemini-persona"
rm -f "$BIN_DIR/opencode-persona"
info "Removed launcher and shims"

# Remove share directory
if [[ -d "$SHARE_DIR" ]]; then
  rm -rf "$SHARE_DIR"
  info "Removed $SHARE_DIR"
fi

# Clean up state directory
if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  info "Removed state directory"
fi

info "Uninstall complete"
