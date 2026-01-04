# Agent-Persona v1.4 Implementation Plan (Final)

> Implementation-ready plan with all enforcement refinements

## Summary of Changes from v1.3

| Item | v1.3 | v1.4 (Final) |
|------|------|--------------|
| Tool name handling | normalize only | normalize + per-tool emit mapping |
| Arg filtering | Token-only | Index-aware (handles two-token flags) |
| List-valued flags | Word-split `$denied` | `mapfile` array construction |
| MCP enforcement | Schema only | Filtering at injection points |
| Codex paths | Relative notation | Materialized absolute paths |
| print-overlay | Uses AGENTS.md only | Mirrors per-tool file resolution |
| strict-policy | Global pass/fail | Per-element evaluation |
| Blocked flags | TBD for Gemini/OpenCode | Complete table |

---

## Part 1: Tool Name Mapping System

### Problem
Policy uses canonical lowercase names (`bash`, `read`), but each tool's CLI expects its own identifiers.

### Solution: Two-Phase Mapping

```python
# Phase 1: Normalize input to canonical form
TOOL_ALIASES = {
    "Bash": "bash", "bash": "bash",
    "Read": "read", "read": "read",
    "Write": "write", "write": "write",
    "Edit": "edit", "edit": "edit",
    "Glob": "glob", "glob": "glob",
    "Grep": "grep", "grep": "grep",
    "WebFetch": "webfetch", "webfetch": "webfetch",
    "WebSearch": "websearch", "websearch": "websearch",
    "Task": "task", "task": "task",
    "TodoWrite": "todowrite", "todowrite": "todowrite",
    "NotebookEdit": "notebookedit", "notebookedit": "notebookedit",
    "AskUserQuestion": "askuserquestion", "askuserquestion": "askuserquestion",
}

def normalize_tool_name(name):
    """Normalize to canonical lowercase form."""
    return TOOL_ALIASES.get(name, name.lower())

# Phase 2: Emit tool-specific identifier
CLAUDE_EMIT_MAP = {
    "bash": "Bash",
    "read": "Read",
    "write": "Write",
    "edit": "Edit",
    "glob": "Glob",
    "grep": "Grep",
    "webfetch": "WebFetch",
    "websearch": "WebSearch",
    "task": "Task",
    "todowrite": "TodoWrite",
    "notebookedit": "NotebookEdit",
    "askuserquestion": "AskUserQuestion",
}

GEMINI_EMIT_MAP = {
    "bash": "shell",        # Gemini may use different names
    "read": "read_file",
    "write": "write_file",
    "edit": "edit_file",
    # ... fill based on Gemini docs
}

OPENCODE_EMIT_MAP = {
    "bash": "bash",
    "read": "read",
    "write": "write",
    "edit": "edit",
    # ... fill based on OpenCode docs
}

def emit_tool_name(tool_family, canonical):
    """Convert canonical name to tool-specific identifier."""
    emit_map = {
        "claude": CLAUDE_EMIT_MAP,
        "gemini": GEMINI_EMIT_MAP,
        "opencode": OPENCODE_EMIT_MAP,
    }.get(tool_family, {})

    if canonical not in emit_map:
        # Return None to signal unmapped tool
        return None
    return emit_map[canonical]

def translate_tool_list(tool_family, canonical_list):
    """Translate list of canonical tools, warning on unmapped."""
    result = []
    unmapped = []
    for canon in canonical_list:
        emitted = emit_tool_name(tool_family, canon)
        if emitted is None:
            unmapped.append(canon)
        else:
            result.append(emitted)
    return result, unmapped
```

### Strict-Policy Integration

```bash
# If any tools couldn't be mapped, fail in strict mode
if [[ "$STRICT_POLICY" == "1" && ${#unmapped[@]} -gt 0 ]]; then
  die "strict-policy: cannot map tools for $tool: ${unmapped[*]}"
fi
```

---

## Part 2: Index-Aware Argument Filtering

### Problem
Two-token flags like `--permission-mode bypassPermissions` require consuming both tokens.

### Solution

