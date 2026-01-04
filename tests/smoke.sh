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

export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

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
[[ "$OVERLAY_OUT" == *"<!-- persona -->"* ]] || fail "print-overlay output"
pass "print-overlay"

# --- Test: flags requiring values ---
set +e
OUT="$("$LAUNCHER" print-overlay codex blank --meta-position 2>&1)"
RC=$?
set -e
[[ $RC -ne 0 && "$OUT" == *"--meta-position requires a value"* ]] || fail "--meta-position without value should error"
pass "--meta-position requires value"

set +e
OUT="$("$LAUNCHER" print-overlay codex blank --meta-file 2>&1)"
RC=$?
set -e
[[ $RC -ne 0 && "$OUT" == *"--meta-file requires a value"* ]] || fail "--meta-file without value should error"
pass "--meta-file requires value"

# --- Test: init command ---
INIT_DIR="$TEST_TMP/test-repo"
mkdir -p "$INIT_DIR"
cd "$INIT_DIR"
"$LAUNCHER" init >/dev/null 2>&1
[[ -d "$INIT_DIR/.personas" ]] || fail "init should create .personas/"
[[ -f "$INIT_DIR/.personas/.shared/meta.AGENTS.md" ]] || fail "init should create .shared/meta.AGENTS.md"
[[ -f "$INIT_DIR/.personas/README.md" ]] || fail "init should create README.md"
pass "init"

# --- Install committed test personas into temp repo ---
FIXTURES_DIR="$ROOT_DIR/tests/fixtures/personas"
if [[ ! -d "$FIXTURES_DIR" ]]; then
  fail "missing fixtures dir: $FIXTURES_DIR"
fi
cp -R "$FIXTURES_DIR"/. "$INIT_DIR/.personas/"

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
echo '<!-- include {"file":"snippets/meta-snippet.md"} -->' > .personas/.shared/meta.AGENTS.md

MERGED="$("$LAUNCHER" print-overlay codex test-persona 2>&1)"
# Meta should come before persona when position=top
META_POS=$(echo "$MERGED" | grep -n "Meta Snippet" | cut -d: -f1 || echo 999)
PERSONA_POS=$(echo "$MERGED" | grep -n "Test Persona Content" | cut -d: -f1 || echo 0)
[[ "$META_POS" -lt "$PERSONA_POS" ]] || fail "meta should be at top by default"
pass "meta merge (position=top)"

# --- Test: meta merge (position=bottom) ---
MERGED_BOTTOM="$("$LAUNCHER" print-overlay codex test-persona --meta-position=bottom 2>&1)"
META_POS=$(echo "$MERGED_BOTTOM" | grep -n "Meta Snippet" | cut -d: -f1 || echo 0)
PERSONA_POS=$(echo "$MERGED_BOTTOM" | grep -n "Test Persona Content" | cut -d: -f1 || echo 999)
[[ "$META_POS" -gt "$PERSONA_POS" ]] || fail "meta should be at bottom with --meta-position=bottom"
pass "meta merge (position=bottom)"

# --- Test: --no-meta flag ---
NO_META_OUT="$("$LAUNCHER" print-overlay codex test-persona --no-meta 2>&1)"
[[ "$NO_META_OUT" != *"Meta Snippet"* ]] || fail "--no-meta should skip meta"
pass "--no-meta"

# --- Test: recover with no orphans ---
RECOVER_OUT="$("$LAUNCHER" recover 2>&1)"
[[ "$RECOVER_OUT" == *"No backups"* ]] || fail "recover with no orphans"
pass "recover (no orphans)"

# --- Persona resolution precedence (repo vs home vs extra paths) ---
cd "$INIT_DIR"
mkdir -p .personas/resolve-persona
echo "# Resolve Persona (repo)" > .personas/resolve-persona/AGENTS.md

mkdir -p "$HOME/.personas/resolve-persona"
echo "# Resolve Persona (home)" > "$HOME/.personas/resolve-persona/AGENTS.md"

EXTRA_DIR="$TEST_TMP/extra_personas"
mkdir -p "$EXTRA_DIR/resolve-persona"
echo "# Resolve Persona (extra)" > "$EXTRA_DIR/resolve-persona/AGENTS.md"

