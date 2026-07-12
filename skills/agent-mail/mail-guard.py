#!/usr/bin/env python3
# mail-guard — PreToolUse guard: deliver mail through `agent-bus send`, never by direct file writes.
# Wire in project settings (same way as mail-check.py; truth-source entry in sibling hooks.json):
#   PreToolUse  matcher "Write|Edit|MultiEdit"  -> <abs>/mail-guard.py
# Rationale (2026-07-10 live): an orchestrator wrote several letters straight into recipient inboxes
# with the Write tool — bypassing every gate the helper carries (8KB hard size cap, >2KB brevity
# warning, atomic tmp/->inbox delivery) — and hand-rolled frontmatter got fields wrong (a letter
# shipped with the wrong `from:`). Prose said "use the helper"; prose that doesn't reach the
# decision point is net-negative -> promote to a tool-call hook (same conclusion as cto-guard).
# Scope: DENY only <bus>/<id>/inbox/... file writes. tmp/ is the helper's own staging area,
# archive/ moves go through `agent-bus archive` (and this guard only sees Write/Edit, not mv),
# registry.md sits at the bus root — none of those match. Reading anything stays free.
# Deny = exit 2 + stderr (shown to the agent). Fail-open: any parse error exits 0, never blocks.
import json
import os
import sys

GUARDED_TOOLS = ("Write", "Edit", "MultiEdit")


def bus_root():
    # $AGENT_MAIL_DIR wins over the default, mirroring agent-bus / mail-check.py.
    raw = os.environ.get("AGENT_MAIL_DIR") or "~/.agents/mail"
    return os.path.realpath(os.path.expanduser(raw))


def inbox_target(file_path):
    # file_path may be absolute, ~-prefixed, or relative; realpath also unifies the
    # macOS /tmp -> /private/tmp symlink so prefix matching can't be dodged by spelling.
    fp = os.path.realpath(os.path.expanduser(file_path))
    bus = bus_root()
    if not fp.startswith(bus + os.sep):
        return False
    rel = fp[len(bus) + 1:].split(os.sep)
    # <bus>/<agent-id>/inbox/<...file> — exactly the delivery surface. tmp/ and archive/
    # (rel[1] != "inbox") and bus-root files like registry.md (len < 3) fall through.
    return len(rel) >= 3 and rel[1] == "inbox"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if data.get("hook_event_name") != "PreToolUse":
        return 0
    if data.get("tool_name") not in GUARDED_TOOLS:
        return 0
    ti = data.get("tool_input") or {}
    file_path = ti.get("file_path") or ""
    if not file_path:
        return 0
    try:
        hit = inbox_target(file_path)
    except Exception:
        return 0  # fail-open: a guard must never block on its own bug
    if not hit:
        return 0
    sys.stderr.write(
        "DENY: direct Write/Edit into an agent-mail inbox. Direct writes bypass the helper's "
        "gates — 8KB hard size cap, >2KB brevity warning, atomic tmp/->inbox delivery — and "
        "hand-rolled frontmatter gets fields wrong (2026-07-10: letters written via the Write "
        "tool shipped with a wrong `from:`). Deliver through the helper instead:\n"
        "  agent-bus send <from> <to> <slug> <subject> <<'EOF'\n"
        "  <body: conclusion first, action items, evidence as paths/URLs>\n"
        "  EOF\n"
        "Reading mail and the roster directly stays fine; only delivery must go through "
        "`agent-bus send`. Read: agent-mail/SKILL.md §agent-bus helper.\n"
    )
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # fail-open
