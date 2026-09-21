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

# Each event carries only part of the picture: Stop has the last message and no
# prompt, UserPromptSubmit the reverse, SessionEnd neither. Overwriting the record
# each time threw the other half away — a finished session lost the very thing
# worth reading about it.
prev=$(cat "$INBOX_DIR/sessions/$sid.json" 2>/dev/null) || prev="{}"
printf '%s' "$prev" | "$JQ" -e 'type == "object"' >/dev/null 2>&1 || prev="{}"

ts=$(date +%s)
case "$event" in
  SessionStart|UserPromptSubmit) state="working" ;;
  Stop)                          state="idle" ;;
  SessionEnd)                    state="done" ;;
  # The event that actually fires for the way people work. A session in
  # acceptEdits or bypassPermissions almost never raises a PermissionRequest, so
  # a bridge listening only for those is deaf to most of a day: Notification is
  # Claude Code saying "this one wants you" whatever the permission mode is.
  Notification)
    # Two different things arrive under this one name. `permission_prompt` is a
    # session that cannot go on without a person. `idle_prompt` is a turn that
    # ended a minute ago with nobody typing — and the session may be busy the
    # whole time, waiting on a background agent or on CI. Filing that under
    # "waiting for you" is inventing urgency, the one error the state vocabulary
    # exists to prevent. An older Claude Code sends no type, only the sentence.
    kind=$(printf '%s' "$payload" | "$JQ" -r '.notification_type // (if ((.message // "") | test("waiting for your input"; "i")) then "idle_prompt" else "" end)' 2>/dev/null)
    case "$kind" in
      idle_prompt|auth_success)
        # Nothing new was observed, so neither the state nor its age moves: the
        # live registry, which knows the session is busy, stays the fresher one.
        state=$(printf '%s' "$prev" | "$JQ" -r '.state // "idle"' 2>/dev/null) || state="idle"
        [ "$state" = "blocked.dialog" ] && state="idle"
        ts=$(printf '%s' "$prev" | "$JQ" -r '.ts // empty' 2>/dev/null)
        case "$ts" in *[!0-9]*|"") ts=$(date +%s) ;; esac
        ;;
      *) state="blocked.dialog" ;;
    esac ;;
  *)                             exit 0 ;;
esac

printf '%s' "$payload" | "$JQ" --arg state "$state" --arg event "$event" --argjson ts "$ts" \
  --argjson prev "$prev" '
  # SKY-5463, from a tracker link first and a bare key second. Three digits at
  # least: "F3 WI-10 5427" is a real prompt, and a label that lies is worse than
  # a folder name.
  def issue: if type != "string" then null else
    ((capture("linear\\.app/[^/\\s]+/issue/(?<k>[A-Za-z][A-Za-z0-9]*-[0-9]+)").k
      // capture("\\b(?<k>[A-Z][A-Z0-9]{1,9}-[0-9]{3,})\\b").k) | ascii_upcase) end;
  # The step a session declared: "/morgan:track fix it" -> "track".
  def phase: if type != "string" then null else
    (capture("^\\s*/(?<n>[A-Za-z0-9:_-]+)").n | split(":") | last | gsub("[-_]+"; " ")
      | select(length > 0)) end;
  # A system event arrives in the same field a person types into, and is not one.
  def typed: .prompt | select(type == "string" and (test("^<[A-Za-z][A-Za-z0-9-]*>") | not));
  {
  session_id: .session_id,
  state: $state,
  ts: $ts,
  event: $event,
  cwd: .cwd,
  permission_mode: .permission_mode,
  transcript_path: .transcript_path,
  end_reason: (.reason // null),
  # What it wants, in Claude Code own words: "Claude is waiting for your input".
  waiting_for: (if $state == "blocked.dialog" then ((.message | select(type == "string")) // $prev.waiting_for) else null end),
  notification_type: (if $state == "blocked.dialog" then (.notification_type // $prev.notification_type // null) else null end),
  # What the person actually asked for. It arrives free on UserPromptSubmit, and
  # it is the difference between a row that says "working" and one that says what
  # the session is working on.
  # UserPromptSubmit also carries system events — task notifications, monitor
  # wakes — in the same field a person types into. Keeping one would make a row
  # say <task-notification> where it should say what was asked for.
  last_prompt: (typed // $prev.last_prompt // null),
  # Which piece of work this is, in the name the person uses for it. Named once,
  # at the start, and almost never again — so it is kept until a newer one is
  # named. A record from before this field still has the link in its prompt.
  # Declared once, by the command that opened the work, and gone from the prompt
  # at the first "да, пуш" — so it is kept until another command replaces it.
  phase: ((typed | phase) // $prev.phase // ($prev.last_prompt | phase) // null),
  issue: ((typed | issue) // $prev.issue // ($prev.last_prompt | issue) // null),
  last_message: (.last_assistant_message // $prev.last_message // null)
}' 2>/dev/null | inbox_write "$INBOX_DIR/sessions/$sid.json" || exit 0

# Nothing else ever sweeps the inbox: a SIGKILLed hook leaves its pending file
# behind as a row that can never be cleared, and sessions/ grows one file per
# session forever — all of them parsed on every poll.
inbox_reap
exit 0
