# agent-persona

**Tool-agnostic persona launcher for AI coding agents.**

Switch between different agent "personalities" without permanently modifying your project files. Define reusable instruction profiles, share them across repos, and launch any supported AI tool with consistent, predictable behavior.

## Why Use This?

| Problem | Solution |
|---------|----------|
| AI agents read `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` at startup, but you want different behaviors for different tasks | Create multiple personas and switch instantly |
| You want project-specific context injected into every agent session | Use repo-wide meta that merges automatically using `meta.AGENTS.md` |
| MCP servers need different configs per project or persona | Define MCP in `persona.json`, auto-injected at launch |
| You work across many repos with similar conventions | Share personas globally; repo-local ones take priority |

## Supported Tools

- **Codex** (OpenAI)
- **Claude / Claude Code** (Anthropic)
- **Gemini** (Google)
- **OpenCode**
- Any executable on PATH

## Quick Start

```bash
# One-liner install
curl -fsSL https://raw.githubusercontent.com/GoodFarming/agent-persona/main/install.sh | bash

# Or clone and install
git clone https://github.com/GoodFarming/agent-persona.git && cd agent-persona && ./install.sh

# Launch Claude with the blank persona (safe default)
agent-persona claude blank

# Launch Codex with a custom persona
agent-persona codex my-researcher

# Pass flags through to the underlying tool
agent-persona codex researcher --full-auto
agent-persona claude reviewer -- --verbose

# See what personas are available
agent-persona --list

# Check your installation
agent-persona doctor
```

## How It Works

When you run `agent-persona claude my-persona`:

1. **Resolves** the persona from repo-local, global, or user directories
2. **Merges** optional repo-wide meta instructions (`.personas/meta.AGENTS.md`)
3. **Injects** MCP server config from `persona.json` (if present)
4. **Overlays** the composed instructions onto `AGENTS.md`, `CLAUDE.md`, or `GEMINI.md` in your working directory
5. **Launches** Codex, Claude, Gemini, or any other CLI Agent with the overlaid file
6. **Restores** the original file when the session ends (though ignoring those files and using Blank Persona as Default recommended)

On Linux with unprivileged user namespaces, the overlay uses a bind-mount — **no on-disk changes occur**. Otherwise, it swaps and restores the file (with backup/recovery for crashes).

## Core Concepts

### Personas

A persona is a directory containing `AGENTS.md` (required) and optionally `persona.json`:

```
.personas/my-persona/
├── AGENTS.md       # Instructions for the agent
└── persona.json    # Optional: CLI defaults + MCP servers
```

### Persona Discovery (Priority Order)

1. **Repo-local:** `.personas/<name>/` (preferred) or `.persona/<name>/` (legacy)
2. **Extra paths:** `AGENT_PERSONA_PATHS` environment variable (colon-separated)
3. **Home:** `~/.personas/<name>/`
4. **User:** `~/.local/share/agent-persona/.personas/<name>/`
5. **System:** `/usr/local/share/agent-persona/.personas/<name>/`

Check where a persona resolves from:
```bash
agent-persona which my-persona
```

### Repo-Wide Meta

Add `.personas/meta.AGENTS.md` to inject context into **every** persona launched in that repo:

```markdown
# .personas/meta.AGENTS.md

## Project Context
This is a TypeScript/React monorepo using pnpm workspaces.

## Conventions
- All new code must have tests
- Use `pnpm test` before committing
- Follow the existing code style

## Do Not
- Modify files in `packages/legacy/`
- Skip type checking
```

The template created by `agent-persona init` is **ignored until you edit it**, so placeholder text never pollutes your sessions.

### MCP Server Injection

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

- **Codex:** Emits `-c mcp_servers.*=...` overrides
- **Claude:** Generates a temp `--mcp-config` JSON file (cleaned up after session)
- Disable with `--no-mcp` or `AGENT_PERSONA_MCP=0`

### Tool-Specific Defaults

Set default CLI arguments per tool in `persona.json`:

```json
{
  "defaults": {
    "*": ["--verbose"],
    "codex": ["--full-auto", "-c", "model=gpt-4"],
    "claude": ["--permission-mode", "bypassPermissions"]
  }
}
```

Global defaults (`*`, `global`, `any`) apply first; tool-specific defaults append after.

## Commands

| Command | Description |
|---------|-------------|
| `agent-persona <tool> <persona>` | Launch tool with persona |
| `agent-persona init` | Scaffold `.personas/` in current repo |
| `agent-persona doctor` | Verify installation and check for issues |
| `agent-persona recover` | Restore files after hard-kill (swap mode) |
| `agent-persona which <persona>` | Show where persona resolves from |
| `agent-persona print-overlay <tool> <persona>` | Preview the composed overlay |
| `agent-persona --list` | List all available personas |

### Tool Shims

For convenience, symlinks let you skip specifying the tool:

