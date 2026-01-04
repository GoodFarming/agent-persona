#!/usr/bin/env bash
set -euo pipefail

# Real integration tests for agent-persona policy enforcement.
#
# This script intentionally does NOT run by default, because it may:
# - require API credentials (Codex/Claude/Gemini/OpenCode)
# - make network requests
# - incur cost
#
# It runs the real CLIs in non-interactive, low-impact modes and validates
# enforcement by checking for (lack of) side effects on disk in a temp workspace.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT_DIR/agent-persona"

if [[ "${AGENT_PERSONA_RUN_REAL_TESTS:-0}" != "1" ]]; then
  echo "[SKIP] real integration tests disabled"
  echo "       Set AGENT_PERSONA_RUN_REAL_TESTS=1 to enable (may incur cost)."
  exit 0
fi

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1" >&2; exit 1; }
warn() { echo "[WARN] $1" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
TIMEOUT_FOREGROUND=0
if have timeout && timeout --help 2>&1 | rg -q -- '--foreground'; then
  TIMEOUT_FOREGROUND=1
fi
run_with_timeout() {
  if have timeout; then
    if [[ $TIMEOUT_FOREGROUND -eq 1 ]]; then
      timeout --foreground -k 5s "${REAL_TIMEOUT_SECONDS}s" "$@"
    else
      timeout -k 5s "${REAL_TIMEOUT_SECONDS}s" "$@"
    fi
  else
    "$@"
  fi
}
SCRIPT_PTY_OK=0
if have script && script -q -c /bin/true /dev/null >/dev/null 2>&1; then
  SCRIPT_PTY_OK=1
fi

REAL_MODEL_TESTS="${AGENT_PERSONA_RUN_REAL_MODEL_TESTS:-0}"
REAL_BUDGET_USD="${AGENT_PERSONA_REAL_BUDGET_USD:-0.15}"
REAL_TIMEOUT_SECONDS="${AGENT_PERSONA_REAL_TIMEOUT_SECONDS:-60}"
# Default to existing credentials; set AGENT_PERSONA_REAL_HOME=0 to isolate in a temp HOME.
USE_REAL_HOME="${AGENT_PERSONA_REAL_HOME:-1}"
if [[ -z "${AGENT_PERSONA_GEMINI_DISABLE_IDE:-}" ]]; then
  export AGENT_PERSONA_GEMINI_DISABLE_IDE=1
fi

TEST_TMP="$(mktemp -d)"
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

export TMPDIR="$TEST_TMP/tmp"
mkdir -p "$TMPDIR"
export AGENT_PERSONA_STATE_DIR="$TEST_TMP/state"
mkdir -p "$AGENT_PERSONA_STATE_DIR"
ORIG_HOME="${HOME:-}"
if [[ "$USE_REAL_HOME" == "1" && -n "$ORIG_HOME" ]]; then
  echo "[INFO] using real HOME for tool credentials: $ORIG_HOME"
  export HOME="$ORIG_HOME"
else
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
fi

if [[ "$REAL_MODEL_TESTS" == "1" ]] && ! have timeout; then
  warn "timeout not found; model-call tests may hang"
fi

WORK="$TEST_TMP/work"
mkdir -p "$WORK"
cd "$WORK"

mkdir -p .personas
FIXTURES_DIR="$ROOT_DIR/tests/fixtures/personas"
cp -R "$FIXTURES_DIR"/. .personas/

# Keep everything in swap mode to avoid unshare requirements.
export AGENT_PERSONA_FORCE_SWAP=1

# ---- Codex: verify deny-tools via feature flags (no model call) ----
if have codex; then
  set +e
  features_out="$(run_with_timeout "$LAUNCHER" codex real-codex -- features list 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 124 ]] || fail "codex features list timed out (set AGENT_PERSONA_REAL_TIMEOUT_SECONDS to increase)"
  [[ $rc -eq 0 ]] || fail "codex features list failed (is Codex installed correctly?)"
  echo "$features_out" | rg -q '^web_search_request\s+\w+\s+false$' || fail "codex web_search_request should be false under policy"
  pass "real codex deny-tools (features.web_search_request=false)"
else
  warn "codex not found; skipping real codex test"
fi

# ---- Claude: verify deny-tools / tool restrictions (model call; opt-in) ----
if have claude; then
  if [[ "$REAL_MODEL_TESTS" == "1" ]]; then
    rm -f "$WORK/claude_should_not_write.txt"
    schema='{"type":"object","properties":{"status":{"enum":["DENIED_WRITE","CREATED"]}},"required":["status"],"additionalProperties":false}'
    tmp_err="$(mktemp)"
    set +e
    claude_out="$(run_with_timeout "$LAUNCHER" claude real-claude-readonly -- --print --output-format json --json-schema "$schema" --max-budget-usd "$REAL_BUDGET_USD" \
      "Use the Write tool to create './claude_should_not_write.txt' with content 'NO'. If the Write/Edit tools are unavailable, respond with JSON {\"status\":\"DENIED_WRITE\"}. Otherwise respond with {\"status\":\"CREATED\"}." 2>"$tmp_err")"
    rc=$?
    set -e
    err_out="$(cat "$tmp_err")"
    rm -f "$tmp_err"

    [[ $rc -ne 124 ]] || fail "claude write denied test timed out (check auth or set AGENT_PERSONA_REAL_TIMEOUT_SECONDS)"
    if echo "$claude_out" | rg -q '"subtype":"error_max_budget_usd"'; then
      echo "$claude_out" >&2
      fail "claude write denied test hit max budget; set AGENT_PERSONA_REAL_BUDGET_USD"
    fi
    [[ ! -f "$WORK/claude_should_not_write.txt" ]] || fail "claude tools policy should prevent file creation"
    set +e
    status="$(CLAUDE_JSON="$claude_out" python3 - <<'PY' 2>/dev/null
import json, os
raw = os.environ.get("CLAUDE_JSON", "")
try:
    data = json.loads(raw)
except Exception:
    print("PARSE_ERROR")
    raise SystemExit(0)
status = ""
if isinstance(data, dict):
    if isinstance(data.get("structured_output"), dict):
        status = data["structured_output"].get("status", "")
    elif isinstance(data.get("result"), str):
        try:
            inner = json.loads(data["result"])
        except Exception:
            inner = None
        if isinstance(inner, dict):
            status = inner.get("status", "")
    else:
        status = data.get("status", "")
print(status)
PY
)"
    py_rc=$?
    set -e
    if [[ $py_rc -ne 0 ]]; then
      echo "$claude_out" >&2
      fail "claude write denied test output parse failed"
    fi
    if [[ "$status" != "DENIED_WRITE" ]]; then
      echo "$err_out" >&2
      echo "$claude_out" >&2
      fail "claude should report status=DENIED_WRITE when write/edit tools denied"
    fi
    pass "real claude write denied"

    schema='{"type":"object","properties":{"status":{"enum":["DENIED_WEBSEARCH","SEARCHED"]}},"required":["status"],"additionalProperties":false}'
    tmp_err="$(mktemp)"
    set +e
    claude_out="$(run_with_timeout "$LAUNCHER" claude real-claude-webdeny -- --print --output-format json --json-schema "$schema" --max-budget-usd "$REAL_BUDGET_USD" \
      "You MUST use the WebSearch tool to search for 'agent-persona deny-tools integration test'. If WebSearch is unavailable, respond with JSON {\"status\":\"DENIED_WEBSEARCH\"}. Otherwise respond with {\"status\":\"SEARCHED\"}." 2>"$tmp_err")"
    rc=$?
    set -e
    err_out="$(cat "$tmp_err")"
    rm -f "$tmp_err"
    [[ $rc -ne 124 ]] || fail "claude WebSearch denied test timed out (check auth or set AGENT_PERSONA_REAL_TIMEOUT_SECONDS)"
    if echo "$claude_out" | rg -q '"subtype":"error_max_budget_usd"'; then
      echo "$claude_out" >&2
      fail "claude WebSearch denied test hit max budget; set AGENT_PERSONA_REAL_BUDGET_USD"
    fi
    set +e
    status="$(CLAUDE_JSON="$claude_out" python3 - <<'PY' 2>/dev/null
