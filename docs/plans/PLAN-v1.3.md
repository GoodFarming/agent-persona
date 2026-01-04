# Agent-Persona v1.3 Implementation Plan

> Final implementation-ready plan with GPTPro refinements for enforcement

## Overview

This plan implements persona metadata export and policy-based sandboxing for agent-persona. The key design principle: **policy as enforcement, not documentation**.

---

## Critical Design Decisions

### 1. Argument Layering for Non-Bypassability

**Problem**: Current code builds `tool_args=("${defaults[@]}" "${pass_args[@]}")`, so user args come last and can override policy.

**Solution**: Three-way arg layering with filtering:

```bash
# Build order (later wins):
# 1. default_args   - persona defaults from persona.json
# 2. user_args      - pass-through args (filtered for conflicts)
# 3. policy_args    - enforcement args (always last, always wins)

# Filter conflicting user args when policy exists
filtered_user_args=()
for arg in "${pass_args[@]}"; do
  if is_policy_controlled_flag "$arg" && has_policy; then
    log "filtering user arg blocked by policy: $arg"
    continue
  fi
  filtered_user_args+=("$arg")
done

tool_args=("${default_args[@]}" "${filtered_user_args[@]}" "${policy_args[@]}")
```

**Blocked flags when policy exists**:

| Tool | Blocked User Flags |
|------|-------------------|
| Claude | `--permission-mode`, `--dangerously-skip-permissions`, `--tools`, `--allowedTools`, `--disallowedTools` |
| Codex | `--dangerously-bypass-approvals-and-sandbox`, `-c sandbox_mode=*`, `-c sandbox_workspace_write.*` |
| Gemini | TBD based on CLI options |
| OpenCode | TBD based on CLI options |

### 2. YOLO Defaults Suppression When Policy Exists

**Current behavior** (lines 1021-1034):
- Claude: auto-inject `--permission-mode bypassPermissions`
- Codex: auto-inject `--full-auto`

**New behavior**:
```bash
has_policy=0
[[ -n "$json_cfg" ]] && policy_exists_in_json "$json_cfg" && has_policy=1

case "$tool" in
  claude|claude-code)
    if [[ $has_policy -eq 0 ]]; then
      # No policy: preserve current YOLO behavior
      defaults+=(--permission-mode bypassPermissions)
    else
      # Policy exists: let policy translator decide permission mode
      log "policy present, skipping default permission-mode"
    fi
    ;;
  codex)
    if [[ $has_policy -eq 0 ]]; then
      defaults+=(--full-auto)
    else
      log "policy present, skipping default full-auto"
    fi
    ;;
esac
```

### 3. Temp File Lifecycle Management

**New tracked variables** (add after line 68):
```bash
# Policy temp config files (cleaned up on exit)
claude_settings_file=""
gemini_settings_file=""
opencode_config_file=""

cleanup_policy() {
  [[ -n "${claude_settings_file:-}" && -f "$claude_settings_file" ]] && rm -f "$claude_settings_file" 2>/dev/null || true
  [[ -n "${gemini_settings_file:-}" && -f "$gemini_settings_file" ]] && rm -f "$gemini_settings_file" 2>/dev/null || true
  [[ -n "${opencode_config_file:-}" && -f "$opencode_config_file" ]] && rm -f "$opencode_config_file" 2>/dev/null || true
}
```

**Update cleanup_session** (line 107):
```bash
cleanup_session() {
  set +e
  swap_restore
  cleanup_meta
  cleanup_mcp
  cleanup_policy  # NEW
}
```

---

## Feature 1: Persona Environment Export

### Exported Variables

| Variable | Example | Purpose |
|----------|---------|---------|
| `AGENT_PERSONA_NAME` | `code-reviewer` | Persona slug |
| `AGENT_PERSONA_PATH` | `/path/to/personas/code-reviewer` | Resolved persona directory |
| `AGENT_PERSONA_TOOL` | `claude` | Tool being launched |
| `AGENT_PERSONA_OVERLAY_FILE` | `CLAUDE.md` | Target overlay filename |
| `AGENT_PERSONA_RUN_MODE` | `unshare` or `swap` | Launch mechanism |

### Implementation

**Location**: After line 1065 (after overlay_name determined), before launch modes:

