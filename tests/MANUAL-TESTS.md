# Manual Test Suite (High Confidence)

These checks validate that *real* agent CLIs enforce restrictions as expected.
They may require credentials, network access, and may incur cost.

## 0) Preflight

```bash
agent-persona doctor
bash tests/smoke.sh
bash tests/integration-cli-parse.sh
```

## 1) Create a manual test workspace

```bash
bash tests/manual/setup.sh
```

This prints a temp workspace path. Then:

```bash
cd /tmp/agent-persona-manual.XXXXXX
source ./env.sh
```

If you prefer, you can also run the per-tool scripts directly from anywhere;
they will create a temporary workspace automatically if needed.

## 2) Run per-tool manual scripts

Each script launches the real CLI with a persona that denies specific tools
and checks the response and filesystem side effects.

```bash
# Codex: deny-tools (no model call) + optional model call checks
<repo>/tests/manual/run-codex.sh

# Claude: deny write/edit and WebSearch (model calls)
<repo>/tests/manual/run-claude.sh

# Gemini: deny write/edit (model call)
<repo>/tests/manual/run-gemini.sh

# OpenCode: deny write/edit (model call)
<repo>/tests/manual/run-opencode.sh
```

## Notes

- The scripts require you to enable model-call checks explicitly:
  - Set `AGENT_PERSONA_RUN_REAL_MODEL_TESTS=1` in `env.sh`.
  - Adjust `AGENT_PERSONA_REAL_BUDGET_USD` if you want a different cap.
- Gemini CLI may try to connect to an IDE companion; keep `AGENT_PERSONA_GEMINI_DISABLE_IDE=1` to force non-IDE mode.
- If Gemini hangs when output is redirected, set `AGENT_PERSONA_GEMINI_FORCE_TTY=1` (requires `script` from util-linux).
- If a tool isn't installed, its script prints `[SKIP]` and exits 0.
- Cleanup when done: `rm -rf /tmp/agent-persona-manual.XXXXXX`
