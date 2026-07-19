#!/usr/bin/env python3
# mail-guard — PreToolUse guard: deliver mail through `agentbus send`, never by direct file writes.
# Wire in project settings (same way as mail-check.py; truth-source entry in sibling hooks.json):
#   PreToolUse  matcher "Write|Edit|MultiEdit"  -> <abs>/mail-guard.py
# Rationale (2026-07-10 live): an orchestrator wrote several letters straight into recipient inboxes
# with the Write tool — bypassing every gate the helper carries (8KB hard size cap, >2KB brevity
# warning, atomic tmp/->inbox delivery) — and hand-rolled frontmatter got fields wrong (a letter
# shipped with the wrong `from:`). Prose said "use the helper"; prose that doesn't reach the
# decision point is net-negative -> promote to a tool-call hook (same conclusion as cto-guard).
# Scope: DENY only <bus>/<id>/inbox/... file writes. tmp/ is the helper's own staging area,
# archive/ moves go through `agentbus archive` (and this guard only sees Write/Edit, not mv),
# registry.md sits at the bus root — none of those match. Reading anything stays free.
# Deny/checker error = exit 2 + stderr (shown to the agent).
import json
import os
import sys

GUARDED_TOOLS = ("Write", "Edit", "MultiEdit")


def checker_error(message):
    sys.stderr.write(f"CHECKER-ERROR: {message}\n")
    return 2


def bus_root():
    # $AGENT_MAIL_DIR wins over the default, mirroring agentbus / mail-check.py.
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
        return checker_error("invalid hook JSON.")
    if not isinstance(data, dict):
        return checker_error("hook payload must be an object.")
    if data.get("hook_event_name") != "PreToolUse":
        return 0
    if data.get("tool_name") not in GUARDED_TOOLS:
        return 0
    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        return checker_error("guarded mail write requires object tool_input.")
    file_path = ti.get("file_path")
    if not isinstance(file_path, str) or not file_path:
        return checker_error("guarded mail write requires string tool_input.file_path.")
    hit = inbox_target(file_path)
    if not hit:
        return 0
    sys.stderr.write(
        "DENY: direct Write/Edit into an agent-mail inbox. Direct writes bypass the helper's "
        "gates — 8KB hard size cap, >2KB brevity warning, atomic tmp/->inbox delivery — and "
        "hand-rolled frontmatter gets fields wrong (2026-07-10: letters written via the Write "
        "tool shipped with a wrong `from:`). Deliver through the helper instead:\n"
        "  agentbus send <from> <to> <slug> <subject> <<'EOF'\n"
        "  <body: conclusion first, action items, evidence as paths/URLs>\n"
        "  EOF\n"
        "Reading mail and the roster directly stays fine; only delivery must go through "
        "`agentbus send`. Read: agent-mail/SKILL.md §agentbus helper.\n"
    )
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(checker_error("internal guard failure."))
