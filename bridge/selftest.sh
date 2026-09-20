#!/bin/bash
# Round-trip the permission hook against a throwaway inbox: block, verdict, decide.
# Also proves the timeout path prints nothing, which is what keeps sessions safe.
set -uo pipefail
cd "$(dirname "$0")"

export CLAUDE_INBOX_DIR="${TMPDIR:-/tmp}/claude-inbox-selftest.$$"
trap 'rm -rf "$CLAUDE_INBOX_DIR"' EXIT

# Stand in for the app. The hook refuses to block when nothing is listening, so
# without this every wait below returns instantly and every assertion fails —
# which is exactly what should happen when the app is not running.
beat() { mkdir -p "$CLAUDE_INBOX_DIR"; date +%s > "$CLAUDE_INBOX_DIR/heartbeat"; }

PAYLOAD='{"hook_event_name":"PermissionRequest","session_id":"s-1","cwd":"/Users/me/work/skyaccess-api","tool_name":"Bash","tool_input":{"command":"rm -rf dist"},"permission_mode":"default","transcript_path":"/tmp/t.jsonl"}'
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected [$3] got [$2]"; fail=1; fi; }

beat
echo "1. verdict arrives -> decision is returned"
( for _ in $(seq 1 100); do
    f=$(ls "$CLAUDE_INBOX_DIR/pending"/*.json 2>/dev/null | head -1) || true
    if [ -n "${f:-}" ]; then
      req=$(basename "$f" .json)
      echo '{"decision":"allow","reason":"approved in test"}' > "$CLAUDE_INBOX_DIR/verdicts/$req.json"
      exit 0
    fi
    sleep 0.1
  done ) &
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=10 ./hook-permission.sh)
wait
# Shape per the binary's validator: decision is an OBJECT keyed by `behavior`.
# A string there is dropped silently, so assert the object, not just the word.
check "event"         "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.hookEventName')" "PermissionRequest"
check "behavior"      "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.decision.behavior')" "allow"
check "decision type" "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.decision | type')" "object"
check "allow is bare" "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.decision | keys | join(",")')" "behavior"

echo "1b. deny carries the message the model is told"
( for _ in $(seq 1 100); do
    f=$(ls "$CLAUDE_INBOX_DIR/pending"/*.json 2>/dev/null | head -1) || true
    if [ -n "${f:-}" ]; then
      echo '{"decision":"deny","reason":"not on staging"}' > "$CLAUDE_INBOX_DIR/verdicts/$(basename "$f" .json).json"
      exit 0
    fi
    sleep 0.1
  done ) &
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=10 ./hook-permission.sh)
wait
check "deny behavior" "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.decision.behavior')" "deny"
check "deny message"  "$(printf '%s' "$out" | /usr/bin/jq -r '.hookSpecificOutput.decision.message')" "not on staging"

echo "2. timeout -> no output, exit 0, pending cleaned up"
beat
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=1 ./hook-permission.sh); rc=$?
check "exit code" "$rc" "0"
check "stdout"    "$out" ""
check "pending"   "$(ls -1 "$CLAUDE_INBOX_DIR/pending" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "3. garbage verdict -> ignored, no output"
beat
( for _ in $(seq 1 100); do
    f=$(ls "$CLAUDE_INBOX_DIR/pending"/*.json 2>/dev/null | head -1) || true
    if [ -n "${f:-}" ]; then echo 'not json at all' > "$CLAUDE_INBOX_DIR/verdicts/$(basename "$f" .json).json"; exit 0; fi
    sleep 0.1
  done ) &
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=5 ./hook-permission.sh)
wait
check "stdout" "$out" ""

echo "4. session registry follows the turn, both ways"
sess() { printf '%s' "$1" | ./hook-session.sh; /usr/bin/jq -r .state "$CLAUDE_INBOX_DIR/sessions/s-2.json" 2>/dev/null; }
check "SessionStart"      "$(sess '{"hook_event_name":"SessionStart","session_id":"s-2","cwd":"/Users/me/work/tarot"}')" "working"
check "Stop"              "$(sess '{"hook_event_name":"Stop","session_id":"s-2","cwd":"/Users/me/work/tarot","last_assistant_message":"done here"}')" "idle"
# The one that was missing: without it a session reads idle from its first answer
# until the process dies, however busy it actually is.
check "UserPromptSubmit"  "$(sess '{"hook_event_name":"UserPromptSubmit","session_id":"s-2","cwd":"/Users/me/work/tarot","prompt":"go on"}')" "working"
check "SessionEnd"        "$(sess '{"hook_event_name":"SessionEnd","session_id":"s-2","cwd":"/Users/me/work/tarot","reason":"clear"}')" "done"
check "end reason kept"   "$(/usr/bin/jq -r .end_reason "$CLAUDE_INBOX_DIR/sessions/s-2.json")" "clear"
check "hooks stay silent" "$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s-3","cwd":"/x","prompt":"hi"}' | ./hook-session.sh)" ""

echo "4b. each event carries half the picture; the record keeps both halves"
# Stop has the last message and no prompt, UserPromptSubmit the reverse, SessionEnd
# neither. Overwriting threw the other half away, and a finished session lost the
# one thing worth reading about it.
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s-4","cwd":"/x","prompt":"/morgan:pull дособери фичу"}' | ./hook-session.sh
printf '%s' '{"hook_event_name":"Stop","session_id":"s-4","cwd":"/x","last_assistant_message":"Done, tests green."}' | ./hook-session.sh
printf '%s' '{"hook_event_name":"SessionEnd","session_id":"s-4","cwd":"/x","reason":"clear"}' | ./hook-session.sh
check "prompt survives"  "$(/usr/bin/jq -r .last_prompt  "$CLAUDE_INBOX_DIR/sessions/s-4.json")" "/morgan:pull дособери фичу"
check "message survives" "$(/usr/bin/jq -r .last_message "$CLAUDE_INBOX_DIR/sessions/s-4.json")" "Done, tests green."
check "state is final"   "$(/usr/bin/jq -r .state        "$CLAUDE_INBOX_DIR/sessions/s-4.json")" "done"
# A corrupt previous record must not take the next write down with it.
echo 'not json' > "$CLAUDE_INBOX_DIR/sessions/s-5.json"
printf '%s' '{"hook_event_name":"Stop","session_id":"s-5","cwd":"/x","last_assistant_message":"ok"}' | ./hook-session.sh
check "corrupt prev survived" "$(/usr/bin/jq -r .state "$CLAUDE_INBOX_DIR/sessions/s-5.json" 2>/dev/null)" "idle"

echo "4c. a system event is not what someone asked for"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s-6","cwd":"/x","prompt":"/morgan:pull дособери"}' | ./hook-session.sh
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s-6","cwd":"/x","prompt":"<task-notification><task-id>a</task-id></task-notification>"}' | ./hook-session.sh
check "real prompt kept" "$(/usr/bin/jq -r .last_prompt "$CLAUDE_INBOX_DIR/sessions/s-6.json")" "/morgan:pull дособери"

echo "5. the pending record keeps what the UI and the grant need"
( for _ in $(seq 1 100); do
    f=$(ls "$CLAUDE_INBOX_DIR/pending"/*.json 2>/dev/null | head -1) || true
    if [ -n "${f:-}" ]; then cp "$f" "$CLAUDE_INBOX_DIR/captured.json"; echo '{"decision":"allow"}' > "$CLAUDE_INBOX_DIR/verdicts/$(basename "$f" .json).json"; exit 0; fi
    sleep 0.1
  done ) &
RICH='{"hook_event_name":"PermissionRequest","session_id":"s-9","cwd":"/w","prompt_id":"p-9","tool_name":"Bash","tool_input":{"command":"ls"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}'
printf '%s' "$RICH" | CLAUDE_INBOX_PERMISSION_TIMEOUT=10 ./hook-permission.sh >/dev/null
wait
check "prompt_id"   "$(/usr/bin/jq -r '.prompt_id' "$CLAUDE_INBOX_DIR/captured.json")" "p-9"
check "suggestions" "$(/usr/bin/jq -r '.permission_suggestions[0].mode' "$CLAUDE_INBOX_DIR/captured.json")" "acceptEdits"

echo "6. nothing is listening -> give the terminal back immediately"
# A hook that blocks for its whole timeout with nothing listening is a dead freeze
# before every prompt, waiting on an answer that was never coming.
rm -f "$CLAUDE_INBOX_DIR/heartbeat"
start=$(date +%s)
out=$(printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=60 ./hook-permission.sh)
elapsed=$(( $(date +%s) - start ))
check "stdout"          "$out" ""
check "gave up fast"    "$([ "$elapsed" -le 8 ] && echo yes || echo "no (${elapsed}s)")" "yes"
check "pending cleaned" "$(ls -1 "$CLAUDE_INBOX_DIR/pending" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "7. a stale heartbeat counts as nobody home"
date -r $(( $(date +%s) - 600 )) +%s > "$CLAUDE_INBOX_DIR/heartbeat" 2>/dev/null || echo $(( $(date +%s) - 600 )) > "$CLAUDE_INBOX_DIR/heartbeat"
start=$(date +%s)
printf '%s' "$PAYLOAD" | CLAUDE_INBOX_PERMISSION_TIMEOUT=60 ./hook-permission.sh >/dev/null
check "gave up fast" "$([ $(( $(date +%s) - start )) -le 8 ] && echo yes || echo no)" "yes"

echo "8. a malformed payload leaves no ghost row"
beat
printf '%s' '{"hook_event_name":"PermissionRequest"}' | CLAUDE_INBOX_PERMISSION_TIMEOUT=2 ./hook-permission.sh >/dev/null
check "no session_id, no row" "$(ls -1 "$CLAUDE_INBOX_DIR/pending" 2>/dev/null | wc -l | tr -d ' ')" "0"
printf '%s' 'not json at all' | CLAUDE_INBOX_PERMISSION_TIMEOUT=2 ./hook-permission.sh >/dev/null
check "garbage, no row"       "$(ls -1 "$CLAUDE_INBOX_DIR/pending" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "9. reaping clears what a killed hook left behind"
mkdir -p "$CLAUDE_INBOX_DIR/pending"
/usr/bin/jq -n '{req:"ghost", kind:"permission", state:"blocked.permission", ts:0, pid:999999, session_id:"s-ghost"}' \
  > "$CLAUDE_INBOX_DIR/pending/ghost.json"
/usr/bin/jq -n '{req:"live", kind:"permission", state:"blocked.permission", ts:0, pid:'"$$"', session_id:"s-live"}' \
  > "$CLAUDE_INBOX_DIR/pending/live.json"
printf '%s' '{"hook_event_name":"Stop","session_id":"s-reap","cwd":"/x"}' | ./hook-session.sh
check "dead pid swept"  "$([ -f "$CLAUDE_INBOX_DIR/pending/ghost.json" ] && echo kept || echo gone)" "gone"
check "live pid kept"   "$([ -f "$CLAUDE_INBOX_DIR/pending/live.json" ] && echo kept || echo gone)" "kept"

echo
[ "$fail" = 0 ] && echo "all good" || { echo "FAILURES"; exit 1; }
