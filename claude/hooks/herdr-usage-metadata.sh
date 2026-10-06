#!/bin/sh
# herdr-usage-metadata.sh — custom Claude Code "Stop" hook (NOT managed by
# herdr's own integration installer — that one only lives at
# ~/.claude/hooks/herdr-agent-state.sh and gets overwritten on reinstall/
# update; this file is a sibling, wired in separately via the "Stop" entry
# in ~/.claude/settings.json).
#
# On every assistant turn ("Stop"), reads this session's own transcript
# (hook gives us transcript_path directly — no need to scan/guess) and pushes
# two custom fields to this pane's Herdr sidebar via pane.report_metadata:
#   $tok     total tokens seen this session (input+output+cache_read+cache_creation)
#   $cachep  % of that total spent on cache_creation (fresh cache writes)
#            — high and sustained here means poor cache reuse, i.e. tokens
#            burned re-paying the system prompt/tools prefix instead of
#            reading it from cache.
#
# Reference $tok / $cachep in ~/.config/herdr/config.toml under
# [ui.sidebar.agents] rows, e.g.:
#   rows = [["state_icon", "workspace", "tab"], ["agent"], ["$tok", "$cachep"]]
#
# Same socket-API pattern as herdr-agent-state.sh: no-ops silently (exit 0)
# outside a Herdr pane, so it's harmless in any other terminal/CI context.
set -eu

hook_input_file="$(mktemp "${TMPDIR:-/tmp}/herdr-usage-hook.XXXXXX")" || exit 0
trap 'rm -f "$hook_input_file"' EXIT HUP INT TERM
cat >"$hook_input_file" 2>/dev/null || true

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HERDR_HOOK_INPUT_FILE="$hook_input_file" python3 - <<'PY'
import json
import os
import socket

hook_input_file = os.environ["HERDR_HOOK_INPUT_FILE"]
pane_id = os.environ["HERDR_PANE_ID"]
socket_path = os.environ["HERDR_SOCKET_PATH"]

try:
    with open(hook_input_file, encoding="utf-8") as fh:
        hook_input = json.load(fh)
except Exception:
    raise SystemExit(0)

transcript_path = hook_input.get("transcript_path")
if not transcript_path or not os.path.isfile(transcript_path):
    raise SystemExit(0)

totals = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}
try:
    with open(transcript_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("type") != "assistant":
                continue
            usage = ((obj.get("message") or {}).get("usage")) or {}
            totals["input"] += usage.get("input_tokens") or 0
            totals["output"] += usage.get("output_tokens") or 0
            totals["cache_read"] += usage.get("cache_read_input_tokens") or 0
            totals["cache_creation"] += usage.get("cache_creation_input_tokens") or 0
except OSError:
    raise SystemExit(0)

grand_total = sum(totals.values())
if grand_total == 0:
    raise SystemExit(0)

cache_side = totals["input"] + totals["cache_read"] + totals["cache_creation"]
cache_pct = round(totals["cache_creation"] / cache_side * 100) if cache_side else 0


def humanize(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


request = {
    "id": f"herdr-usage-metadata:{pane_id}",
    "method": "pane.report_metadata",
    "params": {
        "pane_id": pane_id,
        "source": "claude-usage-metadata",
        "tokens": {"tok": humanize(grand_total), "cachep": f"{cache_pct}%"},
        "ttl_ms": 600000,
    },
}

try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.5)
    client.connect(socket_path)
    client.sendall((json.dumps(request) + "\n").encode())
    try:
        client.recv(4096)
    except Exception:
        pass
    client.close()
except Exception:
    pass
PY
