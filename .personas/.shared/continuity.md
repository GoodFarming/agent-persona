# Continuity

This snippet helps the agent maintain context and avoid regressions across multi-step work.

## State Management

- Keep an explicit list of decisions and constraints (what/why).
- Don’t silently change previously agreed semantics; call it out if revisiting.
- Prefer small, reversible changes; keep diffs easy to review.

## Handoffs

- Summarize what changed and where (file paths).
- Call out remaining follow-ups, edge cases, and how to test.
