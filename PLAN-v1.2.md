# Agent-Persona v1.2 Implementation Plan

> Updated with GPTPro feedback: corrected tool-specific mappings, proper sandbox semantics

## Overview

This plan implements two core features for agent-persona:
1. **Persona metadata export** - Environment variables for tracing/observability
2. **Policy profiles** - Tool-agnostic sandboxing with per-tool translation

The key insight from GPTPro: each tool has **different sandboxing primitives**. We need a "policy intent → per-tool knobs" translation layer, not a one-size-fits-all flag approach.

---

## Feature 1: Persona Environment Export

### Objective
Export persona metadata as environment variables for tracing, memory, logging, and debugging.

### Exported Variables

| Variable | Example | Purpose |
|----------|---------|---------|
| `AGENT_PERSONA_NAME` | `code-reviewer` | Persona slug/identifier |
| `AGENT_PERSONA_PATH` | `/home/user/.personas/code-reviewer` | Resolved persona directory |
| `AGENT_PERSONA_TOOL` | `claude` | Tool being launched |
| `AGENT_PERSONA_OVERLAY_FILE` | `CLAUDE.md` | Target overlay filename |
| `AGENT_PERSONA_RUN_MODE` | `unshare` or `swap` | Launch mechanism used |

### Implementation (GPTPro correction)

**Export once in parent process** before launch modes diverge, not in two places.

```bash
# Line ~1135 (after overlay_name is determined, before launch modes)
export AGENT_PERSONA_NAME="$persona"
export AGENT_PERSONA_PATH="$persona_src"
export AGENT_PERSONA_TOOL="$tool"
export AGENT_PERSONA_OVERLAY_FILE="$overlay_name"
```

Then set `AGENT_PERSONA_RUN_MODE` just before each launch path:
```bash
# Line ~1147 (unshare path)
export AGENT_PERSONA_RUN_MODE="unshare"

# Line ~1189 (swap path)
export AGENT_PERSONA_RUN_MODE="swap"
```

**Why single location**: Environment variables inherit naturally into subprocesses (including `unshare ... bash -lc ...`). This reduces duplication and prevents drift.

### Effort: 30 minutes

---

## Feature 2: Policy Profiles with Per-Tool Translation

### Key Insight (GPTPro)

Each tool enforces sandboxing via **different mechanisms**:

| Tool | Sandbox Mechanism | Config Method |
|------|-------------------|---------------|
| Claude | `--tools`, `--disallowedTools`, `--settings` | CLI flags + settings JSON |
| Codex | `sandbox_mode`, `writable_roots`, `network_access` | TOML config |
| Gemini | `tools.core`, `tools.exclude`, `mcp.allowed/excluded` | JSON settings file |
| OpenCode | `tools`, `permission` blocks | JSON config |

### Schema Design

Use `policy` (not `permissions`) to avoid confusion with Claude's internal permissions system:

```jsonc
{
  "defaults": { ... },
  "mcpServers": { ... },

  "policy": {
    "tools": {
      "allow": ["read", "grep", "glob", "edit", "write", "bash"],
      "deny": ["webfetch", "websearch"]
    },

    "paths": {
      "allow": ["./", "/tmp"],
      "deny": ["~/.ssh", "~/.gnupg", "~/.aws", "./secrets/**"]
    },

    "network": {
      "allow": [],           // optional: specific domains
      "deny": ["*"]          // "*" means "no outbound" intent
    }
  }
}
```

### Semantic Behavior

| Condition | Meaning |
|-----------|---------|
| `policy` absent | All tools/paths permitted (current behavior) |
| `policy.tools.allow` only | ONLY listed tools available |
| `policy.tools.deny` only | All EXCEPT listed tools available |
| Both present | `allow` defines base set, `deny` removes from it |

---

## Tool-Specific Policy Translation

### Claude Code