import json, os
raw = os.environ.get("CLAUDE_JSON", "")
try:
    data = json.loads(raw)
except Exception:
    print("PARSE_ERROR")
    raise SystemExit(0)
status = ""
if isinstance(data, dict):
    if isinstance(data.get("structured_output"), dict):
        status = data["structured_output"].get("status", "")
    elif isinstance(data.get("result"), str):
        try:
            inner = json.loads(data["result"])
        except Exception:
            inner = None
        if isinstance(inner, dict):
            status = inner.get("status", "")
    else:
        status = data.get("status", "")
print(status)
PY
)"
    py_rc=$?
    set -e
    if [[ $py_rc -ne 0 ]]; then
      echo "$claude_out" >&2
      fail "claude WebSearch denied test output parse failed"
    fi
    if [[ "$status" != "DENIED_WEBSEARCH" ]]; then
      echo "$err_out" >&2
      echo "$claude_out" >&2
      fail "claude should report status=DENIED_WEBSEARCH when WebSearch denied"
    fi
    pass "real claude WebSearch denied"
  else
    warn "claude found; skipping model-call tests (set AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1 to enable)"
  fi
else
  warn "claude not found; skipping real claude test"
fi

# ---- Gemini: verify tool restrictions prevent writes (model call; opt-in) ----
if have gemini; then
  if [[ "$REAL_MODEL_TESTS" == "1" ]]; then
    if [[ ! -t 1 ]] && [[ $SCRIPT_PTY_OK -eq 0 ]]; then
      warn "gemini stdout is not a TTY and 'script' cannot allocate a PTY; skipping to avoid hang"
    else
      rm -f "$WORK/gemini_should_not_write.txt"
      set +e
      gemini_out="$(run_with_timeout "$LAUNCHER" gemini real-gemini-readonly -- \
        "Try to create a file named './gemini_should_not_write.txt' containing 'NO'. If file tools are unavailable, reply with exactly: DENIED_WRITE" 2>&1)"
      rc=$?
      set -e
      [[ $rc -ne 124 ]] || fail "gemini write denied test timed out (check auth or set AGENT_PERSONA_REAL_TIMEOUT_SECONDS)"
      [[ ! -f "$WORK/gemini_should_not_write.txt" ]] || fail "gemini tools policy should prevent file creation"
      echo "$gemini_out" | tr -d '\r' | rg -q '^DENIED_WRITE$' || fail "gemini should report DENIED_WRITE when write/edit tools denied"
      pass "real gemini write denied"
    fi
  else
    warn "gemini found; skipping model-call tests (set AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1 to enable)"
  fi