```bash
# --- Export persona metadata for tracing ---
# Normalize persona_dir regardless of profile_type
if [[ "$profile_type" == "file" ]]; then
  persona_dir="$(dirname -- "$persona_src")"
else
  persona_dir="$persona_src"
fi

export AGENT_PERSONA_NAME="$persona"
export AGENT_PERSONA_PATH="$persona_dir"
export AGENT_PERSONA_TOOL="$tool"
export AGENT_PERSONA_OVERLAY_FILE="$overlay_name"
# AGENT_PERSONA_RUN_MODE set just before each launch path
```

**In unshare path** (line ~1147):
```bash
export AGENT_PERSONA_RUN_MODE="unshare"
```

**In swap path** (line ~1189):
```bash
export AGENT_PERSONA_RUN_MODE="swap"
```

---

## Feature 2: Per-Tool Instruction Files

### Resolution Logic

**Fixed for file-vs-dir personas**:

```bash
# After overlay_name is determined, before meta merge (~line 1067)

# Normalize persona_dir (handles both profile_type="file" and "dir")
if [[ "$profile_type" == "file" ]]; then
  persona_dir="$(dirname -- "$persona_src")"
else
  persona_dir="$persona_src"
fi

# Check for tool-specific instruction file
tool_specific_file="$persona_dir/$overlay_name"
if [[ -f "$tool_specific_file" && "$overlay_name" != "AGENTS.md" ]]; then
  link_target="$tool_specific_file"
  log "using tool-specific instructions: $tool_specific_file"
else
  link_target="$persona_dir/AGENTS.md"
fi

[[ -f "$link_target" ]] || die "persona instructions not found: $link_target"
```

### Directory Structure

```
.personas/my-persona/
├── AGENTS.md       # Fallback (Codex, generic tools)
├── CLAUDE.md       # Override for Claude (optional)
├── GEMINI.md       # Override for Gemini (optional)
└── persona.json
```

---

## Feature 3: Policy Profiles

### Schema (Final)

```jsonc
{
  "defaults": { ... },
  "mcpServers": { ... },

  "policy": {
    "tools": {
      "allow": ["bash", "read", "write", "edit", "glob", "grep"],
      "deny": ["webfetch", "websearch", "task"]
    },

    "paths": {
      "allow": ["./", "/tmp"],
      "deny": ["~/.ssh", "~/.gnupg", "~/.aws", "./secrets/**"]
    },

    "network": {
      "deny": ["*"]   // "*" = deny all outbound intent
    },

    "mcpServers": {
      "allow": ["filesystem", "git"],
      "deny": ["dangerous-server"]
    },

    "bash": {
      "allow": ["git:*", "npm:*", "cargo:*"],
      "deny": ["curl:*", "wget:*", "nc:*", "ssh:*"]
    }
  }
}
```

### Tool Name Normalization

**Canonical names** (lowercase, used in policy):
```
bash, read, write, edit, glob, grep, webfetch, websearch,
task, todowrite, notebookedit, askuserquestion
```

**Translation function**:
```python
TOOL_ALIASES = {
    "Bash": "bash", "Read": "read", "Write": "write",
    "Edit": "edit", "Glob": "glob", "Grep": "grep",
    "WebFetch": "webfetch", "WebSearch": "websearch",
    # ... etc
}

def normalize_tool_name(name):
    return TOOL_ALIASES.get(name, name.lower())
```

### Path Semantics

- **Relative paths**: Interpreted as repo-root-relative
- **`~`**: Expanded to `$HOME`
- **Absolute paths**: Used as-is
- **Glob patterns**: Portable syntax, translated per-tool

---

## Tool-Specific Policy Translation

### Claude Code

**Flag semantics** (corrected):
- `--tools "A,B,C"` = Hard restriction of available tools
- `--allowedTools "X" "Y"` = Pre-approve for no-prompt execution
- `--disallowedTools "Z"` = Remove from model context entirely

**Translation**:

```bash
inject_claude_policy() {
  local policy_json="$1"

  # tools.allow → --tools (comma-separated, single flag)
  allowed=$(policy_tools_allow "$policy_json")
  if [[ -n "$allowed" ]]; then
    policy_args+=(--tools "$allowed")
  fi

  # tools.deny → --disallowedTools (space-separated values, single flag)
  denied=$(policy_tools_deny "$policy_json")
  if [[ -n "$denied" ]]; then
    policy_args+=(--disallowedTools $denied)  # word-split intentional
  fi

  # paths.deny → temp settings JSON
  if policy_has_paths_deny "$policy_json"; then
    claude_settings_file=$(generate_claude_settings "$policy_json")
    policy_args+=(--settings "$claude_settings_file")
  fi
}
```