OUT="$("$LAUNCHER" which resolve-persona 2>&1)"
[[ "$OUT" == *"Source:       $INIT_DIR/.personas/resolve-persona/AGENTS.md"* ]] || fail "persona resolution should prefer repo by default"
pass "persona resolution (prefer repo)"

OUT="$(AGENT_PERSONA_PREFER_REPO=0 "$LAUNCHER" which resolve-persona 2>&1)"
[[ "$OUT" == *"Source:       $HOME/.personas/resolve-persona/AGENTS.md"* ]] || fail "persona resolution should prefer home when prefer_repo=0"
pass "persona resolution (prefer home)"

OUT="$(AGENT_PERSONA_PREFER_REPO=0 AGENT_PERSONA_PATHS="$EXTRA_DIR" "$LAUNCHER" which resolve-persona 2>&1)"
[[ "$OUT" == *"Source:       $EXTRA_DIR/resolve-persona/AGENTS.md"* ]] || fail "persona resolution should prefer AGENT_PERSONA_PATHS when set"
pass "persona resolution (prefer extra paths)"

# --- Tool-specific overlay selection (CLAUDE.md / GEMINI.md) ---
cd "$INIT_DIR"
OUT="$("$LAUNCHER" print-overlay claude overlay-persona --no-meta 2>&1)"
[[ "$OUT" == *"CLAUDE OVERLAY"* && "$OUT" != *"DEFAULT OVERLAY"* ]] || fail "claude should prefer CLAUDE.md when present"
pass "tool overlay (claude)"

OUT="$("$LAUNCHER" print-overlay gemini overlay-persona --no-meta 2>&1)"
[[ "$OUT" == *"GEMINI OVERLAY"* && "$OUT" != *"DEFAULT OVERLAY"* ]] || fail "gemini should prefer GEMINI.md when present"
pass "tool overlay (gemini)"

OUT="$("$LAUNCHER" print-overlay codex overlay-persona --no-meta 2>&1)"
[[ "$OUT" == *"DEFAULT OVERLAY"* ]] || fail "codex should use AGENTS.md overlay"
pass "tool overlay (codex)"

# --- Include expansion (AGENTS.md) ---
OUT="$("$LAUNCHER" print-overlay codex include-file --no-meta 2>&1)"
[[ "$OUT" == *"SHARED SNIPPET"* ]] || fail "include file should expand"
pass "include file (shared)"

OUT="$("$LAUNCHER" print-overlay codex include-persona --no-meta 2>&1)"
[[ "$OUT" == *"BASE INCLUDE"* ]] || fail "include persona should expand"
pass "include persona"

# --- Integration: MCP injection + swap restore ---
cd "$INIT_DIR"

BIN_DIR="$TEST_TMP/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

cat > "$BIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
if [[ -n "${CAPTURE_ENV:-}" ]]; then
  {
    echo "AGENT_PERSONA_NAME=${AGENT_PERSONA_NAME:-}"
    echo "AGENT_PERSONA_PATH=${AGENT_PERSONA_PATH:-}"
    echo "AGENT_PERSONA_TOOL=${AGENT_PERSONA_TOOL:-}"
    echo "AGENT_PERSONA_OVERLAY_FILE=${AGENT_PERSONA_OVERLAY_FILE:-}"
    echo "AGENT_PERSONA_RUN_MODE=${AGENT_PERSONA_RUN_MODE:-}"
    echo "GEMINI_CLI_SYSTEM_SETTINGS_PATH=${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}"
    echo "OPENCODE_CONFIG=${OPENCODE_CONFIG:-}"
  } > "$CAPTURE_ENV"
fi
SH
chmod +x "$BIN_DIR/codex"

cat > "$BIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
if [[ -n "${CAPTURE_ENV:-}" ]]; then
  {
    echo "AGENT_PERSONA_NAME=${AGENT_PERSONA_NAME:-}"
    echo "AGENT_PERSONA_PATH=${AGENT_PERSONA_PATH:-}"
    echo "AGENT_PERSONA_TOOL=${AGENT_PERSONA_TOOL:-}"
    echo "AGENT_PERSONA_OVERLAY_FILE=${AGENT_PERSONA_OVERLAY_FILE:-}"
    echo "AGENT_PERSONA_RUN_MODE=${AGENT_PERSONA_RUN_MODE:-}"
    echo "GEMINI_CLI_SYSTEM_SETTINGS_PATH=${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}"
    echo "OPENCODE_CONFIG=${OPENCODE_CONFIG:-}"
  } > "$CAPTURE_ENV"
