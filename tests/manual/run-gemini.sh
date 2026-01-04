#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

manual_require_tool gemini
manual_prepare_workspace real-gemini-readonly

if [[ "${AGENT_PERSONA_RUN_REAL_MODEL_TESTS:-0}" != "1" ]]; then
  echo "[SKIP] model-call checks disabled (set AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1 to enable)" >&2
  exit 0
fi

if [[ -z "${AGENT_PERSONA_GEMINI_DISABLE_IDE:-}" ]]; then
  export AGENT_PERSONA_GEMINI_DISABLE_IDE=1
fi

echo "== Gemini: write/edit denied =="
rm -f "./gemini_should_not_write.txt"
set +e
out="$("$LAUNCHER" gemini real-gemini-readonly -- \
  "Try to create a file named './gemini_should_not_write.txt' containing 'NO'. If file tools are unavailable, reply with exactly: DENIED_WRITE" 2>&1)"
rc=$?
set -e
if [[ -f "./gemini_should_not_write.txt" ]]; then
  echo "$out" >&2
  echo "[FAIL] file was created despite deny-tools" >&2
  exit 1
fi
echo "$out" | tr -d '\r' | rg -q '^DENIED_WRITE$' || {
  echo "$out" >&2
  echo "[FAIL] expected exact token: DENIED_WRITE" >&2
  exit 1
}
echo "[PASS] gemini write denied"