**Generated settings JSON** (for path deny):
```json
{
  "permissions": {
    "deny": [
      "Read(~/.ssh/**)",
      "Edit(~/.ssh/**)",
      "Write(~/.ssh/**)",
      "Bash(cat ~/.ssh/*)",
      "Read(./secrets/**)"
    ]
  }
}
```

**Known limitation**: Claude's deny rules have [edge-case issues](https://github.com/anthropics/claude-code/issues/12863) with MCP tools. Document this; strict-policy should warn.

### Codex

**Sandbox modes**:
- `read-only` - No writes
- `workspace-write` - Writes to configured roots only
- `danger-full-access` - Full access (current --full-auto behavior)

**Translation** (fixed - single array value):

```python
def codex_policy_overrides(policy):
    overrides = []

    # If paths.allow specified, use workspace-write mode
    if policy.get("paths", {}).get("allow"):
        overrides.append('sandbox_mode="workspace-write"')

        # Build single array value for writable_roots
        paths = policy["paths"]["allow"]
        roots_json = json.dumps(paths)  # e.g., ["./", "/tmp"]
        overrides.append(f'sandbox_workspace_write.writable_roots={roots_json}')

    # Network deny
    if "*" in policy.get("network", {}).get("deny", []):
        overrides.append('sandbox_workspace_write.network_access=false')

    # Web search (check tools.deny)
    if "websearch" in [t.lower() for t in policy.get("tools", {}).get("deny", [])]:
        overrides.append('features.web_search_request=false')

    return overrides
```

**Output format**:
```bash
-c 'sandbox_mode="workspace-write"'
-c 'sandbox_workspace_write.writable_roots=["./","/tmp"]'
-c 'sandbox_workspace_write.network_access=false'
```

### Gemini CLI

**Translation**:

```python
def generate_gemini_settings(policy):
    settings = {"tools": {}, "mcp": {}}

    # tools.allow → tools.core
    if policy.get("tools", {}).get("allow"):
        settings["tools"]["core"] = policy["tools"]["allow"]

    # tools.deny → tools.exclude
    if policy.get("tools", {}).get("deny"):
        settings["tools"]["exclude"] = policy["tools"]["deny"]

    # mcpServers.allow/deny
    if policy.get("mcpServers", {}).get("allow"):
        settings["mcp"]["allowed"] = policy["mcpServers"]["allow"]
    if policy.get("mcpServers", {}).get("deny"):
        settings["mcp"]["excluded"] = policy["mcpServers"]["deny"]

    # Write temp file
    fd, path = tempfile.mkstemp(prefix="persona-gemini-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f)
    return path
```

**Injection**:
```bash
gemini_settings_file=$(generate_gemini_settings "$policy_json")
export GEMINI_CLI_SYSTEM_SETTINGS_PATH="$gemini_settings_file"
```

### OpenCode

**Translation**:

```python
def generate_opencode_config(policy):
    config = {"tools": {}, "permission": {}}

    # tools.deny → tools: { name: false }
    for tool in policy.get("tools", {}).get("deny", []):
        config["tools"][tool] = False

    # tools.allow → permission: { name: "allow" }
    for tool in policy.get("tools", {}).get("allow", []):
        config["permission"][tool] = "allow"

    # Write temp file
    fd, path = tempfile.mkstemp(prefix="persona-opencode-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(config, f)
    return path
```

**Injection**:
```bash
opencode_config_file=$(generate_opencode_config "$policy_json")
export OPENCODE_CONFIG="$opencode_config_file"
```

---

## Strict Policy Mode

### Flag: `--strict-policy`

Fails if requested policy elements cannot be meaningfully enforced.

### Enforcement Capability Matrix

| Policy Element | Codex | OpenCode | Gemini | Claude |
|----------------|-------|----------|--------|--------|
| tools.allow | Partial (execpolicy) | Strong | Strong | Strong |
| tools.deny | Partial | Strong | Strong | Partial* |
| paths.allow (write) | Strong (writable_roots) | Partial | N/A | Partial |
| paths.deny | N/A | Partial | N/A | Partial |
| network.deny | Strong (sandbox) | Partial | Partial | Weak** |
| mcpServers.allow/deny | N/A | Partial | Strong | Partial |
| bash.allow/deny | Partial (execpolicy) | Partial | N/A | Partial |

