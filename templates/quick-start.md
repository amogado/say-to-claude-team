# Quick Start — say-to-claude-team

Send messages between Claude Code sessions in under 2 minutes.

## Prerequisites

- macOS with `jq` installed (`brew install jq`)
- Two or more Claude Code sessions open on the same machine

---

## Step 1 — Install (once per machine)

Run this from the skill directory:

```bash
bash /path/to/say-to-claude-team/scripts/setup.sh
```

Then add the hook to `~/.claude/settings.json` (merge with existing `hooks` if present):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/team-queue/scripts/check-messages.sh"
          }
        ]
      }
    ]
  }
}
```

The hook auto-detects incoming messages before each tool call.

---

## Step 2 — Register your session (once per session)

In each Claude Code session, run:

```bash
bash ~/.claude/team-queue/scripts/register.sh frontend
# Output: Registered as 'frontend' (bit 0)
```

Use a meaningful name (`frontend`, `backend`, `tests`, etc.).

---

## Step 3 — Send a message

From session "frontend", broadcast to all other sessions:

```bash
bash ~/.claude/team-queue/scripts/send.sh all text "Build is green, ready to merge"
# Output: Sent text to 'all' (1 recipient(s)): <uuid>
```

Or send a command to a specific session:

```bash
bash ~/.claude/team-queue/scripts/send.sh backend command "Run the auth migration"
```

---

## Step 4 — Receive messages in another session

The hook notifies you automatically before the next tool call:

```
[Team Queue] 1 unread message — run /say-to-claude-team check to read

[1] From: frontend (just now) [text]
    Build is green, ready to merge
```

To read and acknowledge manually:

```bash
# List unread messages (JSON output)
bash ~/.claude/team-queue/scripts/poll.sh

# Acknowledge a message
bash ~/.claude/team-queue/scripts/ack.sh <uuid>
```

Or via the skill:

```
/say-to-claude-team check
```

---

## Useful commands

| What you want | Command |
|---------------|---------|
| See all sessions and queue state | `bash ~/.claude/team-queue/scripts/status.sh` |
| Clean up old messages | `bash ~/.claude/team-queue/scripts/gc.sh` |
| Unregister a session | `bash ~/.claude/team-queue/scripts/deregister.sh` |

---

## Message types

| Type | When to use |
|------|-------------|
| `text` | Share information, no action needed |
| `command` | Instruction the recipient should execute |
| `query` | Question that expects a reply (recipient uses `in_reply_to`) |
