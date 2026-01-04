#!/usr/bin/env bash
set -euo pipefail

# Integration tests that validate agent-persona emits CLI arguments/env that are accepted
# by the real tool binaries, without making model calls.
#
# These tests are still optional because they depend on the tools being installed,
# but they are safe: they only invoke `--help` or other local inspection commands.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT_DIR/agent-persona"

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1" >&2; exit 1; }
warn() { echo "[WARN] $1" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

if ! have timeout; then
  warn "timeout not found; skipping cli-parse integration tests"
  exit 0
fi

TEST_TMP="$(mktemp -d)"
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

export TMPDIR="$TEST_TMP/tmp"
mkdir -p "$TMPDIR"
export AGENT_PERSONA_STATE_DIR="$TEST_TMP/state"
mkdir -p "$AGENT_PERSONA_STATE_DIR"
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

WORK="$TEST_TMP/work"
mkdir -p "$WORK"
cd "$WORK"

"$LAUNCHER" init >/dev/null 2>&1
cp -R "$ROOT_DIR/tests/fixtures/personas"/. .personas/

export AGENT_PERSONA_FORCE_SWAP=1

if have codex; then
  timeout 10s "$LAUNCHER" codex policy-persona -- --help >/dev/null 2>&1 || fail "codex should accept policy args with --help"
  pass "codex cli parse (policy args)"
else
  warn "codex not found; skipping"
fi

if have claude; then
  timeout 10s "$LAUNCHER" claude policy-persona -- --help >/dev/null 2>&1 || fail "claude should accept policy args with --help"
  pass "claude cli parse (policy args)"
else
  warn "claude not found; skipping"
fi

if have gemini; then
  timeout 10s "$LAUNCHER" gemini policy-gemini -- --help >/dev/null 2>&1 || fail "gemini should accept policy env with --help"
  pass "gemini cli parse (policy env)"
else
  warn "gemini not found; skipping"
fi

if have opencode; then
  timeout 10s "$LAUNCHER" opencode policy-opencode -- --help >/dev/null 2>&1 || fail "opencode should accept policy env with --help"
  pass "opencode cli parse (policy env)"
else
  warn "opencode not found; skipping"
fi

echo ""
echo "All cli-parse integration tests passed."
