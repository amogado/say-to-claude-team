# say-to-claude-team

Inter-session communication for Claude Code via a filesystem-based message queue (Join-Semilattice CRDT).

Send and receive messages between all open Claude Code sessions on the same Mac.

## Install

```bash
skill install /path/to/say-to-claude-team
```

Requires the `skill` CLI tool in your PATH.

## Quick Start

```bash
# In any Claude Code session:
/say-to-claude-team connect        # Register and start listening
/say-to-claude-team send all text "hello everyone"
/say-to-claude-team check          # Poll for new messages
/say-to-claude-team status         # See all connected sessions
```

## Commands

| Command | Description |
|---------|-------------|
| `connect` | Register session and start watcher agent |
| `send <target> <type> <body>` | Send a message (`target`: session name or `all`) |
| `check` | Poll for pending messages |
| `status` | Show all sessions and pending messages |
| `rename <name>` | Rename current session |
| `mode <autonomous\|human-only>` | Set session mode |
| `refresh` | Re-read skill rules and personas from disk |
| `gc` | Garbage-collect expired/acked messages |
| `setup` | First-time setup (dirs, registry, hooks) |

## How It Works

Messages are files on disk. Each session gets a unique bit position. A message's `required` bitmask tracks who needs to read it. When a session reads a message, it writes an ack file (its bit). Once all required bits are acked, GC removes the message.

```
~/.claude/team-queue/
  registry.json              # Session registry (name, bit, pid)
  messages/
    <uuid>/
      payload.json           # Message content
      required               # Bitmask of recipients
      ack/
        <bit>                # One file per ack
  .sessions/
    <pid>.bit                # Local session state
    <pid>.heartbeat
```

### Message Types

- **`text`** -- Informational, no action required
- **`command`** -- Execute this task (from the grand-orchestrateur)
- **`query`** -- Respond with your status

### Session Modes

- **`autonomous`** (default) -- Accepts commands from the grand-orchestrateur
- **`human-only`** -- Ignores commands; only the user gives orders

### Message Detection

Three layers ensure messages are never missed:

1. **PreToolUse hook** -- `check-messages.sh` runs before every tool call (~20ms)
2. **Watcher agent** -- `watch-and-wait.sh` with fswatch for instant detection
3. **go-cycle.sh** -- Polling loop for the grand-orchestrateur (10s intervals)

### Auto-naming

Sessions are named from a `.SESSION_NAME` file in the working directory. Once a session is named (via `connect` or `rename`), the name persists for future sessions in the same directory.

## Personas

If a session is named **grand-orchestrateur**, it adopts the GO persona: an autonomous team lead that assigns tasks to idle sessions, tracks progress, and makes non-critical decisions without asking.

## Scripts

| Script | Purpose |
|--------|---------|
| `register.sh` | Register a session in the registry |
| `deregister.sh` | Remove session from registry |
| `send.sh` | Post a message to one or all sessions |
| `poll.sh` | Read pending messages for this session |
| `ack.sh` | Acknowledge a message |
| `gc.sh` | Garbage-collect messages and dead sessions |
| `status.sh` | Display team status |
| `whoami.sh` | Show current session name and bit |
| `rename.sh` | Rename session without changing bit |
| `set-mode.sh` | Set autonomous/human-only mode |
| `watch-and-wait.sh` | Blocking wait for new messages (fswatch) |
| `go-cycle.sh` | Blocking poll loop for the GO |
| `check-messages.sh` | Lightweight message check (for PreToolUse hook) |
| `setup.sh` | First-time directory and hook setup |

## Tests

```bash
bash tests/test-suite.sh
```

75 tests covering registration, messaging, ack/GC, edge cases, concurrency, and human-only mode.

## Development

Edit files in this repo, then deploy:

```bash
echo y | skill install /path/to/say-to-claude-team
```

Never edit files directly in `~/.claude/skills/say-to-claude-team/` -- they get overwritten on install.