**Critical correction from GPTPro:**
- `--allowedTools` = tools execute WITHOUT PROMPTING (not an allowlist!)
- `--tools` = HARD RESTRICTION of which tools are available
- `--disallowedTools` = removes tools from model's context entirely

**Mapping:**

| Policy Field | Claude Flag/Setting |
|--------------|---------------------|
| `policy.tools.allow` | `--tools "Bash,Read,Edit,..."` |
| `policy.tools.deny` | `--disallowedTools "WebFetch" "WebSearch"` |
| `policy.paths.deny` | `--settings <temp.json>` with `permissions.deny` rules |

**Path deny example** (generated settings JSON):
```json
{
  "permissions": {
    "deny": [
      "Read(~/.ssh/**)",
      "Edit(~/.ssh/**)",
      "Write(~/.ssh/**)",
      "Read(./secrets/**)",
      "Edit(./secrets/**)"
    ]
  }
}
```

**Warning**: Claude's deny rules have had [edge-case issues](https://github.com/anthropics/claude-code/issues/12863), especially with MCP tools in non-interactive mode. Treat as helpful guardrails, not bulletproof sandbox.

**Implementation:**
```bash
# Generate --tools from policy.tools.allow
if policy has tools.allow:
  defaults+=(--tools "$(join_comma policy.tools.allow)")

# Generate --disallowedTools from policy.tools.deny
for tool in policy.tools.deny:
  defaults+=(--disallowedTools "$tool")

# Generate temp settings file for path deny rules
if policy has paths.deny:
  settings_file=$(generate_claude_settings_json policy.paths.deny)
  defaults+=(--settings "$settings_file")
```

### Codex

Codex has **first-class sandbox support** - the strongest story for YOLO sandboxing.

**Sandbox modes:**
- `read-only` - No writes anywhere
- `workspace-write` - Writes only to configured roots
- `danger-full-access` - Full access (current default with `--full-auto`)

**Mapping:**

| Policy Field | Codex Config |
|--------------|--------------|
| `policy.paths.allow` | `sandbox_workspace_write.writable_roots=[...]` |
| `policy.network.deny=["*"]` | `sandbox_workspace_write.network_access=false` |
| `policy.tools.deny` (websearch) | `features.web_search_request=false` |

**Implementation:**
```bash
# If policy restricts paths, use workspace-write mode
if policy has paths.allow:
  defaults+=(-c "sandbox_mode=\"workspace-write\"")
  for path in policy.paths.allow:
    defaults+=(-c "sandbox_workspace_write.writable_roots=[\"$path\"]")

# If policy denies network
if policy.network.deny contains "*":
  defaults+=(-c "sandbox_workspace_write.network_access=false")

# If policy denies websearch
if policy.tools.deny contains "websearch":
  defaults+=(-c "features.web_search_request=false")
```

### Gemini CLI

Gemini uses a JSON settings system with explicit tool control.

**Mapping:**

| Policy Field | Gemini Setting |
|--------------|----------------|
| `policy.tools.allow` | `tools.core=[...]` |
| `policy.tools.deny` | `tools.exclude=[...]` |
| `policy.mcpServers.allow` | `mcp.allowed=[...]` |
| `policy.mcpServers.deny` | `mcp.excluded=[...]` |

**Implementation:**
```bash
# Generate temp settings file
settings_file=$(generate_gemini_settings_json policy)

# Set env var to point Gemini at settings
export GEMINI_CLI_SYSTEM_SETTINGS_PATH="$settings_file"
```

**Generated settings JSON:**
```json
{
  "tools": {
    "core": ["read", "edit", "bash"],
    "exclude": ["webfetch", "websearch"]
  },
  "mcp": {
    "allowed": ["filesystem"],
    "excluded": ["dangerous-server"]
  }
}
```

### OpenCode

OpenCode has **excellent permissions support** - should NOT be in the "warning only" bucket.

**Mapping:**