fi

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

cat > "$BIN_DIR/gemini" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
if [[ -n "${CAPTURE_ENV:-}" ]]; then
  {
    echo "AGENT_PERSONA_NAME=${AGENT_PERSONA_NAME:-}"
    echo "AGENT_PERSONA_PATH=${AGENT_PERSONA_PATH:-}"
    echo "AGENT_PERSONA_TOOL=${AGENT_PERSONA_TOOL:-}"
    echo "AGENT_PERSONA_OVERLAY_FILE=${AGENT_PERSONA_OVERLAY_FILE:-}"
    echo "AGENT_PERSONA_RUN_MODE=${AGENT_PERSONA_RUN_MODE:-}"
    echo "GEMINI_CLI_SYSTEM_SETTINGS_PATH=${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}"
    echo "OPENCODE_CONFIG=${OPENCODE_CONFIG:-}"
  } > "$CAPTURE_ENV"
fi
SH
chmod +x "$BIN_DIR/gemini"

cat > "$BIN_DIR/opencode" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
if [[ -n "${CAPTURE_ENV:-}" ]]; then
  {
    echo "AGENT_PERSONA_NAME=${AGENT_PERSONA_NAME:-}"
    echo "AGENT_PERSONA_PATH=${AGENT_PERSONA_PATH:-}"
    echo "AGENT_PERSONA_TOOL=${AGENT_PERSONA_TOOL:-}"
    echo "AGENT_PERSONA_OVERLAY_FILE=${AGENT_PERSONA_OVERLAY_FILE:-}"
    echo "AGENT_PERSONA_RUN_MODE=${AGENT_PERSONA_RUN_MODE:-}"
    echo "GEMINI_CLI_SYSTEM_SETTINGS_PATH=${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}"
    echo "OPENCODE_CONFIG=${OPENCODE_CONFIG:-}"
  } > "$CAPTURE_ENV"
fi
SH
chmod +x "$BIN_DIR/opencode"

# --- Integration: unshare overlay (if available) ---
cd "$INIT_DIR"
unset AGENT_PERSONA_FORCE_SWAP

if command -v unshare >/dev/null 2>&1 && unshare -Um true 2>/dev/null; then
  # Make swap-mode impossible (forces unshare to be the successful path)
  RO_STATE="$TEST_TMP/state_ro"
  mkdir -p "$RO_STATE"
  chmod 555 "$RO_STATE"
  export AGENT_PERSONA_STATE_DIR="$RO_STATE"

  echo "ORIGINAL AGENTS" > AGENTS.md

  # Dummy tool reads the overlaid AGENTS.md from inside the session
  cat > "$BIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
cat AGENTS.md > "${CAPTURE_FILE}.agents"
if [[ -n "${CAPTURE_ENV:-}" ]]; then
  {
    echo "AGENT_PERSONA_NAME=${AGENT_PERSONA_NAME:-}"
    echo "AGENT_PERSONA_PATH=${AGENT_PERSONA_PATH:-}"
    echo "AGENT_PERSONA_TOOL=${AGENT_PERSONA_TOOL:-}"
    echo "AGENT_PERSONA_OVERLAY_FILE=${AGENT_PERSONA_OVERLAY_FILE:-}"
    echo "AGENT_PERSONA_RUN_MODE=${AGENT_PERSONA_RUN_MODE:-}"
    echo "GEMINI_CLI_SYSTEM_SETTINGS_PATH=${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}"
    echo "OPENCODE_CONFIG=${OPENCODE_CONFIG:-}"
  } > "$CAPTURE_ENV"
