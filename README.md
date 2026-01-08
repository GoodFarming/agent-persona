# agent-persona

**Switch AI agent behaviors instantly. Apply persona defaults and policies (strict enforcement optional).**

Define reusable instruction profiles for AI coding agents. Share them across repos, switch personas on the fly, and lock down what agents can do. Works with Claude, Codex, Gemini, and OpenCode.

## Why Use This?

| Problem | Solution |
|---------|----------|
| Different tasks need different agent instructions | Swap personas instantly without editing files |
| `AGENTS.md` changes clutter git history | Overlay system leaves no on-disk changes (Linux) |
| Need safe defaults but occasional overrides | Policy applies by default; CLI args can override (use `--strict-policy` to enforce) |
| MCP servers configured per-project | Portable MCP definitions in `persona.json` |
| Team conventions scattered across repos | Shared personas and includes for consistency |

## Quick Start

```bash
# Install
git clone https://github.com/GoodFarming/agent-persona.git
cd agent-persona && ./install.sh

# Launch Claude with the "blank" persona
agent-persona claude blank

# See what personas are available
agent-persona --list

# Check everything is working
agent-persona doctor
```

## Core Concepts

### What's a Persona?

A persona is a folder containing instructions (and optional config) for an AI agent:

```
.personas/
  my-persona/
    AGENTS.md       # Instructions the agent sees (required)
    CLAUDE.md       # Claude-specific instructions (optional)
    GEMINI.md       # Gemini-specific instructions (optional)
    persona.json    # Defaults, MCP servers, policy (optional)
```

When you run `agent-persona claude my-persona`, the launcher:
1. Finds your persona
2. Overlays the instructions onto the target file (`CLAUDE.md`)
3. Injects any MCP servers and defaults
4. Launches Claude with everything configured

### How the Overlay Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         agent-persona                           │
├─────────────────────────────────────────────────────────────────┤
│  1. Find persona (repo → home → system)                         │
│  2. Merge repo-wide meta instructions                           │
│  3. Expand include directives                                   │
│  4. Inject MCP servers from persona.json                        │
│  5. Translate policy to tool-specific flags                     │
│  6. If `--strict-policy`, filter user args that conflict        │
│  7. Overlay composed file onto working directory                │
│  8. Launch tool with: defaults + policy + user_args             │
└─────────────────────────────────────────────────────────────────┘
```

- Normal mode: user args override policy.
- Strict mode (`--strict-policy`): policy overrides user args.

**On Linux**: Uses bind-mount via `unshare` — your actual `AGENTS.md` is never modified.

**Elsewhere**: Swaps the file, runs the tool, restores on exit. If a crash occurs, run `agent-persona recover`.

---

## Creating Personas

### Option 1: Repo-Local Personas

Best for project-specific instructions that travel with your repo:

```bash
cd your-project
agent-persona init                     # Creates .personas/ scaffold
mkdir .personas/dev
cat > .personas/dev/AGENTS.md << 'EOF'
# Development Persona

You are helping with active development on this project.

## Guidelines
- Write tests for new functionality
- Keep changes focused and minimal
- Explain trade-offs when relevant
EOF
```

### Option 2: Global Personas

Best for personal preferences that apply everywhere:

```bash
mkdir -p ~/.personas/reviewer
cat > ~/.personas/reviewer/AGENTS.md << 'EOF'
# Code Reviewer

Focus on code quality, security, and best practices.
Be thorough but constructive.
EOF
```

### Adding Tool-Specific Instructions

Claude and Gemini can have their own instruction files:

```
.personas/my-persona/
  AGENTS.md    # Default (used by Codex, OpenCode)
  CLAUDE.md    # Used by Claude (if present)
  GEMINI.md    # Used by Gemini (if present)