```bash
# Policy-controlled flag patterns (tool-specific)
CLAUDE_CONTROLLED_FLAGS=(
  "--permission-mode"
  "--dangerously-skip-permissions"
  "--tools"
  "--allowedTools"
  "--disallowedTools"
  "--settings"
)

CODEX_CONTROLLED_PREFIXES=(
  "sandbox_mode="
  "sandbox_workspace_write."
  "features.web_search_request"
)

filter_user_args() {
  local tool="$1"
  shift
  local -a user_args=("$@")
  local -a filtered=()
  local i=0
  local n=${#user_args[@]}

  while (( i < n )); do
    local arg="${user_args[i]}"
    local skip=0
    local skip_next=0

    case "$tool" in
      claude|claude-code)
        for flag in "${CLAUDE_CONTROLLED_FLAGS[@]}"; do
          if [[ "$arg" == "$flag" ]]; then
            skip=1
            skip_next=1  # Also skip the value token
            log "filtering policy-controlled flag: $arg ${user_args[i+1]:-}"
            break
          elif [[ "$arg" == "$flag="* ]]; then
            skip=1
            log "filtering policy-controlled flag: $arg"
            break
          fi
        done
        ;;

      codex)
        if [[ "$arg" == "-c" ]]; then
          local next="${user_args[i+1]:-}"
          for prefix in "${CODEX_CONTROLLED_PREFIXES[@]}"; do
            if [[ "$next" == "$prefix"* ]]; then
              skip=1
              skip_next=1
              log "filtering policy-controlled config: -c $next"
              break
            fi
          done
        fi
        ;;

      # Gemini and OpenCode use env vars, not CLI flags for config
      # No filtering needed (see Blocked Flags Table below)
    esac

    if (( skip == 0 )); then
      filtered+=("$arg")
    fi

    (( i++ ))
    if (( skip_next == 1 && i < n )); then
      (( i++ ))  # Skip the value token too
    fi
  done

  # Output filtered array
  printf '%s\0' "${filtered[@]}"
}

# Usage in main script:
mapfile -d '' filtered_user_args < <(filter_user_args "$tool" "${pass_args[@]}")
```

---

## Part 3: Array Construction for List-Valued Flags

### Problem
Word-splitting `$denied` is fragile (globbing, IFS, empty tokens).

### Solution

```bash
# Python outputs newline-delimited tokens
policy_tools_deny() {
  local json_path="$1" tool_family="$2"
  python3 - "$json_path" "$tool_family" <<'PY'
import json, sys
# ... load policy, translate tool names ...
for tool in denied_tools:
    emitted = emit_tool_name(tool_family, tool)
    if emitted:
        print(emitted)
PY
}

# Bash reads into array safely
inject_claude_policy() {
  local policy_json="$1"

  # tools.allow → --tools (comma-separated)
  local -a allowed_arr
  mapfile -t allowed_arr < <(policy_tools_allow "$policy_json" "claude")
  if (( ${#allowed_arr[@]} > 0 )); then
    local allowed_csv
    allowed_csv=$(IFS=','; echo "${allowed_arr[*]}")
    policy_args+=(--tools "$allowed_csv")
  fi

  # tools.deny → --disallowedTools (separate arguments)
  local -a denied_arr
  mapfile -t denied_arr < <(policy_tools_deny "$policy_json" "claude")
  if (( ${#denied_arr[@]} > 0 )); then
    policy_args+=(--disallowedTools "${denied_arr[@]}")
  fi
}
```

### Note on Claude's Flag Format

Confirmed via testing: `--disallowedTools` accepts multiple arguments:
```bash
claude --disallowedTools WebFetch WebSearch Task
```
This is equivalent to repeating the flag, but cleaner.

---

## Part 4: MCP Allow/Deny Enforcement at Injection Points

### Problem
MCP servers defined in `persona.json` could bypass policy restrictions.

### Solution
Filter MCP servers in existing extraction functions based on `policy.mcpServers`.

