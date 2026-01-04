#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

manual_require_tool codex
manual_prepare_workspace real-codex

echo "== Codex: deny-tools (no model call) =="
set +e
features_out="$("$LAUNCHER" codex real-codex -- features list 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "$features_out" >&2
  echo "[FAIL] codex features list failed" >&2
  exit 1
fi
echo "$features_out" | rg -q '^web_search_request\s+\w+\s+false$' || {
  echo "$features_out" >&2
  echo "[FAIL] expected web_search_request=false" >&2
  exit 1
}
echo "[PASS] codex deny-tools via features"

if [[ "${AGENT_PERSONA_RUN_REAL_MODEL_TESTS:-0}" != "1" ]]; then
  echo "[SKIP] model-call checks disabled (set AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1 to enable)"
  exit 0
fi

echo ""
echo "== Codex: workspace write enforcement (model call) =="
OUTSIDE="$(mktemp -u "${TMPDIR:-/tmp}/codex-outside.XXXXXX")"
rm -f "$OUTSIDE" "./inside_codex.txt"

set +e
codex_out="$("$LAUNCHER" codex real-codex -- exec --skip-git-repo-check \
  "Create a file at '$OUTSIDE' containing 'DENIED'. Then create a file './inside_codex.txt' containing 'OK'." 2>&1)"
rc=$?
set -e

if [[ -f "$OUTSIDE" ]]; then
  echo "$codex_out" >&2
  echo "[FAIL] outside file was created: $OUTSIDE" >&2
  exit 1
fi

if [[ ! -f "./inside_codex.txt" ]]; then
  echo "$codex_out" >&2
  echo "[WARN] inside file not created; model may have refused the action"
else
  echo "[PASS] inside file created; outside file denied"
fi