```

---

## The Policy System

Policies define baseline constraints in `persona.json` (tools/paths/network) that `agent-persona` translates into tool-specific flags/config.

By default, **user tool flags override policy**. This lets you keep safe defaults in `persona.json`, while still allowing power users to push boundaries for a single run (for example, `--yolo` on Codex).

To enforce policies (non-overridable), run with `--strict-policy` (or `AGENT_PERSONA_STRICT_POLICY=1`).

### Defining a Policy

Add a `policy` block to `persona.json`:

```json
{
  "policy": {
    "tools": {
      "allow": ["bash", "read", "edit", "write", "glob", "grep"],
      "deny": ["webfetch", "websearch", "task"]
    },
    "paths": {
      "allow": ["./src", "./tests", "/tmp"],
      "deny": [".env", "credentials.json", "~/.ssh/**"]
    },
    "network": {
      "deny": ["*"]
    }
  }
}
```

### Precedence Rules

- Normal mode (default): `defaults` → `policy` → user tool args
- Strict mode (`--strict-policy`): `defaults` → user tool args (filtered) → `policy`
- Auto-bypass defaults (`codex --full-auto`, `claude --permission-mode bypassPermissions`) are suppressed when a policy exists; pass them explicitly if you want them.

### Policy-Controlled Overrides (Strict Mode)

When `--strict-policy` is used, these user tool flags are ignored/filtered so policy can’t be overridden:

| Tool | User Tool Flags Controlled by `--strict-policy` |
|------|----------------------------------|
| **Claude** | `--permission-mode`, `--tools`, `--allowedTools`, `--disallowedTools`, `--settings`, `--dangerously-skip-permissions` |
| **Codex** | `--full-auto`, `--yolo`, `--dangerously-bypass-*`, `-c sandbox_mode=*`, `-c sandbox_workspace_write.*` |
| **Gemini** | Strict mode forces `GEMINI_CLI_SYSTEM_SETTINGS_PATH` to the generated settings file |
| **OpenCode** | Strict mode forces `OPENCODE_CONFIG` to the generated config file |

### Previewing Policy Translation

See exactly how your policy will be translated:

```bash
agent-persona print-policy claude my-persona
agent-persona print-policy codex my-persona
```

### Strict Mode

Enforce policy and fail if it can't be reliably enforced:

```bash
agent-persona claude my-persona --strict-policy
```

This catches issues like:
- Using `network.deny` while `bash` is allowed (shell can `curl`/`wget`)
- Using `paths.deny` with Codex (not supported)
- Using `paths` restrictions with Gemini (not supported)

### Enforcement Capability Matrix (Strict Mode)

| Policy Element | Codex | Claude | Gemini | OpenCode |
|----------------|-------|--------|--------|----------|
| tools.allow | — | **Strong** | **Strong** | **Strong** |
| tools.deny | Partial (websearch only) | **Strong** | **Strong** | **Strong** |
| paths.allow | **Strong** | — | None | — |
| paths.deny | None | Partial (Claude settings) | None | — |
| network.deny (`"*"`) | **Strong** | None | None | None |

**Legend**: **Strong** = sandbox/config enforced, **Partial** = has known gaps, **None** = not supported, **—** = not implemented

**Notes**:
- **Codex tools.deny**: only `websearch` is translated today (`features.web_search_request=false`).
- **No-network on non-Codex tools**: deny network-capable tools (e.g., `websearch`/`webfetch`) and deny `bash` if you need “no network” guarantees.
- **Claude paths.deny**: Partial via `--settings` deny rules; has edge-cases with MCP tools
- **Non-Codex network.deny**: No sandbox-level network isolation exists; see Hardening Guidance below

### Hardening Guidance

**For "no network access" on Claude, Gemini, or OpenCode:**

These tools lack OS-level network sandboxing. To achieve network isolation:

1. **Deny bash AND deny web tools** — prevents `curl`/`wget` in shell and blocks `webfetch`/`websearch`:
   ```json
   {
     "policy": {
       "tools": {
         "deny": ["bash", "webfetch", "websearch"]
       }
     }
   }
   ```

2. **Or run inside an external network sandbox** (container, VM, network namespace)

3. **Use `--strict-policy`** to fail fast when guarantees aren't possible:
   ```bash
   agent-persona claude my-persona --strict-policy
   ```
   This fails if `network.deny: ["*"]` is set but `bash` is allowed.

**Bash command restrictions are not reliably enforceable.** Once `bash` is in `tools.allow`, the agent can run arbitrary shell commands. There is no cross-tool mechanism to restrict specific commands (e.g., `git clean`). If you need command-level control, deny `bash` entirely or use an OS-level sandbox.

**Use Codex for strongest isolation.** Codex's sandbox mode provides actual OS-level path and network restrictions that other tools cannot match.

---

## Includes and Composition

### Shared Snippets

Create reusable blocks in `.personas/.shared/`:

```bash
# .personas/.shared/security-rules.md
## Security Requirements
- Never expose credentials
- Validate all user input
- Use parameterized queries
```

Include them in any persona:

```markdown
# My Persona

<!-- include {"file":"security-rules.md"} -->

## Additional Guidelines
...
```

### Template Variables

Use `{{persona}}` in shared blocks or meta files to reference the current persona name:

```markdown
# .personas/.shared/planning-rules.md

## Planning
Save your plans to `.persona/{{persona}}/PLAN.md`.
Update `.persona/{{persona}}/SPEC.md` with requirements.
```

When expanded for persona `dev-agent`, this becomes:

```markdown
## Planning
Save your plans to `.persona/dev-agent/PLAN.md`.
Update `.persona/dev-agent/SPEC.md` with requirements.
```

Unrecognized `{{...}}` patterns emit a warning but don't block execution.

### Inheriting from Other Personas

```markdown
# Extended Persona

