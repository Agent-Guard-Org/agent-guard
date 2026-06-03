# agent-guard

A [Claude Code](https://claude.ai/code) hook that scans prompts and tool I/O for leaked credentials using [TruffleHog](https://github.com/trufflesecurity/trufflehog), blocking them before they reach Anthropic's servers.

## How it works

agent-guard registers as a Claude Code hook on three events:

| Event | What happens |
|---|---|
| **UserPromptSubmit** | Scans the prompt before it's sent to Claude — blocked if secrets found |
| **PreToolUse** | Scans tool input (e.g. content being written to a file) — tool call denied if secrets detected |
| **PostToolUse** | Scans tool output (e.g. file reads, shell output) — response redacted if secrets detected |

Detection pipes content through `trufflehog stdin` with `verified`, `unverified`, and `unknown` results enabled. If TruffleHog is unavailable or errors, agent-guard fails open so it never silently breaks your workflow.

For `PostToolUse`, the response is redacted in place rather than dropped — string values containing secrets are replaced with `[REDACTED by agent-guard - credentials detected]` while structural fields (line numbers, types, flags) are preserved so Claude can still reason about the shape of the response.

## Quick install

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/nathabonfim59/agent-guard/main/scripts/install.sh | bash
```

**Windows** (PowerShell 5.1+)

```powershell
irm https://raw.githubusercontent.com/nathabonfim59/agent-guard/main/scripts/install.ps1 | iex
```

Both scripts will:
1. Download the latest binary for your OS/arch
2. Optionally install TruffleHog if it's not found
3. Add hooks to your Claude Code settings (global, project, or local scope)

### Install script options

**macOS / Linux**

```
-b, --bindir DIR          Install directory (default: ~/.local/bin)
-v, --version VERSION     Install a specific version (default: latest)
-y, --yes                 Auto-accept all prompts
    --skip-trufflehog     Don't prompt to install trufflehog
    --skip-config         Don't prompt for Claude Code configuration
    --scope SCOPE         Hook scope: global, project, local
```

Non-interactive global install:

```bash
curl -fsSL https://raw.githubusercontent.com/nathabonfim59/agent-guard/main/scripts/install.sh | bash -s -- -y --scope global
```

**Windows**

```powershell
.\install.ps1 [-BinDir <path>] [-Version <ver>] [-Yes] [-SkipTrufflehog] [-SkipConfig] [-Scope global|project|local]
```

Non-interactive global install:

```powershell
.\install.ps1 -Yes -Scope global
```

> **Note:** TruffleHog does not ship an official Windows installer script. The PowerShell script will point you to the [TruffleHog releases page](https://github.com/trufflesecurity/trufflehog/releases) to download `trufflehog.exe` manually. Place it in your `BinDir` and ensure that directory is on your `PATH`.

## Build from source

```bash
# Build + install binary + add hooks to ~/.claude/settings.json
make hooks

# Or step by step
make build    # output: ./agent-guard
make install  # copy to ~/.local/bin
make hooks    # patch ~/.claude/settings.json

# Remove hooks
make hooks-remove
```

## Manual configuration

To wire the hooks yourself, add to your Claude Code `settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [{"type": "command", "command": "/path/to/agent-guard", "args": [], "timeout": 30}]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [{"type": "command", "command": "/path/to/agent-guard", "args": [], "timeout": 30}]
      }
    ]
  }
}
```

## Requirements

- [TruffleHog](https://github.com/trufflesecurity/trufflehog#installation) — on `$PATH` or at `~/.local/bin/trufflehog` (Unix) / `%USERPROFILE%\.local\bin\trufflehog.exe` (Windows)
- Claude Code
- Go 1.23+ (source builds only)

## Development

```bash
make test    # build + run test suite
make build   # build binary
make clean   # remove binary
```
