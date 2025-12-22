#!/usr/bin/env bash
set -euo pipefail

# Smoke tests for agent-persona

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LAUNCHER="$ROOT_DIR/agent-persona"

# Test helpers
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1" >&2; exit 1; }

# Temp directory for test artifacts
TEST_TMP="$(mktemp -d)"
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

export TMPDIR="$TEST_TMP/tmp"
mkdir -p "$TMPDIR"

export AGENT_PERSONA_STATE_DIR="$TEST_TMP/state"
mkdir -p "$AGENT_PERSONA_STATE_DIR"

echo "Running smoke tests..."
echo ""

# --- Test: version flag ---
VERSION_OUT="$("$LAUNCHER" --version 2>&1)"
[[ "$VERSION_OUT" == agent-persona* ]] || fail "--version output"
pass "--version"

# --- Test: help flag ---
HELP_OUT="$("$LAUNCHER" --help 2>&1)" || true
[[ "$HELP_OUT" == *"USAGE"* ]] || fail "--help output"
pass "--help"

# --- Test: list command ---
export AGENT_PERSONA_HOME="$ROOT_DIR"
LIST_OUT="$("$LAUNCHER" --list 2>&1)" || true
[[ "$LIST_OUT" == *"blank"* ]] || fail "--list should show blank persona"
pass "--list"

# --- Test: which command ---
WHICH_OUT="$("$LAUNCHER" which blank 2>&1)"
[[ "$WHICH_OUT" == *"Persona:"* ]] || fail "which command output"
pass "which"

# --- Test: print-overlay command ---
OVERLAY_OUT="$("$LAUNCHER" print-overlay codex blank 2>&1)"
[[ "$OVERLAY_OUT" == *"BEGIN PERSONA"* ]] || fail "print-overlay output"
pass "print-overlay"

# --- Test: init command ---
INIT_DIR="$TEST_TMP/test-repo"
mkdir -p "$INIT_DIR"
cd "$INIT_DIR"
"$LAUNCHER" init >/dev/null 2>&1
[[ -d "$INIT_DIR/.personas" ]] || fail "init should create .personas/"
[[ -f "$INIT_DIR/.personas/meta.AGENTS.md" ]] || fail "init should create meta.AGENTS.md"
[[ -f "$INIT_DIR/.personas/README.md" ]] || fail "init should create README.md"
pass "init"

# --- Test: init is idempotent ---
"$LAUNCHER" init >/dev/null 2>&1
pass "init (idempotent)"

# --- Test: doctor command ---
DOCTOR_OUT="$("$LAUNCHER" doctor 2>&1)" || true
[[ "$DOCTOR_OUT" == *"Checking"* ]] || fail "doctor output"
pass "doctor"

# --- Test: default meta template is ignored ---
cd "$INIT_DIR"
mkdir -p .personas/test-persona
echo "# Test Persona Content" > .personas/test-persona/AGENTS.md

DEFAULT_META_MERGED="$("$LAUNCHER" print-overlay codex test-persona 2>&1)"
[[ "$DEFAULT_META_MERGED" != *"Repo-Wide Agent Instructions"* ]] || fail "default meta should be ignored until edited"
pass "default meta ignored"

# --- Test: meta merge (position=top) ---
cd "$INIT_DIR"
echo "# Meta Content" > .personas/meta.AGENTS.md

MERGED="$("$LAUNCHER" print-overlay codex test-persona 2>&1)"
# Meta should come before persona when position=top
META_POS=$(echo "$MERGED" | grep -n "Meta Content" | cut -d: -f1 || echo 999)
PERSONA_POS=$(echo "$MERGED" | grep -n "Test Persona Content" | cut -d: -f1 || echo 0)
[[ "$META_POS" -lt "$PERSONA_POS" ]] || fail "meta should be at top by default"
pass "meta merge (position=top)"

# --- Test: meta merge (position=bottom) ---
MERGED_BOTTOM="$("$LAUNCHER" print-overlay codex test-persona --meta-position=bottom 2>&1)"
META_POS=$(echo "$MERGED_BOTTOM" | grep -n "Meta Content" | cut -d: -f1 || echo 0)
PERSONA_POS=$(echo "$MERGED_BOTTOM" | grep -n "Test Persona Content" | cut -d: -f1 || echo 999)
[[ "$META_POS" -gt "$PERSONA_POS" ]] || fail "meta should be at bottom with --meta-position=bottom"
pass "meta merge (position=bottom)"

# --- Test: --no-meta flag ---
NO_META_OUT="$("$LAUNCHER" print-overlay codex test-persona --no-meta 2>&1)"
[[ "$NO_META_OUT" != *"Meta Content"* ]] || fail "--no-meta should skip meta"
pass "--no-meta"

# --- Test: recover with no orphans ---
RECOVER_OUT="$("$LAUNCHER" recover 2>&1)"
[[ "$RECOVER_OUT" == *"No backups"* ]] || fail "recover with no orphans"
pass "recover (no orphans)"

# --- Integration: MCP injection + swap restore ---
cd "$INIT_DIR"
export AGENT_PERSONA_FORCE_SWAP=1

BIN_DIR="$TEST_TMP/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

cat > "$BIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
SH
chmod +x "$BIN_DIR/codex"

cat > "$BIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"