<!-- include {"persona":"base-persona"} -->

## My Additions
...
```

### Composing Policy Fragments

`persona.json` supports includes too:

```json
{
  "include": [
    { "file": "policy-base.json" },
    { "persona": "secure-base" }
  ],
  "policy": {
    "tools": {
      "deny": ["task"]
    }
  }
}
```

Includes merge additively. Conflicts (e.g., same tool in both allow and deny) cause errors.

---

## Repo-Wide Meta Instructions

Add context that applies to **all** personas in a repo:

```bash
# .personas/.shared/meta.AGENTS.md

## Project Context
This is a TypeScript monorepo using pnpm workspaces.

## Conventions
- Use vitest for tests
- Run `pnpm lint` before committing

## Off-Limits
- Don't modify `packages/legacy/`
```

Meta is merged at the top of every persona (or bottom with `--meta-position=bottom`).

The template created by `agent-persona init` is **ignored until you edit it**.

---

## MCP Server Injection

Define MCP servers in `persona.json` and they're automatically configured:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-filesystem"],
      "env": { "ALLOWED_PATHS": "/home/user/projects" }
    },
    "database": {
      "command": "mcp-postgres",
      "args": ["--connection-string", "postgres://..."]
    }
  }
}
```

- **Claude**: Generates temp `--mcp-config` JSON file
- **Codex**: Emits `-c mcp_servers.*=...` overrides
- Disable with `--no-mcp` or `AGENT_PERSONA_MCP=0`

---

## Defaults and Overrides

### Per-Tool Defaults

```json
{
  "defaults": {
    "*": ["--verbose"],
    "codex": ["--model", "o3"],
    "claude": ["--model", "sonnet"]
  }
}
```

Global defaults (`*`) apply first; tool-specific defaults append after.

### Built-in Defaults

Unless policy exists, agent-persona adds sensible defaults:
- **Codex**: `--full-auto` (auto-approve safe operations)
- **Claude**: `--permission-mode bypassPermissions` (skip prompts)

These are suppressed when a policy exists (policy controls permissions).

### User Args Always Win

```bash
# persona.json: "claude": ["--model", "opus"]
agent-persona claude my-persona --model sonnet
# Result: only --model sonnet is passed
```

### Disabling Defaults

```bash
agent-persona claude my-persona --no-defaults
```

---

## Persona Discovery

Resolution order (first match wins):

1. **Repo-local**: `.personas/<name>/` in current directory or parent directories
2. **Extra paths**: `AGENT_PERSONA_PATHS` environment variable (colon-separated)
3. **Home**: `~/.personas/<name>/`
4. **User**: `~/.local/share/agent-persona/.personas/<name>/`
5. **System**: `/usr/local/share/agent-persona/.personas/<name>/`

```bash
agent-persona which my-persona  # Show where persona resolves from
```

Set `AGENT_PERSONA_PREFER_REPO=0` to check home/user before repo.

---

## Commands

| Command | Description |
|---------|-------------|
| `agent-persona <tool> <persona>` | Launch tool with persona |
| `agent-persona init` | Scaffold `.personas/` in current repo |
| `agent-persona doctor` | Verify installation and check for issues |
| `agent-persona recover` | Restore files after hard-kill (swap mode) |
| `agent-persona which <persona>` | Show where persona resolves from |
| `agent-persona print-overlay <tool> <persona>` | Preview composed instructions |
| `agent-persona print-policy <tool> <persona>` | Show policy translation summary |
| `agent-persona --list` | List all available personas |

### Tool Shims

Symlinks let you skip specifying the tool:

```bash
claude-persona my-agent    # same as: agent-persona claude my-agent
codex-persona my-agent
gemini-persona my-agent
opencode-persona my-agent
```

---

## Flags

| Flag | Description |
|------|-------------|
| `--no-meta` | Skip repo meta merge |
| `--no-mcp` | Skip MCP injection |
| `--no-defaults` | Skip all defaults |
| `--meta-file=<path>` | Override meta file location |
| `--meta-position=top\|bottom` | Where to merge meta (default: top) |
| `--force-swap` | Force swap-and-restore (skip bind-mount) |
| `--strict-policy` | Fail if policy cannot be reliably enforced |
| `--version` | Show version |
| `-h, --help` | Show help |

---

## Environment Variables

### Input (Configure agent-persona)