```python
def extract_mcp_config_with_policy(json_path, policy):
    """Extract MCP config, filtered by policy."""
    with open(json_path) as f:
        j = json.load(f)

    mcp_servers = get_mcp_servers(j)
    if not mcp_servers:
        return None

    # Apply policy filtering
    mcp_policy = policy.get("mcpServers", {})
    allowed = set(mcp_policy.get("allow", []))
    denied = set(mcp_policy.get("deny", []))

    filtered = {}
    for name, cfg in mcp_servers.items():
        # If allow list exists, server must be in it
        if allowed and name not in allowed:
            log(f"MCP server '{name}' not in policy allow list, skipping")
            continue
        # If in deny list, skip
        if name in denied:
            log(f"MCP server '{name}' in policy deny list, skipping")
            continue
        filtered[name] = cfg

    if not filtered:
        return None

    # Write filtered config
    config = {"mcpServers": filtered}
    fd, tmp_path = tempfile.mkstemp(prefix="persona-mcp-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(config, f)
    return tmp_path


def codex_mcp_overrides_with_policy(json_path, policy):
    """Generate Codex MCP overrides, filtered by policy."""
    # Same filtering logic as above
    # Only emit -c mcp_servers.* for allowed servers
```

### Injection Point Changes

```bash
# Line ~1046: Claude MCP injection
if [[ "$MCP_ENABLED" != "0" && -n "$json_cfg" ]]; then
  if [[ -n "$policy_json" ]]; then
    mcp_config_file="$(extract_mcp_config_with_policy "$json_cfg" "$policy_json")"
  else
    mcp_config_file="$(extract_mcp_config "$json_cfg")"
  fi
  # ... rest unchanged
fi

# Line ~1039: Codex MCP injection
if [[ "$MCP_ENABLED" != "0" && -n "$json_cfg" && "$tool" == "codex" ]]; then
  if [[ -n "$policy_json" ]]; then
    while IFS= read -r ov; do
      [[ -n "$ov" ]] || continue
      defaults+=( -c "$ov" )
    done < <(codex_mcp_overrides_with_policy "$json_cfg" "$policy_json")
  else
    # ... existing logic
  fi
fi
```

### Policy Disables MCP Entirely

```bash
# If policy explicitly denies all MCP (deny: ["*"])
if policy_denies_all_mcp "$policy_json"; then
  MCP_ENABLED="0"
  log "policy denies all MCP servers"
fi
```

---

## Part 5: Codex Path Normalization

### Problem
Relative paths like `./` need to be absolute for consistent sandbox behavior.

### Solution

```python
def normalize_codex_paths(paths, repo_root):
    """Convert policy paths to absolute paths for Codex sandbox."""
    result = []
    for p in paths:
        if p.startswith("./"):
            # Relative to repo root
            abs_path = os.path.normpath(os.path.join(repo_root, p[2:]))
            result.append(abs_path)
        elif p.startswith("~/"):
            # Home-relative
            abs_path = os.path.expanduser(p)
            result.append(abs_path)
        elif p.startswith("/"):
            # Already absolute
            result.append(p)
        else:
            # Treat as repo-relative
            abs_path = os.path.normpath(os.path.join(repo_root, p))
            result.append(abs_path)
    return result


def codex_policy_overrides(policy, repo_root):
    """Generate Codex sandbox overrides with normalized paths."""
    overrides = []

    if policy.get("paths", {}).get("allow"):
        overrides.append('sandbox_mode="workspace-write"')

        # Normalize paths to absolute
        raw_paths = policy["paths"]["allow"]
        abs_paths = normalize_codex_paths(raw_paths, repo_root)
        roots_json = json.dumps(abs_paths)
        overrides.append(f'sandbox_workspace_write.writable_roots={roots_json}')

    # ... rest unchanged
    return overrides
```

### Glob Pattern Handling

```python
def normalize_codex_paths(paths, repo_root):
    """..."""
    for p in paths:
        # Check for glob patterns
        if '*' in p or '?' in p:
            # Codex writable_roots doesn't support globs
            # In strict mode, this should fail
            raise PolicyError(f"Codex writable_roots does not support glob patterns: {p}")
        # ... rest of normalization
```

---

## Part 6: Update print-overlay for Per-Tool Files

### Current Issue
`cmd_print_overlay` always uses `AGENTS.md`, ignoring tool-specific files.

### Fix

