#!/bin/sh
# herdr-statusline.sh — Claude Code "statusLine" command (settings.json ->
# statusLine.command), NOT a hook. Claude Code pipes a JSON blob on stdin
# after each response; for Pro/Max subscribers it includes the real plan
# limits (https://code.claude.com/docs/en/statusline):
#   rate_limits.five_hour.{used_percentage,resets_at}   rolling 5-hour window
#   rate_limits.seven_day.{used_percentage,resets_at}   weekly window
# These are the same numbers `/usage` shows — no credentials read, no
# undocumented endpoint.
#
# It only CACHES them in ${XDG_CACHE_HOME:-~/.cache}/herdr-claude-limits.json
# (atomic write) and prints nothing, so Claude Code's own status row stays
# empty. herdr's tab bar draws them through scripts/claude-limits-bar
# ([ui] tab_bar_right in config.toml), once for the whole account, at the
# right of the tab bar.
#
# Works inside or outside a Herdr pane. Each window may be absent (API-key
# users, or before the first response in a session): then nothing is cached.
# Always exits 0.
set -u

command -v python3 >/dev/null 2>&1 || exit 0

python3 -c '
import json
import os
import sys
import tempfile
import time

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)

limits = data.get("rate_limits") or {}
five = limits.get("five_hour") or {}
seven = limits.get("seven_day") or {}
if five.get("used_percentage") is None and seven.get("used_percentage") is None:
    raise SystemExit(0)

cache_dir = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
cache_file = os.path.join(cache_dir, "herdr-claude-limits.json")
try:
    os.makedirs(cache_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=cache_dir, prefix=".herdr-claude-limits.")
    with os.fdopen(fd, "w") as fh:
        json.dump({"updated": int(time.time()), "five_hour": five, "seven_day": seven}, fh)
    os.replace(tmp, cache_file)
except OSError:
    pass
'
exit 0
