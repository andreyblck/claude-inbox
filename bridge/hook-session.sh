#!/bin/bash
# SessionStart / UserPromptSubmit / Stop / SessionEnd — keep the registry current.
# Informational only: prints nothing, decides nothing.
#
# UserPromptSubmit is the one that is easy to leave out and wrong to. Stop fires at
# the end of every turn, so without a matching "a turn started" event the registry
# says `idle` from the first completed answer until the process dies — and the inbox
# renders a grey Idle row over a session that is working.
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
  SessionStart|UserPromptSubmit) state="working" ;;
  Stop)                          state="idle" ;;
  SessionEnd)                    state="done" ;;
  *)                             exit 0 ;;
esac

printf '%s' "$payload" | "$JQ" --arg state "$state" --arg event "$event" --argjson ts "$(date +%s)" '{
  session_id: .session_id,
  state: $state,
  ts: $ts,
  event: $event,
  cwd: .cwd,
  permission_mode: .permission_mode,
  transcript_path: .transcript_path,
  end_reason: (.reason // null),
  last_message: (.last_assistant_message // null)
}' 2>/dev/null | inbox_write "$INBOX_DIR/sessions/$sid.json" || exit 0

# Nothing else ever sweeps the inbox: a SIGKILLed hook leaves its pending file
# behind as a row that can never be cleared, and sessions/ grows one file per
# session forever — all of them parsed on every poll.
inbox_reap
inbox_nudge
exit 0
