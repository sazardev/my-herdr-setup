#!/bin/sh
# herdr-statusline.sh — Claude Code "statusLine" command (settings.json ->
# statusLine.command), NOT a hook. Claude Code pipes a JSON blob on stdin
# after each response; for Pro/Max subscribers it includes the real plan
# limits (https://code.claude.com/docs/en/statusline):
#   rate_limits.five_hour.{used_percentage,resets_at}   rolling 5-hour window
#   rate_limits.seven_day.{used_percentage,resets_at}   weekly window
# These are the same numbers `/usage` shows — no credentials read, no
# undocumented endpoint. They are account-wide, so they are shown ONCE (in
# the terminal window title) instead of repeated on every agent row.
#
# Does two things:
#   1. prints a line for Claude Code's own status bar, with reset countdowns:
#        5h ███░░░░░ 32% ↻3h28m · 7d █████░░░ 68% ↻5d6h
#   2. if running inside a Herdr pane, sets the terminal window title through
#      the socket API (client.window_title.set), minimal, no resets:
#        5h ███░░░░░ 32%  ·  7d █████░░░ 68%
#      Needs `window_title = ""` in config.toml [ui], otherwise herdr
#      rewrites the title itself on every workspace/tab change.
#
# Each window may be absent (API-key users, or before the first response in
# a session): then nothing is printed or set. Always exits 0.
set -u

command -v python3 >/dev/null 2>&1 || exit 0

python3 -c '
import json
import os
import socket
import sys
import time

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

limits = data.get("rate_limits") or {}
BAR_WIDTH = 8


def bar(pct):
    filled = max(0, min(BAR_WIDTH, round(pct / 100 * BAR_WIDTH)))
    return "█" * filled + "░" * (BAR_WIDTH - filled)


def fmt_reset(resets_at):
    secs = int(resets_at - time.time())
    if secs <= 0:
        return ""
    days, rem = divmod(secs, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d{hours}h"
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def window(name, key):
    w = limits.get(key) or {}
    pct = w.get("used_percentage")
    if pct is None:
        return None
    reset = fmt_reset(w["resets_at"]) if w.get("resets_at") else ""
    return f"{name} {bar(pct)} {pct:.0f}%", reset


windows = [w for w in (window("5h", "five_hour"), window("7d", "seven_day")) if w]
if not windows:
    raise SystemExit(0)

print(" · ".join(f"{text} ↻{reset}" if reset else text for text, reset in windows))

if os.environ.get("HERDR_ENV") != "1":
    raise SystemExit(0)
sock_path = os.environ.get("HERDR_SOCKET_PATH")
if not sock_path:
    raise SystemExit(0)

request = {
    "id": "herdr-rate-limits-title",
    "method": "client.window_title.set",
    "params": {"title": "  ·  ".join(text for text, _ in windows)},
}
try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(sock_path)
    client.sendall((json.dumps(request) + "\n").encode())
    try:
        client.recv(4096)
    except Exception:
        pass
    client.close()
except Exception:
    pass
'
exit 0