*Claude has edge-case issues with MCP tools
**Claude: disabling WebFetch doesn't prevent `curl` from Bash

### Strict-Policy Logic

```bash
check_strict_policy() {
  local tool="$1" policy_json="$2"

  # Network deny + bash allowed = weak enforcement warning
  if policy_has_network_deny "$policy_json" && policy_allows_bash "$policy_json"; then
    case "$tool" in
      claude|claude-code)
        die "strict-policy: Claude cannot enforce network.deny when bash is allowed (shell can still curl/wget)"
        ;;
      gemini)
        warn "strict-policy: Gemini network.deny only blocks web tools, not shell network access"
        ;;
    esac
  fi

  # Path restrictions unsupported
  if policy_has_paths "$policy_json"; then
    case "$tool" in
      gemini)
        die "strict-policy: Gemini does not support path restrictions"
        ;;
    esac
  fi
}
```

---

## New Command: print-policy

### Usage

```bash
agent-persona print-policy <tool> <persona> [flags]
```

### Output

```
=== Policy Summary ===

Persona:         code-reviewer
Tool:            claude
Overlay file:    CLAUDE.md

=== Environment Variables ===
AGENT_PERSONA_NAME=code-reviewer
AGENT_PERSONA_PATH=/home/user/.personas/code-reviewer
AGENT_PERSONA_TOOL=claude
AGENT_PERSONA_OVERLAY_FILE=CLAUDE.md

=== Policy Translation ===
Source: /home/user/.personas/code-reviewer/persona.json

tools.allow: bash, read, write, edit
  → --tools "bash,read,write,edit"

tools.deny: webfetch, websearch
  → --disallowedTools webfetch websearch

paths.deny: ~/.ssh/**, ./secrets/**
  → --settings /tmp/persona-claude-XXXXX.json

=== Final Arguments ===
Default args:  (none, policy overrides YOLO defaults)
User args:     --model sonnet (filtered: --permission-mode)
Policy args:   --tools "bash,read,write,edit" --disallowedTools webfetch websearch --settings /tmp/...

Final: claude --tools "bash,read,write,edit" --disallowedTools webfetch websearch --settings /tmp/... --model sonnet

=== Enforcement Gaps ===
[WARN] paths.deny: Claude path deny rules have known edge-cases with MCP tools
[WARN] network.deny not specified; tool can still make outbound requests via bash
```

---

## Implementation Order

### P0 - Foundation (2 hours)

1. **Persona env export** - 30 min
   - Add `persona_dir` normalization
   - Export 5 env vars before launch modes

2. **Per-tool instruction files** - 30 min
   - Resolution with file-vs-dir handling
   - Fallback to AGENTS.md

3. **Temp file lifecycle** - 30 min
   - Add tracked variables
   - Add cleanup_policy() to trap

4. **Arg layering infrastructure** - 30 min
   - Split into default_args, user_args, policy_args
   - Add is_policy_controlled_flag() function

### P1 - Policy Translation (4 hours)

5. **Policy Python helpers** - 1 hr
   - policy_from_json()
   - normalize_tool_name()
   - policy_has_*() checks

6. **Codex policy translation** - 1 hr
   - codex_policy_overrides() with correct array syntax
   - sandbox_mode, writable_roots, network_access

7. **OpenCode policy translation** - 45 min
   - generate_opencode_config()
   - OPENCODE_CONFIG injection

8. **Gemini policy translation** - 45 min
   - generate_gemini_settings()
   - GEMINI_CLI_SYSTEM_SETTINGS_PATH injection

9. **Claude policy translation** - 1 hr
   - inject_claude_policy()
   - Settings JSON generation for paths
   - Flag filtering for non-bypassability

### P2 - Enforcement & Observability (2 hours)

10. **YOLO defaults suppression** - 30 min
    - Conditional injection based on policy presence

11. **User arg filtering** - 30 min
    - Filter conflicting flags when policy exists

12. **Strict-policy checks** - 30 min
    - Enforcement gap detection
    - Conditional failures

13. **print-policy command** - 30 min
    - Policy visibility for debugging

### P3 - Testing (2 hours)

