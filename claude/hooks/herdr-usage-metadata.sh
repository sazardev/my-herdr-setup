#!/bin/sh
# herdr-usage-metadata.sh — custom Claude Code "Stop" hook (NOT managed by
# herdr's own integration installer — that one only lives at
# ~/.claude/hooks/herdr-agent-state.sh and gets overwritten on reinstall/
# update; this file is a sibling, wired in separately via the "Stop" entry
# in ~/.claude/settings.json).
#
# On every assistant turn ("Stop"), summarizes this session's own transcript
# (hook gives us transcript_path directly — no need to scan/guess) with
# `claude-usage-report --transcript` and pushes custom fields to this pane's
# Herdr sidebar via pane.report_metadata:
#   $cost    estimated USD spent this session at public API prices
#            (monotonic: it only grows; plan subscribers: API-equivalent, not
#            what is billed). Prices live in scripts/claude-usage-report.
#   $tok     total tokens seen this session (input+output+cache_read+cache_creation)
#   $cachep  % of input-side tokens spent on cache_creation (fresh cache writes)
#            — high and sustained here means poor cache reuse.
#
# Reference them in ~/.config/herdr/config.toml under [ui.sidebar.agents]
# rows, e.g.:
#   rows = [["state_icon", "workspace", "tab"], ["$cost"]]
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
import shutil
import socket
import subprocess

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

report = shutil.which("claude-usage-report") or os.path.expanduser("~/.local/bin/claude-usage-report")
if not os.access(report, os.X_OK):
    raise SystemExit(0)

try:
    out = subprocess.run(
        [report, "--transcript", transcript_path],
        capture_output=True, text=True, timeout=20, check=True,
    ).stdout
    totals = json.loads(out)
except Exception:
    raise SystemExit(0)

cache_side = totals["input"] + totals["cache_read"] + totals["cache_creation"]
grand_total = cache_side + totals["output"]
if grand_total == 0:
    raise SystemExit(0)

cache_pct = round(totals["cache_creation"] / cache_side * 100) if cache_side else 0


def humanize(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


cost = f"${totals['cost_usd']:,.2f}"
if totals.get("unpriced_requests"):
    cost += "+"  # hubo requests de un modelo sin precio conocido: el real es mayor

request = {
    "id": f"herdr-usage-metadata:{pane_id}",
    "method": "pane.report_metadata",
    "params": {
        "pane_id": pane_id,
        "source": "claude-usage-metadata",
        "tokens": {"cost": cost, "tok": humanize(grand_total), "cachep": f"{cache_pct}%"},
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