```bash
cmd_print_overlay() {
  # ... existing arg parsing ...

  # Determine overlay filename (same logic as main launch)
  local overlay_name="AGENTS.md"
  case "$tool" in
    claude|claude-code) overlay_name="CLAUDE.md" ;;
    gemini) overlay_name="GEMINI.md" ;;
  esac

  # ... existing persona resolution ...

  # NEW: Check for tool-specific instruction file
  local persona_dir
  if [[ -f "$persona_src" ]]; then
    persona_dir="$(dirname -- "$persona_src")"
  else
    persona_dir="$persona_src"
  fi

  local tool_specific_file="$persona_dir/$overlay_name"
  local instruction_file
  if [[ -f "$tool_specific_file" && "$overlay_name" != "AGENTS.md" ]]; then
    instruction_file="$tool_specific_file"
    echo "# Using tool-specific: $overlay_name"
  else
    instruction_file="$persona_dir/AGENTS.md"
    echo "# Using default: AGENTS.md"
  fi

  # ... rest of print logic uses $instruction_file ...
}
```

---

## Part 7: Per-Element Strict-Policy Evaluation

### Problem
Global pass/fail doesn't tell you *which* policy element failed.

### Solution

```bash
check_strict_policy() {
  local tool="$1" policy_json="$2"
  local -a failures=()
  local -a warnings=()

  # Check each policy element

  # 1. tools.allow
  if policy_has_tools_allow "$policy_json"; then
    local -a unmapped
    mapfile -t unmapped < <(get_unmapped_tools "$policy_json" "$tool" "allow")
    if (( ${#unmapped[@]} > 0 )); then
      failures+=("tools.allow: cannot map for $tool: ${unmapped[*]}")
    fi
  fi

  # 2. tools.deny
  if policy_has_tools_deny "$policy_json"; then
    local -a unmapped
    mapfile -t unmapped < <(get_unmapped_tools "$policy_json" "$tool" "deny")
    if (( ${#unmapped[@]} > 0 )); then
      failures+=("tools.deny: cannot map for $tool: ${unmapped[*]}")
    fi

    # Claude-specific: warn about MCP edge cases
    if [[ "$tool" == "claude" || "$tool" == "claude-code" ]]; then
      warnings+=("tools.deny: Claude has known edge-cases with MCP tools (see #12863)")
    fi
  fi

  # 3. paths.allow
  if policy_has_paths_allow "$policy_json"; then
    case "$tool" in
      gemini)
        failures+=("paths.allow: Gemini does not support path restrictions")
        ;;
      codex)
        # Check for unsupported globs
        if policy_paths_have_globs "$policy_json" "allow"; then
          failures+=("paths.allow: Codex writable_roots does not support glob patterns")
        fi
        ;;
    esac
  fi

  # 4. paths.deny
  if policy_has_paths_deny "$policy_json"; then
    case "$tool" in
      gemini)
        failures+=("paths.deny: Gemini does not support path restrictions")
        ;;
      codex)
        failures+=("paths.deny: Codex sandbox does not support deny-only paths")
        ;;
    esac
  fi

  # 5. network.deny
  if policy_has_network_deny "$policy_json"; then
    if policy_allows_bash "$policy_json"; then
      case "$tool" in
        claude|claude-code)
          failures+=("network.deny: Claude cannot enforce when bash allowed (shell can curl/wget)")
          ;;
        gemini|opencode)
          warnings+=("network.deny: only blocks web tools, not shell network access")
          ;;
        codex)
          # Codex sandbox can actually enforce this
          ;;
      esac
    fi
  fi

  # 6. mcpServers restrictions
  if policy_has_mcp_restrictions "$policy_json"; then
    case "$tool" in
      codex)
        warnings+=("mcpServers: Codex MCP support is limited")
        ;;
    esac
  fi

  # Report results
  if (( ${#warnings[@]} > 0 )); then
    for w in "${warnings[@]}"; do
      warn "strict-policy: $w"
    done
  fi

  if (( ${#failures[@]} > 0 )); then
    for f in "${failures[@]}"; do
      echo "[FAIL] $f" >&2
    done
    die "strict-policy: ${#failures[@]} enforcement failure(s)"
  fi
}
```

---

## Part 8: Complete Blocked Flags Table

### Claude

| Flag Pattern | Blocked When | Reason |
|--------------|--------------|--------|
| `--permission-mode` | policy exists | Policy controls permission model |
| `--permission-mode=*` | policy exists | Policy controls permission model |
| `--dangerously-skip-permissions` | policy exists | Bypasses all restrictions |
| `--tools` | policy.tools exists | Policy defines tool set |
| `--tools=*` | policy.tools exists | Policy defines tool set |
| `--allowedTools` | policy.tools exists | Policy defines approvals |
| `--disallowedTools` | policy.tools exists | Policy defines denials |
| `--settings` | policy.paths exists | Policy generates settings |
| `--settings=*` | policy.paths exists | Policy generates settings |