mcp_path=""
for ((i=1; i<=$#; i++)); do
  a="${!i}"
  if [[ "$a" == "--mcp-config" ]]; then
    j=$((i+1))
    [[ $j -le $# ]] || { echo "missing value for --mcp-config" >&2; exit 2; }
    mcp_path="${!j}"
    break
  elif [[ "$a" == --mcp-config=* ]]; then
    mcp_path="${a#*=}"
    break
  fi
done

if [[ -n "$mcp_path" ]]; then
  [[ -f "$mcp_path" ]] || { echo "mcp config not found: $mcp_path" >&2; exit 3; }
  echo "$mcp_path" > "${CAPTURE_FILE}.mcp_path"
fi
SH
chmod +x "$BIN_DIR/claude"

mkdir -p .personas/mcp-persona
echo "# MCP Persona" > .personas/mcp-persona/AGENTS.md
cat > .personas/mcp-persona/persona.json <<'JSON'
{
  "mcpServers": {
    "testserver": {
      "command": "test-mcp",
      "args": ["--foo", "bar"],
      "env": { "TEST_ENV": "1" }
    }
  }
}
JSON

# Seed overlay targets so swap mode restores them
echo "ORIGINAL AGENTS" > AGENTS.md
echo "ORIGINAL CLAUDE" > CLAUDE.md

# Codex: should receive -c mcp_servers.* overrides
export CAPTURE_FILE="$TEST_TMP/codex.args"
"$LAUNCHER" codex mcp-persona -- --hello world >/dev/null 2>&1
grep -Fq 'mcp_servers.testserver.enabled=true' "$CAPTURE_FILE" || fail "codex MCP enabled override"
grep -Fq 'mcp_servers.testserver.command="test-mcp"' "$CAPTURE_FILE" || fail "codex MCP command override"
[[ "$(cat AGENTS.md)" == "ORIGINAL AGENTS" ]] || fail "swap restore (AGENTS.md)"
if compgen -G "$AGENT_PERSONA_STATE_DIR/*.backup" >/dev/null 2>&1; then
  fail "swap restore should not leave backups"
fi
pass "codex MCP injection + swap restore"

# Codex: --no-mcp should skip overrides
export CAPTURE_FILE="$TEST_TMP/codex.no_mcp.args"
"$LAUNCHER" codex mcp-persona --no-mcp -- --hello world >/dev/null 2>&1
if grep -Fq 'mcp_servers.testserver.' "$CAPTURE_FILE"; then
  fail "--no-mcp should skip codex MCP overrides"
fi
pass "codex --no-mcp"

# Claude: should receive --mcp-config, and temp file should be deleted after exit
export CAPTURE_FILE="$TEST_TMP/claude.args"
"$LAUNCHER" claude mcp-persona -- --hello world >/dev/null 2>&1
[[ -f "${CAPTURE_FILE}.mcp_path" ]] || fail "claude should receive --mcp-config"
mcp_path="$(cat "${CAPTURE_FILE}.mcp_path")"
[[ ! -f "$mcp_path" ]] || fail "claude MCP config should be cleaned up"
[[ "$(cat CLAUDE.md)" == "ORIGINAL CLAUDE" ]] || fail "swap restore (CLAUDE.md)"
pass "claude MCP injection + cleanup"

# Claude: --no-mcp should skip injection
export CAPTURE_FILE="$TEST_TMP/claude.no_mcp.args"
rm -f "${CAPTURE_FILE}.mcp_path" 2>/dev/null || true
"$LAUNCHER" claude mcp-persona --no-mcp -- --hello world >/dev/null 2>&1
[[ ! -f "${CAPTURE_FILE}.mcp_path" ]] || fail "--no-mcp should skip claude MCP injection"
pass "claude --no-mcp"

# Claude: user-supplied --mcp-config should not be replaced (and should not be deleted)
custom_cfg="$TEST_TMP/custom-mcp.json"
echo '{}' > "$custom_cfg"
export CAPTURE_FILE="$TEST_TMP/claude.user_mcp.args"
rm -f "${CAPTURE_FILE}.mcp_path" 2>/dev/null || true
"$LAUNCHER" claude mcp-persona -- --mcp-config "$custom_cfg" >/dev/null 2>&1
[[ "$(cat "${CAPTURE_FILE}.mcp_path")" == "$custom_cfg" ]] || fail "user --mcp-config should be respected"
[[ -f "$custom_cfg" ]] || fail "user --mcp-config should not be deleted"
pass "claude user --mcp-config"

# Recover: restore an orphaned backup
echo "CORRUPTED" > AGENTS.md
backup="$(mktemp -p "$AGENT_PERSONA_STATE_DIR" "agent-persona.AGENTS.md.XXXXXX.backup")"
meta="${backup%.backup}.meta"
echo "ORIGINAL AGENTS" > "$backup"
echo "$INIT_DIR/AGENTS.md" > "$meta"
"$LAUNCHER" recover >/dev/null 2>&1
[[ "$(cat AGENTS.md)" == "ORIGINAL AGENTS" ]] || fail "recover should restore original AGENTS.md"
if compgen -G "$AGENT_PERSONA_STATE_DIR/*.backup" >/dev/null 2>&1; then
  fail "recover should remove backups"
fi
pass "recover (orphan backup)"

echo ""
echo "All tests passed!"