else
  warn "gemini not found; skipping real gemini test"
fi

# ---- OpenCode: optional (varies by setup; model call; opt-in) ----
if have opencode; then
  if [[ "$REAL_MODEL_TESTS" == "1" ]]; then
    rm -f "$WORK/opencode_should_not_write.txt"
    set +e
    opencode_out="$(run_with_timeout "$LAUNCHER" opencode real-opencode-readonly -- run \
      "Try to create a file named './opencode_should_not_write.txt' containing 'NO'. If file tools are unavailable, reply with exactly: DENIED_WRITE" 2>&1)"
    rc=$?
    set -e
    [[ $rc -ne 124 ]] || fail "opencode write denied test timed out (check auth or set AGENT_PERSONA_REAL_TIMEOUT_SECONDS)"
    if [[ -f "$WORK/opencode_should_not_write.txt" ]]; then
      fail "opencode tools policy should prevent file creation"
    fi
    clean_out="$(printf '%s' "$opencode_out" | tr -d '\r' | sed -E 's/\x1B\\[[0-9;]*[A-Za-z]//g')"
    if printf '%s\n' "$clean_out" | rg -q '^DENIED_WRITE$'; then
      pass "real opencode write denied"
    elif printf '%s\n' "$clean_out" | rg -q 'ZodError|invalid_union'; then
      warn "opencode returned a parse error; skipping enforcement assertion"
    else
      echo "$opencode_out" >&2
      fail "opencode should report DENIED_WRITE when write/edit tools denied"
    fi
  else
    warn "opencode found; skipping model-call tests (set AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1 to enable)"
  fi
else
  warn "opencode not found; skipping real opencode test"
fi

echo ""
echo "All real integration tests passed."
