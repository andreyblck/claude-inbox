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

# Each event carries only part of the picture: Stop has the last message and no
# prompt, UserPromptSubmit the reverse, SessionEnd neither. Overwriting the record
# each time threw the other half away — a finished session lost the very thing
# worth reading about it.
prev=$(cat "$INBOX_DIR/sessions/$sid.json" 2>/dev/null) || prev="{}"
printf '%s' "$prev" | "$JQ" -e 'type == "object"' >/dev/null 2>&1 || prev="{}"

printf '%s' "$payload" | "$JQ" --arg state "$state" --arg event "$event" --argjson ts "$(date +%s)" \
  --argjson prev "$prev" '{
  session_id: .session_id,
  state: $state,
  ts: $ts,
  event: $event,
  cwd: .cwd,
  permission_mode: .permission_mode,
  transcript_path: .transcript_path,
  end_reason: (.reason // null),
  # What the person actually asked for. It arrives free on UserPromptSubmit, and
  # it is the difference between a row that says "working" and one that says what
  # the session is working on.
  # UserPromptSubmit also carries system events — task notifications, monitor
  # wakes — in the same field a person types into. Keeping one would make a row
  # say <task-notification> where it should say what was asked for.
  last_prompt: ((.prompt | select(type == "string" and (test("^<[A-Za-z][A-Za-z0-9-]*>") | not))) // $prev.last_prompt // null),
  last_message: (.last_assistant_message // $prev.last_message // null)
}' 2>/dev/null | inbox_write "$INBOX_DIR/sessions/$sid.json" || exit 0

# Nothing else ever sweeps the inbox: a SIGKILLed hook leaves its pending file
# behind as a row that can never be cleared, and sessions/ grows one file per
# session forever — all of them parsed on every poll.
inbox_reap
exit 0
