# Blank Persona

A minimal persona with no specialized constraints. Use this for generic agent sessions.

## Purpose
General-purpose AI assistant with standard tool behavior.

## Operating Mode
- No persona-specific restrictions
- Default tool permissions apply
- Follow user instructions directly

## Notes
This persona is recommended as a safe default when you want to launch an agent without specialized behavior. Since agent-persona overlays the instruction file at launch, having a blank persona available ensures you can always start a clean session.

```bash
agent-persona claude blank
agent-persona codex blank
```
