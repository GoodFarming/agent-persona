#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAUNCHER="$ROOT_DIR/agent-persona"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures/personas"

manual_require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[SKIP] $tool not found" >&2
    exit 0
  fi
}

manual_prepare_workspace() {
  local persona="$1"

  if [[ -f ".personas/$persona/AGENTS.md" ]]; then
    return 0
  fi

  if [[ ! -d "$FIXTURES_DIR" ]]; then
    echo "[FAIL] fixtures missing: $FIXTURES_DIR" >&2
    exit 1
  fi

  local workdir
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/agent-persona-manual.XXXXXX")"
  mkdir -p "$workdir/.personas"
  cp -R "$FIXTURES_DIR"/. "$workdir/.personas/"
  cd "$workdir"

  if [[ -z "${AGENT_PERSONA_FORCE_SWAP:-}" ]]; then
    export AGENT_PERSONA_FORCE_SWAP=1
  fi

  echo "[INFO] using manual workspace: $workdir"
  echo "[INFO] cleanup: rm -rf $workdir"
}