```bash
claude-persona my-agent    # same as: agent-persona claude my-agent
codex-persona my-agent
gemini-persona my-agent
opencode-persona my-agent
```

### Passing Arguments to the Tool

Extra arguments are passed through to the underlying tool:

```bash
# These flags go to codex
agent-persona codex researcher --full-auto --model o3

# Use -- to separate agent-persona flags from tool flags
agent-persona claude reviewer --no-meta -- --verbose --model sonnet
```

## Flags

| Flag | Description |
|------|-------------|
| `--no-meta` | Skip repo meta merge |
| `--no-mcp` | Skip MCP injection |
| `--meta-file=<path>` | Override meta file location |
| `--meta-position=top\|bottom` | Where to merge meta (default: top) |
| `--force-swap` | Force swap-and-restore (skip unshare) |
| `--version` | Show version |
| `-h, --help` | Show help |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AGENT_PERSONA_DEBUG` | Enable debug logging | off |
| `AGENT_PERSONA_META` | Enable meta merge | `1` |
| `AGENT_PERSONA_MCP` | Enable MCP injection | `1` |
| `AGENT_PERSONA_META_FILE` | Override meta file path | auto-detect |
| `AGENT_PERSONA_META_POSITION` | `top` or `bottom` | `top` |
| `AGENT_PERSONA_FORCE_SWAP` | Force swap mode | `0` |
| `AGENT_PERSONA_PATHS` | Extra search paths (colon-separated) | empty |
| `AGENT_PERSONA_HOME` | User persona directory | `~/.local/share/agent-persona` |
| `AGENT_PERSONA_PREFER_REPO` | Prefer repo-local personas | `1` |

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

## Use Case Ideas

### 1. Task-Specific Agents

```bash
# Deep research mode
agent-persona claude researcher

# Quick fixes only
agent-persona codex fixer

# Code review specialist
agent-persona claude reviewer
```

### 2. Project Archetypes

Create personas for different project types:
- `spec-lead` — Recursive Planning and Multi-Chapter Specs
- `bead-lead` — Breaking Specs out into Beads and Beads Progress
- `aga` — Agent Governence Architect - Desinging and Fine-Tuning Personas

### 3. Team Standards

Share personas via your dotfiles or a team repo:
```bash
export AGENT_PERSONA_PATHS="$HOME/team-personas:$AGENT_PERSONA_PATHS"
```

### 4. Sandboxed Experiments

Use `blank` for untrusted or exploratory work:
```bash
agent-persona claude blank  # No specialized instructions
```

### 5. Multi-Tool Workflows

Same persona, different tools:
```bash
agent-persona codex architect   # Planning with Codex
agent-persona claude architect  # Implementation with Claude
```

### 6. MCP Per-Project

Different projects need different MCP servers:
```json
// frontend-app/.personas/dev/persona.json
{
  "mcpServers": {
    "browser": { "command": "mcp-browser-tools" }
  }
}

// backend-api/.personas/dev/persona.json
{
  "mcpServers": {
    "postgres": { "command": "mcp-postgres", "args": ["--local"] }
  }
}
```

## Creating Your First Persona

### Option 1: Repo-Local

```bash
cd your-project
agent-persona init
mkdir .personas/my-agent
cat > .personas/my-agent/AGENTS.md << 'EOF'
# My Agent

## Purpose
Help with feature development in this project.

## Approach
- Write tests first
- Keep changes minimal
- Explain trade-offs
EOF
```

### Option 2: Global

```bash
mkdir -p ~/.personas/my-agent
# Add AGENTS.md as above
```

### Option 3: With Defaults & MCP

```bash
mkdir -p ~/.local/share/agent-persona/.personas/my-agent
cat > ~/.local/share/agent-persona/.personas/my-agent/persona.json << 'EOF'
{
  "defaults": {
    "claude": ["--permission-mode", "bypassPermissions"]
  },
  "mcpServers": {
    "memory": {
      "command": "mcp-memory",
      "args": ["--db", "/tmp/memory.db"]
    }
  }
}
EOF
```

## Installation

See [INSTALL.md](INSTALL.md) for detailed instructions.

```bash
# Quick install
git clone https://github.com/GoodFarming/agent-persona.git
cd agent-persona
./install.sh

# Verify
agent-persona doctor
```

## Uninstall

```bash
./uninstall.sh
# or manually:
rm -f ~/.local/bin/agent-persona ~/.local/bin/*-persona
rm -rf ~/.local/share/agent-persona
```

## Requirements

- **Linux** (tested on Ubuntu, should work on most distros)
- **Bash 4.0+**
- **Python 3** (for persona.json parsing; optional but recommended)
- One or more AI tools: `codex`, `claude`, `gemini`, `opencode`

## Contributing

Any Contributions must be more than 1 full days work in value to justify the PR -- otherwise suggestions are preffered to avoid review. 

## License

MIT
