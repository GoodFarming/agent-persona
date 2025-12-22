# Installation Guide

## Requirements

- **Linux** (required for best experience)
- Bash 4.0+
- One or more supported AI tools: `codex`, `claude`, `gemini`, `opencode`

### Optional but Recommended

- **Unprivileged user namespaces** enabled (for bind-mount overlay)
  - Check: `unshare -Um true && echo "OK"`
  - Most modern Linux distros have this enabled by default

## Quick Install

```bash
git clone https://github.com/GoodFarming/agent-persona.git
cd agent-persona
./install.sh
```

This will:
1. Copy `agent-persona` to `~/.local/bin/`
2. Create symlinks: `codex-persona`, `claude-persona`, `gemini-persona`, `opencode-persona`
3. Copy example personas to `~/.local/share/agent-persona/personas/` (and create `personas.local/` for private personas)

## Manual Install

```bash
# 1. Copy the launcher
cp agent-persona ~/.local/bin/
chmod +x ~/.local/bin/agent-persona

# 2. Create tool shims (optional but convenient)
ln -s ~/.local/bin/agent-persona ~/.local/bin/codex-persona
ln -s ~/.local/bin/agent-persona ~/.local/bin/claude-persona
ln -s ~/.local/bin/agent-persona ~/.local/bin/gemini-persona
ln -s ~/.local/bin/agent-persona ~/.local/bin/opencode-persona

# 3. Create persona directories
mkdir -p ~/.local/share/agent-persona/personas ~/.local/share/agent-persona/personas.local

# 4. Copy example personas
cp -r personas/* ~/.local/share/agent-persona/personas/

# 5. Ensure ~/.local/bin is in PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## Verify Installation

```bash
# Check installation
agent-persona doctor

# List available personas
agent-persona --list

# Test with blank persona
agent-persona claude blank
```

## Uninstall

```bash
./uninstall.sh
```

Or manually:
```bash
rm -f ~/.local/bin/agent-persona
rm -f ~/.local/bin/codex-persona ~/.local/bin/claude-persona ~/.local/bin/gemini-persona ~/.local/bin/opencode-persona
rm -rf ~/.local/share/agent-persona
```

## Directory Structure

After installation:

```
~/.local/
├── bin/
│   ├── agent-persona          # main launcher
│   ├── codex-persona          # symlink
│   ├── claude-persona         # symlink
│   ├── gemini-persona         # symlink
│   └── opencode-persona       # symlink
└── share/
    └── agent-persona/
        ├── personas/
        │   ├── blank/AGENTS.md    # minimal persona
        │   └── example/AGENTS.md  # template
        └── personas.local/        # your private personas
```

## Adding Your Own Personas

### User-level (applies everywhere)

If you prefer a simple global location, you can store personas in `~/.personas/<name>/AGENTS.md`:

```bash
mkdir -p ~/.personas/my-persona
$EDITOR ~/.personas/my-persona/AGENTS.md
```

Or store them under the installed directory:

```bash
mkdir -p ~/.local/share/agent-persona/personas/my-persona
cat > ~/.local/share/agent-persona/personas/my-persona/AGENTS.md <<'EOF'
# My Persona

## Purpose
[What this persona does]

## Operating Mode
[How it should behave]
EOF
```

### Repo-level (applies only in that repo)

```bash
cd /path/to/your/repo
agent-persona init

# Creates .personas/ directory, then:
mkdir .personas/my-persona
# Add AGENTS.md as above
```

### Per-tool defaults

Create `persona.json` next to `AGENTS.md`:

```json
{
  "defaults": {
    "codex": ["--full-auto", "-c", "some_config=value"],
    "claude": ["--permission-mode", "bypassPermissions"],
    "*": []
  }
}
```

## Troubleshooting

### "unshare failed" / falling back to swap mode

This is normal if unprivileged user namespaces are disabled. The launcher will use swap-and-restore mode instead. To enable namespaces:

```bash
# Check current setting
cat /proc/sys/kernel/unprivileged_userns_clone

# Enable (requires root)
echo 1 | sudo tee /proc/sys/kernel/unprivileged_userns_clone

# Make permanent
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/99-userns.conf
sudo sysctl --system
```

### File not restored after crash

Run `agent-persona recover` to restore from backup.

### Persona not found

1. Check spelling: `agent-persona which my-persona`
2. Verify the persona exists: `ls ~/.local/share/agent-persona/personas/`
3. Check search paths: `agent-persona --list`

### Tool not found

Ensure the tool is installed and in PATH:
```bash
which codex
which claude
```