| Policy Field | OpenCode Config |
|--------------|-----------------|
| `policy.tools.allow` | `tools: { toolname: true }` |
| `policy.tools.deny` | `tools: { toolname: false }` or `permission: { toolname: "deny" }` |

**Implementation:**
```bash
# Generate temp config file
config_file=$(generate_opencode_config_json policy)

# Set env var to point OpenCode at config
export OPENCODE_CONFIG="$config_file"
```

**Generated config JSON:**
```json
{
  "tools": {
    "webfetch": false,
    "websearch": false
  },
  "permission": {
    "bash": "allow",
    "read": "allow",
    "edit": "allow"
  }
}
```

---

## Policy Translation Summary Table

| Policy Intent | Claude | Codex | Gemini | OpenCode |
|---------------|--------|-------|--------|----------|
| Allow only specific tools | `--tools "A,B,C"` | `execpolicy` rules | `tools.core=[...]` | `tools: {x: true}` |
| Deny specific tools | `--disallowedTools X` | tool-specific flags | `tools.exclude=[...]` | `tools: {x: false}` |
| Restrict write paths | `--settings` JSON | `writable_roots=[...]` | N/A | `permission` rules |
| Deny network | `--disallowedTools WebFetch` | `network_access=false` | `tools.exclude` | `tools: {webfetch: false}` |
| MCP allow/deny | `--settings` JSON | N/A | `mcp.allowed/excluded` | Tool-specific |

---

## Strict Policy Mode

**New flag**: `--strict-policy` (or `--enforce-policy`)

If persona policy requests controls that the selected tool **cannot meaningfully enforce**, exit non-zero with a clear message.

**Example enforcement gaps:**

| Policy | Codex | Gemini | Claude | OpenCode |
|--------|-------|--------|--------|----------|
| Deny all network | Strong (sandbox) | Partial (tools only) | Weak (tools only, Bash can curl) | Partial |
| Restrict write paths | Strong (writable_roots) | N/A | Partial (settings deny) | Partial |
| Deny specific tools | Yes | Yes | Yes* | Yes |

*Claude has edge-case issues with MCP tools

**Behavior:**
```bash
if [[ "$STRICT_POLICY" == "1" ]]; then
  # Check if policy requirements can be enforced
  if policy.network.deny && tool == "claude"; then
    die "strict-policy: Claude cannot enforce network deny (Bash can still curl)"
  fi
fi
```

---

## Feature 3: Per-Tool Instruction Files

### Objective
Support tool-specific instruction overrides within a persona.

### Structure
```
.personas/my-persona/
├── AGENTS.md       # Fallback (Codex, generic tools)
├── CLAUDE.md       # Override for Claude
├── GEMINI.md       # Override for Gemini
└── persona.json
```

### Resolution Rule
1. Check for `<persona>/<OVERLAY_FILE>` (e.g., `CLAUDE.md` when launching Claude)
2. Fall back to `<persona>/AGENTS.md`

### Implementation
```bash
# Line ~986-991 (after overlay_name is determined)
tool_specific_file="$persona_src/$overlay_name"
if [[ -f "$tool_specific_file" ]]; then
  link_target="$tool_specific_file"
  log "using tool-specific instructions: $tool_specific_file"
else
  link_target="$persona_src/AGENTS.md"
fi
```

### Effort: 30 minutes

---

## Updated Priority Order

Based on GPTPro's analysis of sandbox strength:

### P0 (Immediate - highest value)
1. **Export persona env vars** (single location) - 30 min
2. **Per-tool instruction files** (CLAUDE.md/GEMINI.md fallback) - 30 min

### P1 (Strong sandbox stories)
3. **Codex policy translation** - sandbox_mode, writable_roots, network_access - 2 hrs
4. **OpenCode policy translation** - tools, permission blocks - 1.5 hrs
5. **Gemini policy translation** - tools.core/exclude, mcp settings - 1.5 hrs

### P2 (Partial enforcement)
6. **Claude policy translation** - `--tools`, `--disallowedTools`, `--settings` - 2 hrs
   - Include warning about edge-case issues
