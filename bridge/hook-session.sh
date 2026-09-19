#!/bin/bash
# SessionStart / Stop / SessionEnd — keep the registry current.
# Informational only: prints nothing, decides nothing.
set -uo pipefail
cd "$(dirname "$0")" 2>/dev/null || exit 0
# shellcheck source=lib.sh
. ./lib.sh 2>/dev/null || exit 0

payload=$(cat) || exit 0
inbox_ready || exit 0

event=$(printf '%s' "$payload" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null)
sid=$(printf '%s' "$payload" | "$JQ" -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

case "$event" in
  SessionStart) state="working" ;;
  Stop)         state="idle" ;;
  SessionEnd)   state="done" ;;
  *)            exit 0 ;;
esac

printf '%s' "$payload" | "$JQ" --arg state "$state" --argjson ts "$(date +%s)" '{
  session_id: .session_id,
  state: $state,
  ts: $ts,
  cwd: .cwd,
  permission_mode: .permission_mode,
  transcript_path: .transcript_path,
  last_message: (.last_assistant_message // null)
}' 2>/dev/null | inbox_write "$INBOX_DIR/sessions/$sid.json" || exit 0

inbox_nudge
exit 0
