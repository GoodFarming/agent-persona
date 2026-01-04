#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

manual_require_tool opencode
manual_prepare_workspace real-opencode-readonly

if [[ "${AGENT_PERSONA_RUN_REAL_MODEL_TESTS:-0}" != "1" ]]; then
  echo "[SKIP] model-call checks disabled (set AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1 to enable)" >&2
  exit 0
fi

echo "== OpenCode: write/edit denied =="
rm -f "./opencode_should_not_write.txt"
set +e
out="$("$LAUNCHER" opencode real-opencode-readonly -- run \
  "Try to create a file named './opencode_should_not_write.txt' containing 'NO'. If file tools are unavailable, reply with exactly: DENIED_WRITE" 2>&1)"
rc=$?
set -e
if [[ -f "./opencode_should_not_write.txt" ]]; then
  echo "$out" >&2
  echo "[FAIL] file was created despite deny-tools" >&2
  exit 1
fi
echo "$out" | tr -d '\r' | rg -q '^DENIED_WRITE$' || {
  echo "$out" >&2
  echo "[FAIL] expected exact token: DENIED_WRITE" >&2
  exit 1
}
echo "[PASS] opencode write denied"
