#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAUNCHER="$ROOT_DIR/agent-persona"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures/personas"

if [[ ! -x "$LAUNCHER" ]]; then
  echo "[FAIL] agent-persona not found: $LAUNCHER" >&2
  exit 1
fi

if [[ ! -d "$FIXTURES_DIR" ]]; then
  echo "[FAIL] fixtures missing: $FIXTURES_DIR" >&2
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-persona-manual.XXXXXX")"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

"$LAUNCHER" init >/dev/null 2>&1
cp -R "$FIXTURES_DIR"/. .personas/

cat > "$WORKDIR/env.sh" <<'SH'
export AGENT_PERSONA_FORCE_SWAP=1
export AGENT_PERSONA_RUN_REAL_TESTS=1
export AGENT_PERSONA_REAL_BUDGET_USD=0.10
export AGENT_PERSONA_GEMINI_DISABLE_IDE=1
# Enable model-call checks (may incur cost):
# export AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1
SH

echo ""
echo "Manual test workspace created:"
echo "  $WORKDIR"
echo ""
echo "Next:"
echo "  cd $WORKDIR"
echo "  source ./env.sh"
echo "  # Run scripts from the repo:"
echo "  $ROOT_DIR/tests/manual/run-codex.sh"
echo "  $ROOT_DIR/tests/manual/run-claude.sh"
echo "  $ROOT_DIR/tests/manual/run-gemini.sh"
echo "  $ROOT_DIR/tests/manual/run-opencode.sh"
echo ""
echo "Cleanup when done:"
echo "  rm -rf $WORKDIR"
