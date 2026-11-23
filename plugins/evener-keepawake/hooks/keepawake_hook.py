#!/usr/bin/env python3
"""evener-keepawake hook: records session busy state in marker files.

One marker file per session lives in ~/.local/state/evener-keepawake/<session_id>.
The heartbeat service refreshes the Sprite task `evener` while any marker is
fresh; a marker untouched for the TTL is stale and ignored, so a crashed
session can never hold the Sprite awake indefinitely.

Event map (input arrives as one JSON object on stdin):
  busy (touch marker):  SessionStart, UserPromptSubmit, PostToolBatch,
                        SubagentStart, PostToolUseFailure(AskUserQuestion)
  idle (remove marker): Stop, StopFailure, SubagentStop, SessionEnd,
                        PreToolUse(AskUserQuestion)

Why the two AskUserQuestion cases exist: when a turn ends on a pending,
unanswered question, evener skips the Stop hook entirely (the session goes
straight to `awaiting`), so the marker must be cleared when the question is
asked — but if the ask call itself fails, the session is still mid-turn and
the marker is restored.

The hook is synchronous: it only touches or removes a file, never touches the
network, and always exits 0 so it can never block a session.
"""

import json
import os
import sys
import time

STATE_DIR = os.environ.get(
    "EVENER_KEEPAWAKE_STATE",
    os.path.join(os.path.expanduser("~"), ".local", "state", "evener-keepawake"),
)
DEBUG = os.environ.get("EVENER_KEEPAWAKE_DEBUG") == "1"

BUSY_EVENTS = {
    "SessionStart",       # a turn is about to run (covers delegate children too)
    "UserPromptSubmit",   # a new prompt was submitted
    "PostToolBatch",      # a tool round finished; the turn continues
    "SubagentStart",     # a delegate child run is launching
}
IDLE_EVENTS = {
    "Stop",               # turn ended normally (fires even with live background jobs)
    "StopFailure",        # turn ended on a provider failure
    "SubagentStop",       # a delegate run finished (runs on the child session)
    "SessionEnd",         # session teardown (daemon idle shutdown, clear, other)
}


def log(message: str) -> None:
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(os.path.join(STATE_DIR, "hooks.log"), "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), message))
    except OSError:
        pass  # logging must never break the hook


def touch(marker: str) -> None:
    with open(marker, "a"):
        os.utime(marker, None)


def remove(marker: str) -> None:
    try:
        os.remove(marker)
    except FileNotFoundError:
        pass


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception as exc:  # malformed input must never block the session
        log("ignoring unreadable hook input: %s" % exc)
        return 0

    session_id = data.get("session_id")
    event = data.get("hook_event_name", "")
    if not session_id:
        log("no session_id in %s input; doing nothing" % (event or "unknown event"))
        return 0
    marker = os.path.join(STATE_DIR, session_id)

    action = None
    if event in BUSY_EVENTS:
        action = "busy"
    elif event in IDLE_EVENTS:
        action = "idle"
    elif event == "PreToolUse" and data.get("tool_name") == "AskUserQuestion":
        action = "idle"  # about to block waiting for the human
    elif event == "PostToolUseFailure" and data.get("tool_name") == "AskUserQuestion":
        action = "busy"  # the ask failed; the turn is still running

    try:
        if action == "busy":
            os.makedirs(STATE_DIR, exist_ok=True)
            touch(marker)
        elif action == "idle":
            remove(marker)
        if DEBUG:
            log("%s %s -> %s" % (event, session_id, action or "ignored"))
    except OSError as exc:
        log("%s %s: %s" % (event, session_id, exc))
        # Sandbox policy may forbid writes outside the session; that is expected
        # for confined sessions. Exit 0 regardless: never block the session.
    return 0


if __name__ == "__main__":
    sys.exit(main())
