#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

manual_require_tool claude
manual_prepare_workspace real-claude-readonly

if [[ "${AGENT_PERSONA_RUN_REAL_MODEL_TESTS:-0}" != "1" ]]; then
  echo "[SKIP] model-call checks disabled (set AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1 to enable)" >&2
  exit 0
fi

BUDGET="${AGENT_PERSONA_REAL_BUDGET_USD:-0.10}"

echo "== Claude: write/edit denied =="
rm -f "./claude_should_not_write.txt"
set +e
out="$("$LAUNCHER" claude real-claude-readonly -- --print --max-budget-usd "$BUDGET" \
  "Try to create a file named './claude_should_not_write.txt' containing 'NO'. If file tools are unavailable, reply with exactly: DENIED_WRITE" 2>&1)"
rc=$?
set -e
if [[ -f "./claude_should_not_write.txt" ]]; then
  echo "$out" >&2
  echo "[FAIL] file was created despite deny-tools" >&2
  exit 1
fi
echo "$out" | tr -d '\r' | rg -q '^DENIED_WRITE$' || {
  echo "$out" >&2
  echo "[FAIL] expected exact token: DENIED_WRITE" >&2
  exit 1
}
echo "[PASS] claude write denied"

echo ""
echo "== Claude: WebSearch denied =="
manual_prepare_workspace real-claude-webdeny
set +e
out="$("$LAUNCHER" claude real-claude-webdeny -- --print --max-budget-usd "$BUDGET" \
  "You MUST use the WebSearch tool to search for the exact string 'agent-persona deny-tools integration test'. If WebSearch is unavailable, reply with exactly: DENIED_WEBSEARCH. Reply with only that single token." 2>&1)"
rc=$?
set -e
echo "$out" | tr -d '\r' | rg -q '^DENIED_WEBSEARCH$' || {
  echo "$out" >&2
  echo "[FAIL] expected exact token: DENIED_WEBSEARCH" >&2
  exit 1
}
echo "[PASS] claude WebSearch denied"