### Codex

| Flag Pattern | Blocked When | Reason |
|--------------|--------------|--------|
| `-c sandbox_mode=*` | policy.paths exists | Policy controls sandbox mode |
| `-c sandbox_workspace_write.*` | policy.paths exists | Policy controls sandbox config |
| `-c features.web_search_request=*` | policy.tools.deny has websearch | Policy controls web access |
| `--dangerously-bypass-approvals-and-sandbox` | policy exists | Bypasses all restrictions |
| `--yolo` | policy exists | Alias for dangerous bypass |

### Gemini

| Flag Pattern | Blocked When | Reason |
|--------------|--------------|--------|
| **None** | - | Gemini uses `GEMINI_CLI_SYSTEM_SETTINGS_PATH` env var, not CLI flags |

**Enforcement note**: Gemini policy is enforced via generated settings file. There is no known CLI flag to override the settings path. If user sets `GEMINI_CLI_SYSTEM_SETTINGS_PATH` manually, it will be overwritten by policy injection.

### OpenCode

| Flag Pattern | Blocked When | Reason |
|--------------|--------------|--------|
| **None** | - | OpenCode uses `OPENCODE_CONFIG` env var, not CLI flags |

**Enforcement note**: OpenCode policy is enforced via generated config file. There is no known CLI flag to override the config path. If user sets `OPENCODE_CONFIG` manually, it will be overwritten by policy injection.

---

## Part 9: Test Shim Pattern

### Consistent argv Capture

```bash
# Create test tool shim that captures argv and env
create_capture_shim() {
  local shim_name="$1"
  local shim_path="$BIN_DIR/$shim_name"

  cat > "$shim_path" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${CAPTURE_FILE:?CAPTURE_FILE must be set}"

# Capture argv
{
  echo "=== ARGV ==="
  printf '%s\n' "$0" "$@"
  echo ""
  echo "=== ENV ==="
  env | grep -E '^AGENT_PERSONA_' | sort
  echo ""
  echo "=== SETTINGS FILES ==="
  for arg in "$@"; do
    if [[ "$arg" == *.json && -f "$arg" ]]; then
      echo "--- $arg ---"
      cat "$arg"
    fi
  done
} > "$CAPTURE_FILE"
SHIM

  chmod +x "$shim_path"
}

# Usage in tests
create_capture_shim "claude"
create_capture_shim "codex"
create_capture_shim "gemini"
create_capture_shim "opencode"
```

### Test Assertions

```bash
# Assert flag present
assert_has_flag() {
  local flag="$1"
  grep -qF "$flag" "$CAPTURE_FILE" || fail "expected flag: $flag"
}

# Assert flag absent
assert_no_flag() {
  local flag="$1"
  ! grep -qF "$flag" "$CAPTURE_FILE" || fail "unexpected flag: $flag"
}

# Assert env var
assert_env() {
  local var="$1" expected="$2"
  grep -qF "$var=$expected" "$CAPTURE_FILE" || fail "expected env: $var=$expected"
}
```

---

## Implementation Checklist

### P0 - Foundation (2.5 hours)

- [ ] Add `persona_dir` normalization (handles file-vs-dir)
- [ ] Export 5 persona env vars (single location)
- [ ] Implement per-tool instruction file resolution
- [ ] Update `cmd_print_overlay` to mirror resolution
- [ ] Add temp file lifecycle tracking (`cleanup_policy`)
- [ ] Create 3-way arg layering structure

### P1 - Policy Core (4 hours)

- [ ] Implement `normalize_tool_name()` function
- [ ] Implement per-tool `emit_tool_name()` mappings
- [ ] Implement `translate_tool_list()` with unmapped warnings
- [ ] Implement index-aware `filter_user_args()`
- [ ] Implement `mapfile`-based array construction for flags

### P2 - Tool Translation (4 hours)

- [ ] Claude: `inject_claude_policy()` with settings JSON generation
- [ ] Codex: `codex_policy_overrides()` with path normalization
- [ ] Gemini: `generate_gemini_settings()` with emit mapping
- [ ] OpenCode: `generate_opencode_config()` with emit mapping
- [ ] MCP: Add policy filtering to extraction functions