fi
SH
  chmod +x "$BIN_DIR/codex"

  export CAPTURE_FILE="$TEST_TMP/unshare.args"
  export CAPTURE_ENV="$TEST_TMP/unshare.env"
  "$LAUNCHER" codex unshare-persona --no-meta -- --hello world >/dev/null 2>&1 || fail "unshare overlay launch"
  [[ "$(cat AGENTS.md)" == "ORIGINAL AGENTS" ]] || fail "unshare overlay should not modify AGENTS.md on disk"
  grep -Fq "UNSHARE PERSONA" "${CAPTURE_FILE}.agents" || fail "tool should see persona content via unshare overlay"
  grep -Fxq "AGENT_PERSONA_RUN_MODE=unshare" "$CAPTURE_ENV" || fail "env export (unshare run mode)"
  unset CAPTURE_ENV

  # Restore writable state dir for remaining tests
  export AGENT_PERSONA_STATE_DIR="$TEST_TMP/state"
  chmod 700 "$AGENT_PERSONA_STATE_DIR" 2>/dev/null || true

  pass "unshare overlay (if available)"
else
  echo "[SKIP] unshare overlay (unshare disabled)"
fi

export AGENT_PERSONA_FORCE_SWAP=1

mkdir -p .personas/mcp-persona
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

# --- Env export (swap mode) ---
export CAPTURE_FILE="$TEST_TMP/codex.env.args"
export CAPTURE_ENV="$TEST_TMP/codex.env"
"$LAUNCHER" codex env-persona -- --hello world >/dev/null 2>&1
grep -Fxq "AGENT_PERSONA_NAME=env-persona" "$CAPTURE_ENV" || fail "env export (name)"
grep -Fxq "AGENT_PERSONA_PATH=$INIT_DIR/.personas/env-persona" "$CAPTURE_ENV" || fail "env export (path)"
grep -Fxq "AGENT_PERSONA_TOOL=codex" "$CAPTURE_ENV" || fail "env export (tool)"
grep -Fxq "AGENT_PERSONA_OVERLAY_FILE=AGENTS.md" "$CAPTURE_ENV" || fail "env export (overlay)"
grep -Fxq "AGENT_PERSONA_RUN_MODE=swap" "$CAPTURE_ENV" || fail "env export (run mode)"
unset CAPTURE_ENV
pass "env export (swap mode)"

# --- Defaults override and suppression ---
export CAPTURE_FILE="$TEST_TMP/codex.defaults.args"
"$LAUNCHER" codex defaults-persona -- -c model=from_user >/dev/null 2>&1
if grep -Fq 'model=from_persona' "$CAPTURE_FILE"; then
  fail "user args should override persona defaults (codex -c key)"
fi
grep -Fq 'model=from_user' "$CAPTURE_FILE" || fail "user override should be present (codex -c key)"
pass "defaults override (codex)"

export CAPTURE_FILE="$TEST_TMP/claude.defaults.args"
"$LAUNCHER" claude defaults-persona -- --permission-mode=ask >/dev/null 2>&1
if grep -Fq 'bypassPermissions' "$CAPTURE_FILE"; then
  fail "user args should override persona defaults (claude --permission-mode)"
fi
grep -Fq -- '--permission-mode=ask' "$CAPTURE_FILE" || fail "user override should be present (claude --permission-mode)"
pass "defaults override (claude)"

export CAPTURE_FILE="$TEST_TMP/codex.no_defaults.args"
"$LAUNCHER" codex defaults-persona --no-defaults -- --hello world >/dev/null 2>&1
if grep -Fq 'model=from_persona' "$CAPTURE_FILE"; then
  fail "--no-defaults should disable persona defaults"
fi
if grep -Fq 'features.web_search_request=false' "$CAPTURE_FILE"; then
  fail "--no-defaults should disable persona defaults (-c)"
fi
if grep -Fq -- '--full-auto' "$CAPTURE_FILE"; then
  fail "--no-defaults should disable built-in tool defaults"
fi
pass "--no-defaults"

