# Knowledge Dilligence

This snippet reduces hallucinations and improves correctness when working with code, docs, or external tools.

## Accuracy Rules

- Don’t invent APIs, flags, or file paths; verify by reading the repo or running `--help`.
- If you’re unsure, ask or propose a safe exploratory command.
- When describing behavior, tie it to a specific implementation detail (function/file), not intuition.

## Verification

- Prefer deterministic checks (unit tests, parsing, static checks) over “it seems right”.
- When something can’t be validated automatically, provide a minimal, explicit manual check.