### P3 - Enforcement (2 hours)

- [ ] Implement `policy_exists_in_json()` check
- [ ] Implement YOLO defaults suppression
- [ ] Implement per-element `check_strict_policy()`
- [ ] Implement `print-policy` command

### P4 - Testing (2 hours)

- [ ] Create capture shim pattern
- [ ] Test env var export
- [ ] Test per-tool file resolution
- [ ] Test policy flag generation (all 4 tools)
- [ ] Test arg filtering
- [ ] Test strict-policy failures
- [ ] Test MCP filtering
- [ ] Test temp file cleanup

**Total: ~14.5 hours**

---

## File Changes Summary

| File | Lines Changed | Description |
|------|---------------|-------------|
| `agent-persona` | +350 | Policy system, arg filtering, env export |
| `tests/smoke.sh` | +150 | New test cases |
| `README.md` | +80 | Policy documentation |
| `POLICY.md` | New (~300) | Detailed policy reference |

---

## Appendix: Complete Policy Schema

```jsonc
{
  // Existing fields (unchanged)
  "defaults": {
    "*": ["--verbose"],
    "claude": ["--model", "sonnet"],
    "codex": []
  },

  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-filesystem"]
    }
  },

  // NEW: Policy block
  "policy": {
    // Tool restrictions (canonical lowercase names)
    "tools": {
      "allow": ["bash", "read", "write", "edit", "glob", "grep"],
      "deny": ["webfetch", "websearch", "task"]
    },

    // Path restrictions (repo-root-relative or absolute)
    "paths": {
      "allow": ["./", "/tmp"],
      "deny": ["~/.ssh", "~/.gnupg", "~/.aws", "./secrets/**"]
    },

    // Network restrictions
    "network": {
      "deny": ["*"]  // "*" = deny all outbound
    },

    // MCP server restrictions
    "mcpServers": {
      "allow": ["filesystem", "git"],
      "deny": ["dangerous-server"]
    },

    // Bash command restrictions (pattern-based)
    "bash": {
      "allow": ["git:*", "npm:*", "cargo:*", "make:*"],
      "deny": ["curl:*", "wget:*", "nc:*", "ssh:*", "scp:*"]
    }
  }
}
```

---

## Appendix: Enforcement Capability Matrix (Final)

| Policy Element | Codex | OpenCode | Gemini | Claude |
|----------------|-------|----------|--------|--------|
| tools.allow | Weak | **Strong** | **Strong** | **Strong** |
| tools.deny | Weak | **Strong** | **Strong** | Partial* |
| paths.allow (write) | **Strong** | Partial | None | Partial |
| paths.deny | None | Partial | None | Partial |
| network.deny (full) | **Strong** | Weak | Weak | Weak |
| network.deny (web tools only) | **Strong** | **Strong** | **Strong** | **Strong** |
| mcpServers.allow/deny | N/A | Partial | **Strong** | Partial |
| bash.allow/deny | Partial | Partial | N/A | Partial |

*Claude has known edge-cases with MCP tools and --disallowedTools

**Legend:**
- **Strong**: Enforced at sandbox/config level
- **Partial**: Enforced but with known gaps
- **Weak**: Best-effort only
- **None**: Cannot enforce

---

## Appendix: Pre-Implementation Sanity Checks

### 1. Bash Compatibility Stance

**Decision required**: `mapfile` requires Bash 4+.

**Options:**
- **Option A (Recommended)**: Require Bash ≥ 4 in docs + `doctor` check, keep `mapfile`
- **Option B**: Replace `mapfile` with `while IFS= read -r` loops for Bash 3.2 compatibility

**Implementation for Option A:**
```bash
# Add to doctor command (~line 365)
bash_version="${BASH_VERSINFO[0]}"
if (( bash_version < 4 )); then
  echo "[!!] Bash $BASH_VERSION detected; policy features require Bash 4+"
  issues=$((issues + 1))
else
  echo "[ok] Bash $BASH_VERSION (policy features supported)"
fi
```

### 2. Python Required for Policy Enforcement

**Rule**: If `persona.json` contains `policy` key AND Python unavailable → **hard error**.

