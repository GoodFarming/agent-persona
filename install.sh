#!/usr/bin/env bash
set -euo pipefail

# agent-persona installer
# Works both locally (git clone) and via curl:
#   curl -fsSL https://raw.githubusercontent.com/GoodFarming/agent-persona/main/install.sh | bash

REPO_URL="https://raw.githubusercontent.com/GoodFarming/agent-persona/main"
VERSION="${AGENT_PERSONA_VERSION:-main}"

BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/agent-persona"

info() { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }

# Detect if running from local clone or curl
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Check for curl or wget
fetch() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
  else
    die "Neither curl nor wget found. Please install one."
  fi
}

# Create directories
mkdir -p "$BIN_DIR" "$SHARE_DIR/personas" "$SHARE_DIR/personas.local"

# Install launcher
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/agent-persona" ]]; then
  # Local install
  cp "$SCRIPT_DIR/agent-persona" "$BIN_DIR/agent-persona"
  info "Installed from local: $BIN_DIR/agent-persona"
else
  # Remote install
  info "Downloading agent-persona..."
  fetch "$REPO_URL/agent-persona" "$BIN_DIR/agent-persona"
  info "Installed from GitHub: $BIN_DIR/agent-persona"
fi
chmod +x "$BIN_DIR/agent-persona"

# Create tool shims
for shim in codex-persona claude-persona gemini-persona opencode-persona; do
  ln -sf "$BIN_DIR/agent-persona" "$BIN_DIR/$shim"
done
info "Created shims: codex-persona, claude-persona, gemini-persona, opencode-persona"

# Install personas
install_persona() {
  local name="$1"
  local src="$2"  # local path or empty for remote

  if [[ -d "$SHARE_DIR/personas/$name" ]]; then
    info "Persona exists, skipping: $name"
    return
  fi

  mkdir -p "$SHARE_DIR/personas/$name"

  if [[ -n "$src" && -f "$src/AGENTS.md" ]]; then
    cp "$src/AGENTS.md" "$SHARE_DIR/personas/$name/"
    [[ -f "$src/persona.json" ]] && cp "$src/persona.json" "$SHARE_DIR/personas/$name/"
  else
    fetch "$REPO_URL/personas/$name/AGENTS.md" "$SHARE_DIR/personas/$name/AGENTS.md"
  fi
  info "Installed persona: $name"
}

if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/personas" ]]; then
  for persona in "$SCRIPT_DIR/personas"/*; do
    [[ -d "$persona" ]] || continue
    install_persona "$(basename "$persona")" "$persona"
  done
else
  install_persona "blank" ""
  install_persona "example" ""
fi

# Install examples
if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/examples" ]]; then
  cp -r "$SCRIPT_DIR/examples" "$SHARE_DIR/"
  info "Installed examples"
else
  mkdir -p "$SHARE_DIR/examples/.personas"
  fetch "$REPO_URL/examples/.personas/meta.AGENTS.md" "$SHARE_DIR/examples/.personas/meta.AGENTS.md"
  info "Installed examples"
fi

# Check PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  warn "$BIN_DIR is not in PATH"
  echo ""
  echo "Add to your shell config (~/.bashrc or ~/.zshrc):"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
  echo "Then restart your shell or run:"
  echo "  source ~/.bashrc"
  echo ""
fi

echo ""
info "Installation complete!"
echo ""
echo "Verify with:"
echo "  agent-persona doctor"
echo "  agent-persona --list"
echo ""
echo "Quick start:"
echo "  agent-persona claude blank"
echo ""
echo "Documentation:"
echo "  https://github.com/GoodFarming/agent-persona"