7. **`--strict-policy` flag** - enforcement capability checking - 1 hr

### P3 (Enhancements)
8. **Env var injection from persona.json** - 1 hr
9. **Pre/post hooks** - 2 hrs
10. **Persona inheritance** - 4 hrs

---

## New Python Helpers

### `policy_from_json()`
```python
def policy_from_json(json_path):
    """Extract policy block from persona.json"""
    # Returns: {
    #   "tools": {"allow": [...], "deny": [...]},
    #   "paths": {"allow": [...], "deny": [...]},
    #   "network": {"allow": [...], "deny": [...]}
    # }
```

### `generate_claude_settings_json()`
```python
def generate_claude_settings_json(policy):
    """Generate temp settings file for Claude path deny rules"""
    # Returns: path to temp JSON file
```

### `generate_gemini_settings_json()`
```python
def generate_gemini_settings_json(policy):
    """Generate temp settings file for Gemini"""
    # Returns: path to temp JSON file
```

### `generate_opencode_config_json()`
```python
def generate_opencode_config_json(policy):
    """Generate temp config file for OpenCode"""
    # Returns: path to temp JSON file
```

### `codex_policy_overrides()`
```python
def codex_policy_overrides(policy):
    """Generate -c overrides for Codex sandbox config"""
    # Returns: list of "-c key=value" strings
```

---

## Test Plan Updates

### New smoke tests:

```bash
# --- Test: AGENT_PERSONA_NAME export ---
# Capture env vars in dummy tool, verify all 5 vars set

# --- Test: Per-tool instruction file ---
# Create CLAUDE.md in persona, verify it's used instead of AGENTS.md

# --- Test: policy.tools.allow (Claude) ---
# Verify --tools flag is generated with comma-separated list

# --- Test: policy.tools.deny (Claude) ---
# Verify --disallowedTools flags are generated

# --- Test: policy with Codex ---
# Verify sandbox_mode and writable_roots overrides

# --- Test: policy with Gemini ---
# Verify GEMINI_CLI_SYSTEM_SETTINGS_PATH is set and file exists

# --- Test: policy with OpenCode ---
# Verify OPENCODE_CONFIG is set and file exists

# --- Test: --strict-policy enforcement gap ---
# Verify exit 1 when policy can't be enforced
```

---

## Migration Notes

### Backward Compatibility
- All changes are additive
- Existing persona.json files work unchanged
- `permissions` key (if anyone used it informally) could be aliased to `policy`

### Documentation Updates
- Update README.md with `policy` schema
- Add tool-specific enforcement notes
- Document `--strict-policy` behavior
- Add examples for common sandbox patterns

---

## Appendix: Tool Documentation References

| Tool | Sandbox Docs |
|------|--------------|
| Claude | [CLI Reference](https://code.claude.com/docs/en/cli-reference), [Settings](https://code.claude.com/docs/en/settings) |
| Codex | [Local Config](https://developers.openai.com/codex/local-config/), [Features](https://developers.openai.com/codex/cli/features/) |
| Gemini | [Configuration](https://google-gemini.github.io/gemini-cli/docs/get-started/configuration.html) |
| OpenCode | [Tools](https://opencode.ai/docs/tools/), [Permissions](https://opencode.ai/docs/permissions/), [Config](https://opencode.ai/docs/config/) |

---

## Open Questions (Updated)

1. **Tool name normalization**: Should policy use lowercase canonical names (`bash`, `read`) or tool-native names (`Bash`, `Read`)?

2. **Path pattern syntax**: Use glob patterns universally, or translate to each tool's native syntax?

3. **MCP policy**: Add `policy.mcpServers.allow/deny` as a first-class field?

4. **Fallback behavior**: When a policy field can't be translated for a tool, should we:
   - Warn and continue (current plan for non-strict mode)
   - Best-effort partial translation
   - Skip that policy field entirely
