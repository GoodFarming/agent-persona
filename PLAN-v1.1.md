# Agent-Persona v1.1 Implementation Plan

## Overview

This document outlines the implementation plan for two new features and additional enhancements to the agent-persona system. The goal is to improve agent traceability, sandboxing, and quality control while maintaining compatibility with all supported CLI tools (Claude, Codex, Gemini, OpenCode).

---

## Feature 1: Persona Name Environment Export

### Objective
Export persona metadata as environment variables at launch time to enable:
- Agent behavior tracing
- Downstream memory/context systems
- Logging and observability
- Tuning and analytics pipelines

### Exported Variables

| Variable | Example Value | Purpose |
|----------|---------------|---------|
| `AGENT_PERSONA_NAME` | `code-reviewer` | The persona slug/identifier |
| `AGENT_PERSONA_PATH` | `/home/user/.personas/code-reviewer` | Full resolved path to persona directory |
| `AGENT_PERSONA_TOOL` | `claude` | The tool being launched |

### Implementation Details

**Location in codebase**: `agent-persona` lines 1147-1228 (launch section)

**Changes required**:

1. **Unshare mode** (line ~1168): Export variables inside the namespace before exec
```bash
export AGENT_PERSONA_NAME='$persona'
export AGENT_PERSONA_PATH='$persona_src'
export AGENT_PERSONA_TOOL='$tool'
```

2. **Swap mode** (line ~1219): Export variables before tool execution
```bash
export AGENT_PERSONA_NAME="$persona"
export AGENT_PERSONA_PATH="$persona_src"
export AGENT_PERSONA_TOOL="$tool"
```

### Compatibility Matrix

| Tool | Support | Notes |
|------|---------|-------|
| Claude | Full | Env vars passed to subprocess |
| Codex | Full | Env vars passed to subprocess |
| Gemini | Full | Env vars passed to subprocess |
| OpenCode | Full | Env vars passed to subprocess |
| Any PATH executable | Full | Standard env inheritance |

### Effort Estimate
- Implementation: 30 minutes
- Testing: 30 minutes
- **Total: 1 hour**

---

## Feature 2: Allow/Deny Permission Profiles

### Objective
Introduce permission profiles in `persona.json` to sandbox and quality control agent behavior. This enables:
- Restricting which tools an agent can use
- Limiting file/path access
- Controlling MCP server availability
- Creating "safe" personas for untrusted contexts

### Schema Design

**Option A: Structured permissions block** (recommended)
```json
{
  "defaults": { ... },
  "mcpServers": { ... },

  "permissions": {
    "allowedTools": ["Bash", "Read", "Write", "Edit", "Glob", "Grep"],
    "disallowedTools": ["WebFetch", "WebSearch", "Task"],
    "allowedPaths": ["/home/user/project", "/tmp"],
    "disallowedPaths": ["/etc", "/root", "~/.ssh", "~/.gnupg", "~/.aws"]
  }
}
```

**Option B: Simple top-level syntax**
```json
{
  "allow": ["Bash", "Read", "Edit"],
  "deny": ["WebFetch", "WebSearch"]
}
```

### Semantic Behavior

| Condition | Behavior |
|-----------|----------|
| Neither `allow` nor `deny` present | All tools permitted (current behavior) |
| Only `allow` present | ONLY listed tools permitted |
| Only `deny` present | All EXCEPT listed tools permitted |
| Both present | `allow` defines base set, `deny` removes from it |

### Tool-Specific Translation

#### Claude Code
Claude supports native permission flags:
- `--allowedTools "Tool1" "Tool2"` - Tools execute without prompting
- `--disallowedTools "Tool1" "Tool2"` - Tools removed entirely from context

**Path patterns**: Claude supports glob syntax:
- `Edit(/project/**/*.ts)` - Allow editing TypeScript files
- `Read(~/.zshrc)` - Allow reading specific files
- `Bash(git:*)` - Allow git commands only

**Implementation**: Generate flags from persona.json permissions:
```bash
# Generated from permissions.allowedTools
defaults+=(--allowedTools "Bash" "Read" "Write" "Edit")

# Generated from permissions.disallowedTools
defaults+=(--disallowedTools "WebFetch" "WebSearch")
```

#### Codex
Research needed on exact flag syntax. Codex uses TOML config overrides:
```bash
-c sandbox.allowed_commands=["git","npm"]
```

#### Gemini
Research needed. May require wrapper approach if native flags unavailable.

#### Unsupported Tools
For tools without native permission support:
1. Log a warning: `[agent-persona] warning: permissions not supported for <tool>`
2. Optionally: Refuse to launch with `--strict-permissions` flag

### Implementation Details

**New Python helper** `permissions_from_json()` (~line 270):
```python
def permissions_from_json(json_path):
    """Extract permissions from persona.json"""
    # Returns: {"allowedTools": [...], "disallowedTools": [...], ...}
```

**New function** `inject_permissions()` (~line 1040):
```bash
inject_permissions() {
  local json_cfg="$1" tool="$2"
  # Parse permissions, generate tool-specific flags
  # Append to defaults array
}
```

### Compatibility Matrix

