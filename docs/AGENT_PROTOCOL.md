# Agent Protocol

This document is the contract between **WAM Voice Capture** (the Mac client) and **any downstream agent** processing its transcripts. If you follow the layout and signals below, you can build your own agent on any stack (Python cron, Node, Go daemon, Rust inotify watcher, plain shell + `entr`) and it will Just Work with the unmodified Mac client.

The reference agent implementation lives in [`artempolansky/angelina-ops`](https://github.com/artempolansky/angelina-ops) — feel free to crib from it.

**Protocol version:** `1` (current). Breaking changes get a new version number.

---

## Mental model

The Mac client doesn't push transcripts over HTTP/WebSocket/RPC. It **rsyncs files into a folder** on your server. Your agent watches that folder. That's the whole API.

```
[Mac]                                    [Your server]
  WAM Voice Capture                        /home/<you>/inbox/        ← you choose this path
       │
       │  start meeting
       │  ────────────────►   2026-06-04-093000-meeting.md           ← appears here, header only
       │                       (header: YAML frontmatter or          ← agent: "new meeting started"
       │                        "# Meeting <stem>" legacy form)
       │
       │  meeting is recording, transcript grows live
       │  ────────────────►   2026-06-04-093000-meeting.md           ← grows over ~2 s ticks
       │                       (every appendLine triggers an rsync;  ← agent: "this meeting is live"
       │                        --inplace lets you tail -f it)
       │
       │  stop meeting
       │  ────────────────►   2026-06-04-093000-meeting.md.done      ← empty marker file appears
       │                                                              ← agent: "this meeting is FINAL,
       │                                                                 safe to process"
```

That's it. No HTTP, no auth headers, no schema. Just files.

---

## Inbox layout

You pick the directory when configuring the Mac side (Tray → Settings → Forward transcripts to → Add target). Conventionally it's called `inbox/`. The Mac will create the directory if missing.

Files in the inbox follow this naming:

| File | Meaning |
|---|---|
| `<stem>.md` | The transcript itself — Markdown with optional YAML frontmatter |
| `<stem>.md.done` | **Empty** marker file. Existence = the corresponding `.md` is finalized; safe to process |

`<stem>` is `YYYY-MM-DD-HHMMSS-<slug>` where `<slug>` is either:
- a slugified calendar event title (e.g. `2026-06-04-093000-standup-with-anya`), or
- the generic `meeting` (e.g. `2026-06-04-093000-meeting`) if no event was matched.

---

## Transcript file format

### Header

Either a YAML frontmatter block (when a calendar event was matched):

```markdown
---
title: Standup with Anya
date: 2026-06-04
start: 09:30
end: 10:00
attendees: [Anya Petrova, Boris Sidorov]
link: https://meet.google.com/abc-defg-hij
calendar: Google – work@example.com
calendar_event_id: 656F7C44-552D-4E8B-B321-EF66471FC062:...@google.com
---

# Standup with Anya

```

Or the legacy plain header (no calendar match):

```markdown
# Meeting 2026-06-04-093000-meeting

```

Agents should handle both. Parse only the keys you care about; unknown keys may appear in future protocol versions.

### Body

Each line has this shape:

```
HH:MM Speaker N: text…
```

or after a user-side rename:

```
HH:MM <Custom Name>: text…
```

Where `Speaker 1` is always the user's mic, `Speaker 2` is the first voice detected in system audio (other party on a call), `Speaker 3` is the next, and so on. Within-channel diarization is provider-dependent:

- **Deepgram** distinguishes Speaker 2, 3, 4… by voice
- **Local Whisper** lumps everything in system audio into Speaker 2 (no diarization)

Each line is one final segment from the STT provider. They appear roughly in chronological order, but not strictly — the client uses `--inplace` rsync, so an agent may briefly see the file mid-write.

---

## Lifecycle contract

### Agent should:

1. **Watch the inbox** — inotify / fswatch / cron polling, doesn't matter. Recommended poll interval: 30 s or faster.
2. **Wait for `.done`** before processing. The `.md` may exist for several minutes while a meeting is live — don't act until the marker appears.
3. **Treat `.done` as monotone** — once it exists, the `.md` is committed; no further writes will happen to that file.
4. **Be idempotent.** rsync may transfer the same content multiple times if the network blips. Same `<stem>` arriving twice should produce the same result; don't bill the user twice or post the same summary twice.
5. **Move or delete consumed files** when done. The client never touches files after writing `.done`, so the inbox would otherwise grow forever.

### Agent must NOT:

- Process a `.md` without a corresponding `.md.done`. The file may still be open for append on the Mac side.
- Assume any particular line ordering within a file beyond chronological. Speaker switches and rsync timing can produce surprising orders.
- Delete `.done` marker files without consuming the `.md` — the client uses no further signal beyond their existence.

---

## Live-streaming option (advanced)

If your agent wants to **observe a meeting as it's happening** (mid-meeting insights, real-time alerts), you can read `.md` files before `.done` arrives:

- Use `tail -f` semantics. The client uses `rsync --inplace`, which writes to the same inode; `tail -f` won't lose its position.
- Be aware: lines may appear out of strict order due to rsync's diff algorithm. Re-sort by timestamp if it matters.
- A meeting may stop without ever producing `.done` (Mac crashed, network died, user quit the app mid-call). Use a timeout — if no new lines for ~10 min and no `.done`, treat as orphaned.

The reference Angelina v3 watcher uses this pattern for [proactive context-aware mid-meeting insights](https://github.com/artempolansky/angelina-ops/issues/264).

---

## Retry and failure semantics

The Mac client retries rsync indefinitely with exponential backoff while a meeting is active. Once `.done` is written, no further sync attempts happen for that `<stem>`.

If your server is down when a meeting ends, the client may keep retrying for a while; the `.md` and `.md.done` will arrive together once the connection comes back. Don't assume they appear simultaneously, but they will appear within seconds of each other.

---

## A 30-line example watcher (Python)

This is the minimum viable agent. Polls inbox every 30 s, processes any new `.md.done` once, archives both files, never spams.

```python
#!/usr/bin/env python3
"""Minimal WAM Voice Capture agent — see AGENT_PROTOCOL.md v1."""
import shutil
import time
from pathlib import Path

INBOX   = Path.home() / "wam-inbox"
ARCHIVE = Path.home() / "wam-archive"

def process_one(done_marker: Path) -> None:
    md = done_marker.with_suffix("")  # strips ".done"
    if not md.exists():
        return
    print(f"[agent] processing {md.name}")
    text = md.read_text()
    # ... your real logic here: classify, summarize, post to Slack,
    # create Linear issues from action items, whatever ...
    print(f"[agent]   {len(text)} chars, {text.count(chr(10))} lines")
    # Move both files into archive so we never re-process.
    ARCHIVE.mkdir(parents=True, exist_ok=True)
    shutil.move(str(md), ARCHIVE / md.name)
    shutil.move(str(done_marker), ARCHIVE / done_marker.name)

def main() -> None:
    INBOX.mkdir(parents=True, exist_ok=True)
    while True:
        for marker in sorted(INBOX.glob("*.md.done")):
            try:
                process_one(marker)
            except Exception as e:
                print(f"[agent] error on {marker.name}: {e}")
        time.sleep(30)

if __name__ == "__main__":
    main()
```

A more sophisticated implementation (LLM classification, Telegram delivery, action-item extraction to Google Docs, multi-meeting state) is in `artempolansky/angelina-ops` at `scripts/process_transcripts.py` (watcher v2) and `core/transcript_watcher/` (watcher v3).

---

## Multiple agents on one inbox

**Not supported.** The Mac client assumes one inbox = one agent. If you want fan-out (one transcript → multiple agents), do one of:

- Configure multiple sync targets on the Mac side (Tray → Settings → Forward transcripts to → Add target). Each goes to a different host or path, each has its own agent.
- Inside your agent, after consuming the `.md`, fan out the work yourself (post to Slack AND save to Notion AND email yourself).

---

## Versioning

This is protocol version **1**. Breaking changes — changes to the file naming convention, the `.done` semantics, or the YAML frontmatter shape — will bump the version and be documented here.

The current Mac client does **not** embed the protocol version in transcripts. A future minor change will add an `x-wam-protocol: 1` field to YAML frontmatter so robust agents can pin to a known version.

---

## Questions / contribution

Drop them in the [community chat](https://t.me/weamclub) or open an [issue](https://github.com/artempolansky/wam-voice-capture/issues).
