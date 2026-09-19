#!/bin/bash
# S0.1 — record the real stdin payload of a hook event, then get out of the way.
# Capture only: never decides anything, never writes to stdout, always exits 0.
set -uo pipefail

OUT="${CLAUDE_INBOX_CAPTURE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/spikes/captured}"
mkdir -p "$OUT" 2>/dev/null || exit 0

payload=$(cat)
event=$(printf '%s' "$payload" | /usr/bin/jq -r '.hook_event_name // "unknown"' 2>/dev/null) || event=unknown
tool=$(printf '%s' "$payload" | /usr/bin/jq -r '.tool_name // empty' 2>/dev/null) || tool=""
ts=$(date +%Y%m%d-%H%M%S)

printf '%s' "$payload" > "$OUT/${event}${tool:+-$tool}-$ts-$$.json" 2>/dev/null
exit 0