| Tool | allowedTools | disallowedTools | Paths | Notes |
|------|--------------|-----------------|-------|-------|
| Claude | Native | Native | Native | Full support via CLI flags |
| Codex | Partial | Partial | TBD | Via TOML overrides |
| Gemini | Warning | Warning | N/A | No native support |
| OpenCode | Warning | Warning | N/A | No native support |

### Effort Estimate
- Schema design: 30 minutes
- Python helper: 1 hour
- Claude integration: 1 hour
- Codex integration: 1 hour
- Testing: 1.5 hours
- **Total: 5 hours**

---

## Additional Enhancements

### Enhancement A: Environment Variable Injection

**Objective**: Allow persona.json to define environment variables passed to the tool.

```json
{
  "env": {
    "ANTHROPIC_MODEL": "claude-sonnet-4-20250514",
    "LOG_LEVEL": "debug",
    "PROJECT_ROOT": "/home/user/myproject"
  }
}
```

**Use cases**:
- Set model preferences per persona
- Configure logging verbosity
- Pass project-specific context

**Effort**: 1 hour

### Enhancement B: Per-Tool Instruction Files

**Objective**: Support tool-specific instruction overrides within a persona.

```
.personas/my-persona/
├── AGENTS.md       # Default (used by Codex, generic tools)
├── CLAUDE.md       # Override for Claude
├── GEMINI.md       # Override for Gemini
└── persona.json
```

**Resolution order**:
1. Check for `<TOOL>.md` (e.g., `CLAUDE.md`)
2. Fall back to `AGENTS.md`

**Use cases**:
- Tool-specific prompt engineering
- Different instruction styles per tool
- Gradual migration between tools

**Effort**: 2 hours

### Enhancement C: Persona Inheritance

**Objective**: Allow a persona to extend another persona.

```json
{
  "extends": "base-secure",
  "defaults": {
    "claude": ["--verbose"]
  }
}
```

**Resolution**:
1. Load parent persona
2. Deep-merge child overrides
3. Child values win on conflict

**Use cases**:
- Organization-wide base policies
- Role-based persona hierarchies
- DRY configuration

**Effort**: 4 hours

### Enhancement D: Pre/Post Hooks

**Objective**: Run scripts before/after tool launch.

```json
{
  "hooks": {
    "pre": "./scripts/setup.sh",
    "post": "./scripts/cleanup.sh"
  }
}
```

**Use cases**:
- Environment setup (activate venv, set vars)
- Cleanup tasks
- Logging/metrics collection
- Git state verification

**Effort**: 2 hours

---

## Implementation Priority

| Priority | Feature | Effort | Value | Complexity |
|----------|---------|--------|-------|------------|
| P0 | Persona name export | 1 hr | High | Low |
| P0 | Allow/Deny (Claude) | 3 hrs | High | Medium |
| P1 | Allow/Deny (Codex) | 2 hrs | Medium | Medium |
| P1 | Env var injection | 1 hr | Medium | Low |
| P2 | Per-tool instructions | 2 hrs | Medium | Low |
| P2 | Pre/Post hooks | 2 hrs | Medium | Medium |
| P3 | Persona inheritance | 4 hrs | Low | High |

---

## Test Plan

### New smoke tests for `tests/smoke.sh`:

```bash
# --- Test: AGENT_PERSONA_NAME export ---
# Verify tool receives AGENT_PERSONA_NAME in environment

# --- Test: permissions.allowedTools (Claude) ---
# Verify --allowedTools flags are generated

# --- Test: permissions.disallowedTools (Claude) ---
# Verify --disallowedTools flags are generated

# --- Test: permissions with unsupported tool ---
# Verify warning is logged, launch proceeds

# --- Test: env injection ---
# Verify custom env vars are passed to tool
```

### Manual testing checklist:
- [ ] Claude with allowedTools only
- [ ] Claude with disallowedTools only
- [ ] Claude with both allow and deny
- [ ] Codex with permissions (once implemented)
- [ ] Gemini with permissions (warning expected)
- [ ] Env var visible in tool's subprocess

---

## Migration Notes

### Backward Compatibility
All changes are additive. Existing `persona.json` files without `permissions` or `env` keys will work unchanged.

### Documentation Updates
- Update README.md with new persona.json fields
- Add examples for common permission patterns
- Document tool-specific behavior differences

---

## Open Questions

1. **Strict mode**: Should `--strict-permissions` refuse to launch if tool doesn't support permissions?

2. **Path syntax**: Should we normalize path patterns across tools, or use native syntax?

3. **Inheritance depth**: Should persona inheritance be limited to prevent cycles?

4. **MCP permissions**: Should `permissions.mcpServers` control which MCP servers are enabled?

---

## Appendix: Claude Code Permission Reference

### Available Tools
```
Bash, Read, Write, Edit, Glob, Grep, WebFetch, WebSearch, Task,
TodoWrite, NotebookEdit, AskUserQuestion, mcp__<server>
```

### Pattern Syntax
```
Bash(git:*)           # Command prefix
Bash(npm run test:*)  # Subcommand prefix
Edit(/src/**/*.ts)    # Glob path pattern
Read(~/.zshrc)        # Home-relative path
WebFetch(domain:example.com)  # Domain restriction
```

### Permission Modes
```
--permission-mode default          # Standard prompting
--permission-mode acceptEdits      # Auto-accept edits
--permission-mode plan             # Read-only analysis
--permission-mode bypassPermissions  # Skip all prompts
```