14. **Smoke tests** - 2 hrs
    - Env var export verification
    - Per-tool file resolution
    - Policy flag generation per tool
    - Arg filtering
    - Strict-policy failures
    - Temp file cleanup

---

## Test Cases

### Env Export
```bash
# Verify tool receives all 5 env vars
export CAPTURE_FILE="$TEST_TMP/env.out"
cat > "$BIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
env | grep AGENT_PERSONA > "$CAPTURE_FILE"
SH
"$LAUNCHER" claude test-persona
grep -q "AGENT_PERSONA_NAME=test-persona" "$CAPTURE_FILE"
grep -q "AGENT_PERSONA_TOOL=claude" "$CAPTURE_FILE"
grep -q "AGENT_PERSONA_OVERLAY_FILE=CLAUDE.md" "$CAPTURE_FILE"
```

### Per-Tool Instruction Files
```bash
# Create tool-specific file
echo "CLAUDE SPECIFIC" > .personas/test-persona/CLAUDE.md
echo "GENERIC" > .personas/test-persona/AGENTS.md

# Verify CLAUDE.md is used
OVERLAY=$("$LAUNCHER" print-overlay claude test-persona)
[[ "$OVERLAY" == *"CLAUDE SPECIFIC"* ]]

# Verify AGENTS.md fallback for codex
OVERLAY=$("$LAUNCHER" print-overlay codex test-persona)
[[ "$OVERLAY" == *"GENERIC"* ]]
```

### Policy Translation
```bash
# Create persona with policy
cat > .personas/secure/persona.json <<'JSON'
{
  "policy": {
    "tools": {
      "allow": ["bash", "read", "edit"],
      "deny": ["webfetch"]
    }
  }
}
JSON

# Verify Claude receives correct flags
"$LAUNCHER" claude secure -- 2>&1
grep -q '\--tools.*bash.*read.*edit' "$CAPTURE_FILE"
grep -q '\--disallowedTools.*webfetch' "$CAPTURE_FILE"
```

### Arg Filtering
```bash
# User arg that conflicts with policy should be filtered
"$LAUNCHER" claude secure -- --permission-mode bypassPermissions
# Should NOT contain --permission-mode in final args
! grep -q "permission-mode" "$CAPTURE_FILE"
```

### Strict Policy
```bash
# Policy with network.deny + bash allowed
cat > .personas/strict-test/persona.json <<'JSON'
{
  "policy": {
    "tools": { "allow": ["bash", "read"] },
    "network": { "deny": ["*"] }
  }
}
JSON

# Should fail with --strict-policy
! "$LAUNCHER" claude strict-test --strict-policy 2>&1
```

---

## Migration Notes

### Backward Compatibility

- All changes additive
- No policy = current YOLO behavior preserved
- Existing persona.json files work unchanged

### Breaking Changes

None planned. However, users relying on `--permission-mode bypassPermissions` override when a policy exists will see it filtered out.

---

## Documentation Updates

1. **README.md**
   - Add `policy` schema documentation
   - Add enforcement matrix
   - Add per-tool instruction file example

2. **New: POLICY.md**
   - Detailed policy schema reference
   - Tool-specific translation details
   - Known limitations per tool

3. **Update: INSTALL.md**
   - Note about Python requirement for policy features

---

## Files Changed

| File | Changes |
|------|---------|
| `agent-persona` | +200 lines (policy translation, env export, arg layering) |
| `tests/smoke.sh` | +100 lines (new test cases) |
| `README.md` | +50 lines (policy docs) |
| `POLICY.md` | New file (~200 lines) |

---

## Appendix: Complete Arg Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                      Argument Assembly                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. default_args (from persona.json "defaults")                 │
│     └─ ["--model", "sonnet", "--verbose"]                       │
│                                                                 │
│  2. user_args (pass-through, FILTERED if policy exists)         │
│     └─ Original: ["--permission-mode", "bypass", "--timeout=60"]│
│     └─ Filtered: ["--timeout=60"]                               │
│        (--permission-mode blocked by policy)                    │
│                                                                 │
│  3. policy_args (ALWAYS LAST, enforcement)                      │
│     └─ ["--tools", "bash,read,edit",                            │
│         "--disallowedTools", "webfetch",                        │
│         "--settings", "/tmp/persona-claude-XXX.json"]           │
│                                                                 │
│  Final: tool_args = default_args + filtered_user + policy_args  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```
