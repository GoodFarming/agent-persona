# Test Personas (Fixtures)

These personas are used by `tests/smoke.sh` to validate launcher behavior without invoking real agent CLIs.

- They are copied into a temp repo’s `.personas/` directory during tests.
- Tests run against dummy `codex`/`claude`/`gemini`/`opencode` shims that only capture arguments and environment variables.
- No network access or model calls occur as part of these fixtures.
- `.shared/` contains reusable snippets and policy fragments for include tests.