```bash
policy_requires_python() {
  local json_path="$1"
  # Quick grep check - doesn't need Python
  grep -qE '"policy"\s*:' "$json_path" 2>/dev/null
}

# In main script, after json_cfg is found:
if [[ -n "$json_cfg" ]] && policy_requires_python "$json_cfg"; then
  if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    die "policy defined in persona.json but Python not available (required for enforcement)"
  fi
fi
```

### 3. Emit Maps Fail-Loud Under Strict-Policy

Already covered in v1.4 `check_strict_policy()`, but ensure implementation:

```bash
# Non-strict: warn and skip unmapped tools
if (( ${#unmapped[@]} > 0 )); then
  warn "cannot map tools for $tool: ${unmapped[*]} (skipping)"
fi

# Strict: fail with per-element message
if [[ "$STRICT_POLICY" == "1" && ${#unmapped[@]} -gt 0 ]]; then
  die "strict-policy: tools.allow: cannot map for $tool: ${unmapped[*]}"
fi
```

### 4. Handle Both Split and Combined Flag Forms

Ensure filter covers all forms:

```bash
# Pattern: --flag value (split)
if [[ "$arg" == "--permission-mode" ]]; then
  skip=1; skip_next=1
fi

# Pattern: --flag=value (combined)
if [[ "$arg" == "--permission-mode="* ]]; then
  skip=1
fi

# Codex: -c key=value (always split in our usage)
if [[ "$arg" == "-c" ]]; then
  # Check next token
fi
```

### 5. Factor Resolution Logic (DRY)

Create shared function for instruction file resolution:

```bash
# Shared resolution function
resolve_instruction_file() {
  local persona_dir="$1" overlay_name="$2"

  local tool_specific="$persona_dir/$overlay_name"
  if [[ -f "$tool_specific" && "$overlay_name" != "AGENTS.md" ]]; then
    echo "$tool_specific"
  else
    echo "$persona_dir/AGENTS.md"
  fi
}

# Used in main launch path:
link_target="$(resolve_instruction_file "$persona_dir" "$overlay_name")"

# Used in cmd_print_overlay:
instruction_file="$(resolve_instruction_file "$persona_dir" "$overlay_name")"
```

---

## Appendix: Surgical Implementation Mapping

Where v1.4 changes slot into existing code structure:

| Change | Location | Notes |
|--------|----------|-------|
| Temp file tracking | After line 68 | Add `claude_settings_file`, etc. |
| `cleanup_policy()` | After line 69 | New cleanup function |
| `cleanup_session` update | Line 107 | Add `cleanup_policy` call |
| `persona_dir` normalization | After line 980 | Single computation, reuse everywhere |
| Overlay name determination | Move before line 984 | Earlier, before instruction file resolution |
| `has_policy` detection | After line 1002 | Before YOLO defaults injection |
| YOLO defaults suppression | Lines 1021-1034 | Conditional on `has_policy` |
| 3-way arg layering | Line 1135 | Replace single-line assembly |
| `filter_user_args()` | New function ~line 270 | Index-aware filtering |
| Policy translation | After MCP injection ~line 1058 | New `inject_*_policy()` calls |
| MCP policy filtering | Lines 170, 202 | Modify existing helpers |
| Env var export | After line 1065 | Before launch mode selection |

---

## Final Implementation Order (Revised)

Based on surgical mapping, optimal order:

1. **Foundation** (safe, no behavior change)
   - Add temp file tracking + cleanup
   - Add `persona_dir` normalization
   - Move overlay_name earlier
   - Add `resolve_instruction_file()` helper
   - Update `cmd_print_overlay` to use helper

2. **Env Export** (additive, no behavior change)
   - Export 5 env vars before launch modes
   - Test with capture shim

3. **Policy Detection** (additive)
   - Add `policy_requires_python()` check
   - Add `has_policy` detection
   - Add YOLO defaults suppression

4. **Arg Layering** (behavior change - policy enforcement begins)
   - Split into 3 arg arrays
   - Add `filter_user_args()`
   - Implement blocked flags filtering

5. **Tool Translation** (feature complete)
   - Claude, Codex, Gemini, OpenCode translators
   - MCP policy filtering at injection points

6. **Strict-Policy** (polish)
   - Per-element evaluation
   - `print-policy` command