| Variable | Description | Default |
|----------|-------------|---------|
| `AGENT_PERSONA_DEBUG` | Enable debug logging | off |
| `AGENT_PERSONA_META` | Enable meta merge | `1` |
| `AGENT_PERSONA_MCP` | Enable MCP injection | `1` |
| `AGENT_PERSONA_DEFAULTS` | Enable persona/tool defaults | `1` |
| `AGENT_PERSONA_STRICT_POLICY` | Fail on unenforced policy | `0` |
| `AGENT_PERSONA_FORCE_SWAP` | Force swap mode | `0` |
| `AGENT_PERSONA_PATHS` | Extra search paths (colon-separated) | empty |
| `AGENT_PERSONA_HOME` | User persona directory | `~/.local/share/agent-persona` |
| `AGENT_PERSONA_PREFER_REPO` | Prefer repo-local personas | `1` |
| `AGENT_PERSONA_INCLUDE_DEPTH` | Max include recursion depth | `10` |
| `AGENT_PERSONA_GEMINI_DISABLE_IDE` | Disable Gemini IDE mode | `0` |
| `AGENT_PERSONA_GEMINI_FORCE_TTY` | Force pseudo-TTY for Gemini | `auto` |

### Output (Exported to Tool Process)

Useful for hooks, scripts, memory, and logging:

| Variable | Description | Example |
|----------|-------------|---------|
| `AGENT_PERSONA_NAME` | Persona slug | `code-reviewer` |
| `AGENT_PERSONA_PATH` | Resolved persona directory | `/home/user/.personas/code-reviewer` |
| `AGENT_PERSONA_TOOL` | Tool being launched | `claude` |
| `AGENT_PERSONA_OVERLAY_FILE` | Target overlay file | `CLAUDE.md` |
| `AGENT_PERSONA_RUN_MODE` | Launch mode | `unshare` or `swap` |

---

## Use Cases

### Task-Specific Agents

```bash
agent-persona claude researcher  # Deep research, thorough exploration
agent-persona codex fixer        # Quick fixes, minimal changes
agent-persona claude reviewer    # Code review, security focus
```

### Secure Sandboxed Development

```json
{
  "policy": {
    "tools": { "allow": ["bash", "read", "edit", "write", "glob", "grep"] },
    "paths": { "allow": ["./src", "./tests"] },
    "network": { "deny": ["*"] }
  }
}
```

### Multi-Tool Workflows

Same persona, different tools:
```bash
agent-persona codex architect   # Planning with Codex
agent-persona claude architect  # Implementation with Claude
```

### Team Standards

Share personas via dotfiles or a team repo:
```bash
export AGENT_PERSONA_PATHS="$HOME/team-personas:$AGENT_PERSONA_PATHS"
```

### Per-Project MCP Configuration

```json
// frontend/.personas/dev/persona.json
{
  "mcpServers": {
    "browser": { "command": "mcp-browser-tools" }
  }
}

// backend/.personas/dev/persona.json
{
  "mcpServers": {
    "postgres": { "command": "mcp-postgres", "args": ["--local"] }
  }
}
```

---

## Overlay Safety

| Environment | Method | On-Disk Changes | Hard-Kill Risk |
|-------------|--------|-----------------|----------------|
| Linux with `unshare` | Bind-mount | None | None |
| Other / `--force-swap` | Swap-and-restore | Temporary | Use `recover` |

If a session is killed unexpectedly (SIGKILL, crash, power loss) while in swap mode:

```bash
agent-persona recover  # Restores from backup
agent-persona doctor   # Shows any orphaned backups
```

---

## Installation

See [INSTALL.md](INSTALL.md) for detailed instructions.

```bash
git clone https://github.com/GoodFarming/agent-persona.git
cd agent-persona && ./install.sh
agent-persona doctor
```

### Requirements

- **Linux** (tested on Ubuntu, should work on most distros)
- **Bash 4.0+** (required for policy features)
- **Python 3** (required for policy enforcement, persona.json parsing, include expansion)
- One or more AI tools: `codex`, `claude`, `gemini`, `opencode`

### Uninstall

```bash
./uninstall.sh
# or manually:
rm -f ~/.local/bin/agent-persona ~/.local/bin/*-persona
rm -rf ~/.local/share/agent-persona
```

---

## Testing

```bash
# Core functionality
bash tests/smoke.sh

# CLI argument/env translation (no model calls)
bash tests/integration-cli-parse.sh

# Real CLI tests (requires credentials, may incur cost)
AGENT_PERSONA_RUN_REAL_TESTS=1 bash tests/integration-real.sh
```

For full test options and manual test procedures, see `tests/MANUAL-TESTS.md`.

---

## Supported Tools

| Tool | Overlay File | Policy Support |
|------|--------------|----------------|
| **Claude / Claude Code** | `CLAUDE.md` | Full |
| **Codex** | `AGENTS.md` | Full (sandbox-based) |
| **Gemini** | `GEMINI.md` | Full (settings-based) |
| **OpenCode** | `AGENTS.md` | Full (config-based) |
| Any executable on PATH | `AGENTS.md` | None |

---

## Contributing

Issues and PRs welcome at [github.com/GoodFarming/agent-persona](https://github.com/GoodFarming/agent-persona).

## License

MIT