# --- Policy translation + strict-policy (requires Python) ---
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  PRINT_POLICY_OUT="$("$LAUNCHER" print-policy claude policy-persona 2>&1)"
  [[ "$PRINT_POLICY_OUT" == *"--allowedTools Bash,Read,MyTool"* ]] || fail "print-policy should map tools.allow"
  [[ "$PRINT_POLICY_OUT" == *"--disallowedTools WebSearch,WebFetch"* ]] || fail "print-policy should map tools.deny"
  pass "print-policy (claude translation)"

  PRINT_POLICY_OUT="$("$LAUNCHER" print-policy codex policy-persona 2>&1)"
  [[ "$PRINT_POLICY_OUT" == *"-c sandbox_mode=\"workspace-write\""* ]] || fail "print-policy should set codex sandbox_mode"
  [[ "$PRINT_POLICY_OUT" == *"-c sandbox_workspace_write.writable_roots="* ]] || fail "print-policy should set codex writable_roots"
  [[ "$PRINT_POLICY_OUT" == *"-c sandbox_workspace_write.network_access=false"* ]] || fail "print-policy should set codex network_access"
  [[ "$PRINT_POLICY_OUT" == *"-c features.web_search_request=false"* ]] || fail "print-policy should set codex web_search_request"
  pass "print-policy (codex translation)"

  PRINT_POLICY_OUT="$("$LAUNCHER" print-policy claude policy-include 2>&1)"
  echo "$PRINT_POLICY_OUT" | grep -Fq '"websearch"' || fail "policy include should merge websearch deny"
  echo "$PRINT_POLICY_OUT" | grep -Fq '"bash"' || fail "policy include should merge bash deny"
  pass "policy include merge"

  set +e
  OUT="$("$LAUNCHER" print-policy claude policy-conflict 2>&1)"
  RC=$?
  set -e
  [[ $RC -ne 0 && "$OUT" == *"policy tools.allow conflicts with tools.deny"* ]] || fail "policy include conflict should error"
  pass "policy include conflict"

  # Codex path normalization: ./, ~/, absolute
  mkdir -p "$INIT_DIR/src" "$HOME/allowed-home"
  PRINT_POLICY_OUT="$("$LAUNCHER" print-policy codex policy-paths 2>&1)"
  [[ "$PRINT_POLICY_OUT" == *"$INIT_DIR/src"* ]] || fail "codex should normalize ./ paths to absolute"
  [[ "$PRINT_POLICY_OUT" == *"$HOME/allowed-home"* ]] || fail "codex should expand ~/ paths"
  [[ "$PRINT_POLICY_OUT" == *"/tmp"* ]] || fail "codex should keep absolute paths"
  pass "policy paths normalization (codex)"

  # Policy should apply by default (codex)
  export CAPTURE_FILE="$TEST_TMP/codex.policy.baseline.args"
  "$LAUNCHER" codex policy-persona -- --hello world >/dev/null 2>&1
  grep -Fq 'sandbox_mode="workspace-write"' "$CAPTURE_FILE" || fail "policy baseline should set sandbox_mode"
  grep -Fq 'sandbox_workspace_write.writable_roots=' "$CAPTURE_FILE" || fail "policy baseline should set writable_roots"
  grep -Fq 'sandbox_workspace_write.network_access=false' "$CAPTURE_FILE" || fail "policy baseline should set network_access"
  grep -Fq 'features.web_search_request=false' "$CAPTURE_FILE" || fail "policy baseline should set web_search_request"
  pass "policy baseline (codex)"

  # User args should override policy in normal mode (codex)
  export CAPTURE_FILE="$TEST_TMP/codex.policy.override.args"
  "$LAUNCHER" codex policy-persona -- --full-auto --yolo \
    -c sandbox_mode=danger-full-access \
    -c sandbox_workspace_write.network_access=true \
    -c 'sandbox_workspace_write.writable_roots=["/tmp"]' \
    -c features.web_search_request=true >/dev/null 2>&1
  grep -Fq -- '--full-auto' "$CAPTURE_FILE" || fail "user override should keep --full-auto"
  grep -Fq -- '--yolo' "$CAPTURE_FILE" || fail "user override should keep --yolo"
  grep -Fq 'sandbox_mode=danger-full-access' "$CAPTURE_FILE" || fail "user override should keep sandbox_mode"
  grep -Fq 'sandbox_workspace_write.network_access=true' "$CAPTURE_FILE" || fail "user override should keep network_access"
  grep -Fq 'sandbox_workspace_write.writable_roots=["/tmp"]' "$CAPTURE_FILE" || fail "user override should keep writable_roots"
  grep -Fq 'features.web_search_request=true' "$CAPTURE_FILE" || fail "user override should keep web_search_request"
  if grep -Fq 'sandbox_mode="workspace-write"' "$CAPTURE_FILE"; then
    fail "policy sandbox_mode should not override user args"
  fi
  if grep -Fq 'sandbox_workspace_write.network_access=false' "$CAPTURE_FILE"; then
    fail "policy network_access should not override user args"
  fi
  if grep -Fq 'features.web_search_request=false' "$CAPTURE_FILE"; then
    fail "policy web_search_request should not override user args"
  fi
  pass "policy override (codex)"

  # Strict-policy: policy wins (codex)
  export CAPTURE_FILE="$TEST_TMP/codex.policy.strict.args"
  "$LAUNCHER" codex policy-persona --strict-policy -- --full-auto --yolo \
    -c sandbox_mode=danger-full-access \
    -c sandbox_workspace_write.network_access=true \
    -c 'sandbox_workspace_write.writable_roots=["/tmp"]' \
    -c features.web_search_request=true >/dev/null 2>&1
  if grep -Fq -- '--full-auto' "$CAPTURE_FILE"; then
    fail "strict-policy should drop --full-auto"
  fi
  if grep -Fq -- '--yolo' "$CAPTURE_FILE"; then
    fail "strict-policy should drop --yolo"
  fi
  if grep -Fq 'sandbox_mode=danger-full-access' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user sandbox_mode"
  fi
  if grep -Fq 'sandbox_workspace_write.network_access=true' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user network_access"
  fi
  if grep -Fq 'sandbox_workspace_write.writable_roots=["/tmp"]' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user writable_roots"
  fi
  if grep -Fq 'features.web_search_request=true' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user web_search_request"
  fi
  grep -Fq 'sandbox_mode="workspace-write"' "$CAPTURE_FILE" || fail "strict-policy should set sandbox_mode"
  grep -Fq 'sandbox_workspace_write.writable_roots=' "$CAPTURE_FILE" || fail "strict-policy should set writable_roots"
  grep -Fq 'sandbox_workspace_write.network_access=false' "$CAPTURE_FILE" || fail "strict-policy should set network_access"
  grep -Fq 'features.web_search_request=false' "$CAPTURE_FILE" || fail "strict-policy should set web_search_request"
  pass "strict-policy arg filtering (codex)"

  # Policy should apply by default (claude)
  export CAPTURE_FILE="$TEST_TMP/claude.policy.baseline.args"
  "$LAUNCHER" claude policy-claude -- --hello world >/dev/null 2>&1
  grep -Fq 'Bash,Read' "$CAPTURE_FILE" || fail "policy baseline should set --allowedTools"
  grep -Fq 'WebSearch' "$CAPTURE_FILE" || fail "policy baseline should set --disallowedTools"
  settings_path="$(awk 'prev == "--settings" {print; exit} {prev=$0}' "$CAPTURE_FILE")"
  [[ -n "$settings_path" ]] || fail "policy baseline should set --settings"
  [[ ! -f "$settings_path" ]] || fail "claude settings should be cleaned up"
  pass "policy baseline (claude)"

  # User args should override policy in normal mode (claude)
  export CAPTURE_FILE="$TEST_TMP/claude.policy.override.args"
  "$LAUNCHER" claude policy-claude -- \
    --allowedTools WebFetch \
    --disallowedTools Task \
    --permission-mode bypassPermissions \
    --settings /tmp/should-not-use >/dev/null 2>&1
  grep -Fq 'WebFetch' "$CAPTURE_FILE" || fail "user override should keep --allowedTools"
  grep -Fq 'Task' "$CAPTURE_FILE" || fail "user override should keep --disallowedTools"
  grep -Fq -- '--permission-mode' "$CAPTURE_FILE" || fail "user override should keep --permission-mode"
  grep -Fq '/tmp/should-not-use' "$CAPTURE_FILE" || fail "user override should keep --settings"
  if grep -Fq 'Bash,Read' "$CAPTURE_FILE"; then
    fail "policy --allowedTools should not override user args"
  fi
  if grep -Fq 'WebSearch' "$CAPTURE_FILE"; then
    fail "policy --disallowedTools should not override user args"
  fi
  if compgen -G "$TMPDIR/persona-claude-settings-*.json" >/dev/null 2>&1; then
    fail "claude settings temp files should be cleaned up"
  fi
  pass "policy override (claude)"

  # Strict-policy: policy wins (claude)
  export CAPTURE_FILE="$TEST_TMP/claude.policy.strict.args"
  "$LAUNCHER" claude policy-claude --strict-policy -- \
    --allowedTools WebFetch \
    --disallowedTools Task \
    --permission-mode bypassPermissions \
    --settings /tmp/should-not-use >/dev/null 2>&1
  if grep -Fq 'WebFetch' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user --allowedTools"
  fi
  if grep -Fq 'Task' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user --disallowedTools"
  fi
  if grep -Fq -- '--permission-mode' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user --permission-mode"
  fi
  if grep -Fq '/tmp/should-not-use' "$CAPTURE_FILE"; then
    fail "strict-policy should drop user --settings"
  fi
  grep -Fq 'Bash,Read' "$CAPTURE_FILE" || fail "strict-policy should set --allowedTools"
  grep -Fq 'WebSearch' "$CAPTURE_FILE" || fail "strict-policy should set --disallowedTools"
  settings_path="$(awk 'prev == "--settings" {print; exit} {prev=$0}' "$CAPTURE_FILE")"
  [[ -n "$settings_path" ]] || fail "strict-policy should set --settings"
  [[ "$settings_path" != "/tmp/should-not-use" ]] || fail "strict-policy should override user --settings"
  [[ ! -f "$settings_path" ]] || fail "claude settings should be cleaned up"
  pass "strict-policy arg filtering (claude)"

  export CAPTURE_FILE="$TEST_TMP/claude.strict.args"
  "$LAUNCHER" claude strict-persona --strict-policy -- --hello world >/dev/null 2>&1 || fail "strict-policy should allow network deny when bash denied"
  pass "strict-policy (bash denied)"

  set +e
  OUT="$("$LAUNCHER" claude strict-fail-claude --strict-policy -- --hello world 2>&1)"
  RC=$?
  set -e
  [[ $RC -ne 0 && "$OUT" == *"network.deny"* ]] || fail "strict-policy should fail (claude network deny + bash)"
  pass "strict-policy failure (claude network deny)"

  set +e
  OUT="$("$LAUNCHER" codex strict-fail-codex --strict-policy -- --hello world 2>&1)"
  RC=$?
  set -e
  [[ $RC -ne 0 && "$OUT" == *"paths.deny"* ]] || fail "strict-policy should fail (codex paths.deny)"
  pass "strict-policy failure (codex paths.deny)"

  export CAPTURE_FILE="$TEST_TMP/gemini.policy.args"
  export CAPTURE_ENV="$TEST_TMP/gemini.policy.env"
  "$LAUNCHER" gemini policy-gemini -- --hello world >/dev/null 2>&1
  settings_path="$(grep -F 'GEMINI_CLI_SYSTEM_SETTINGS_PATH=' "$CAPTURE_ENV" | cut -d= -f2- || true)"
  [[ -n "$settings_path" ]] || fail "gemini settings path should be set"
  [[ ! -f "$settings_path" ]] || fail "gemini settings should be cleaned up"
  unset CAPTURE_ENV
  pass "policy temp cleanup (gemini)"

  export CAPTURE_FILE="$TEST_TMP/opencode.policy.args"
  export CAPTURE_ENV="$TEST_TMP/opencode.policy.env"
  "$LAUNCHER" opencode policy-opencode -- --hello world >/dev/null 2>&1
  settings_path="$(grep -F 'OPENCODE_CONFIG=' "$CAPTURE_ENV" | cut -d= -f2- || true)"
  [[ -n "$settings_path" ]] || fail "opencode config path should be set"
  [[ ! -f "$settings_path" ]] || fail "opencode config should be cleaned up"
  unset CAPTURE_ENV
  pass "policy temp cleanup (opencode)"

  set +e
  OUT="$("$LAUNCHER" gemini strict-fail-gemini --strict-policy -- --hello world 2>&1)"
  RC=$?
  set -e
  [[ $RC -ne 0 && "$OUT" == *"Gemini does not support path restrictions"* ]] || fail "strict-policy should fail (gemini paths)"
  pass "strict-policy failure (gemini paths)"
else
  echo "[SKIP] policy tests (python not found)"
fi

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
